-- ============================================================
-- V4 #19-BE1: DURABLE BOOKING CANCELLATION METADATA
-- ============================================================
-- Attribute-only extension of public.bookings. Historical cancelled
-- rows keep their all-NULL metadata bundle; new reason-aware
-- cancellations are written only through the trusted RPC below.

ALTER TABLE public.bookings
  ADD COLUMN cancellation_reason_code text,
  ADD COLUMN cancellation_reason_detail text,
  ADD COLUMN cancelled_by uuid,
  ADD COLUMN cancelled_at timestamptz,
  ADD CONSTRAINT bookings_cancellation_metadata_check
  CHECK (
    (
      cancellation_reason_code IS NULL
      AND cancellation_reason_detail IS NULL
      AND cancelled_by IS NULL
      AND cancelled_at IS NULL
    )
    OR
    (
      status = 'cancelled'
      AND cancellation_reason_code IN (
        'schedule_conflict',
        'unable_to_continue',
        'location_issue',
        'payment_issue',
        'other'
      )
      AND cancelled_by IS NOT NULL
      AND (cancelled_by = worker_id OR cancelled_by = client_id)
      AND cancelled_at IS NOT NULL
      AND (
        cancellation_reason_detail IS NULL
        OR (
          cancellation_reason_detail = btrim(
            cancellation_reason_detail,
            E' \t\n\r\f\v'
          )
          AND cancellation_reason_detail <> ''
          AND char_length(cancellation_reason_detail) <= 300
        )
      )
      AND (
        cancellation_reason_code <> 'other'
        OR cancellation_reason_detail IS NOT NULL
      )
    )
  );

COMMENT ON COLUMN public.bookings.cancellation_reason_code IS
  'V4 #19-BE1 stable cancellation reason code; NULL on legacy or non-cancelled rows.';

COMMENT ON COLUMN public.bookings.cancellation_reason_detail IS
  'V4 #19-BE1 optional trimmed cancellation detail, at most 300 characters; required for reason code other.';

COMMENT ON COLUMN public.bookings.cancelled_by IS
  'V4 #19-BE1 trusted cancelling participant from auth.uid(); NULL for legacy or non-cancelled rows.';

COMMENT ON COLUMN public.bookings.cancelled_at IS
  'V4 #19-BE1 trusted database cancellation time; NULL for legacy or non-cancelled rows.';

COMMENT ON CONSTRAINT bookings_cancellation_metadata_check ON public.bookings IS
  'Allows the legacy all-NULL bundle, or a coherent cancelled-row bundle with an approved reason, Booking participant actor, database timestamp, and normalized bounded detail.';


-- ---------- REASON-AWARE EITHER-PARTICIPANT CANCELLATION ----------
-- The old UUID-only identity must be removed: retaining it would leave
-- a metadata-free public cancellation bypass. Repository and local
-- catalog preflight found no dependent database object.

DROP FUNCTION public.cancel_my_booking(uuid);

CREATE FUNCTION public.cancel_my_booking(
  p_booking_id uuid,
  p_reason_code text,
  p_reason_detail text DEFAULT NULL
)
RETURNS TABLE (
  booking_id     uuid,
  job_id         uuid,
  booking_status text,
  job_status     text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller         uuid := auth.uid();
  v_booking_status text;
  v_booking_client uuid;
  v_booking_worker uuid;
  v_payment_status text;
  v_job_id         uuid;
  v_job_status     text;
  v_job_client     uuid;
  v_job_title      text;
  v_recipient      uuid;
  v_reason_detail  text;
BEGIN
  -- Account authorization remains first and reveals no Booking state.
  IF v_caller IS NULL
     OR NOT (private.is_active_worker() OR private.is_active_client())
  THEN
    RAISE EXCEPTION 'not authorized to cancel bookings'
      USING ERRCODE = '42501';
  END IF;

  -- Fixed lock order step 1: Booking.
  SELECT b.status::text, b.client_id, b.worker_id, b.job_id,
         b.payment_status::text
    INTO v_booking_status, v_booking_client, v_booking_worker, v_job_id,
         v_payment_status
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  -- Collapse absence, non-participation, and wrong Booking status.
  IF NOT FOUND
     OR (v_booking_client IS DISTINCT FROM v_caller
         AND v_booking_worker IS DISTINCT FROM v_caller)
     OR v_booking_status IS DISTINCT FROM 'confirmed'
  THEN
    RAISE EXCEPTION 'this booking is not available for cancellation'
      USING ERRCODE = 'SM409';
  END IF;

  -- Preserve the settled-payment guard after participation is proven.
  IF v_payment_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'a paid booking cannot be cancelled here'
      USING ERRCODE = 'SM403';
  END IF;

  -- Fixed lock order step 2: Job.
  SELECT jp.status::text, jp.client_id, jp.title::text
    INTO v_job_status, v_job_client, v_job_title
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_job_status IS DISTINCT FROM 'matched'
     OR v_job_client IS DISTINCT FROM v_booking_client
  THEN
    RAISE EXCEPTION 'this booking is not available for cancellation'
      USING ERRCODE = 'SM409';
  END IF;

  -- Payload validation deliberately follows authorization and lifecycle
  -- validation so malformed input cannot become a Booking oracle.
  IF p_reason_code IS NULL
     OR p_reason_code NOT IN (
       'schedule_conflict',
       'unable_to_continue',
       'location_issue',
       'payment_issue',
       'other'
     )
  THEN
    RAISE EXCEPTION 'invalid cancellation reason code'
      USING ERRCODE = '22023';
  END IF;

  v_reason_detail := nullif(btrim(p_reason_detail, E' \t\n\r\f\v'), '');

  IF v_reason_detail IS NOT NULL
     AND char_length(v_reason_detail) > 300
  THEN
    RAISE EXCEPTION 'invalid cancellation reason detail'
      USING ERRCODE = '22023';
  END IF;

  IF p_reason_code = 'other' AND v_reason_detail IS NULL THEN
    RAISE EXCEPTION 'cancellation reason detail is required for other'
      USING ERRCODE = '22023';
  END IF;

  -- One atomic Booking update satisfies the coherence constraint. The
  -- payment tuple and completed_at are absent and therefore untouched.
  UPDATE public.bookings AS b
  SET status                     = 'cancelled',
      cancellation_reason_code   = p_reason_code,
      cancellation_reason_detail = v_reason_detail,
      cancelled_by               = v_caller,
      cancelled_at               = now()
  WHERE b.id = p_booking_id;

  -- Cancellation remains terminal: never reopen or rematch the Job.
  UPDATE public.job_postings AS jp
  SET status = 'cancelled'
  WHERE jp.id = v_job_id;

  IF v_caller = v_booking_client THEN
    v_recipient := v_booking_worker;
  ELSE
    v_recipient := v_booking_client;
  END IF;

  -- Fixed trusted text only; free-text detail is not copied here.
  PERFORM private.emit_notification(
    v_recipient,
    'booking_cancelled',
    'The booking for "' || v_job_title || '" has been cancelled.'
  );

  RETURN QUERY
  SELECT b.id, b.job_id, b.status::text, jp.status::text
  FROM public.bookings AS b
  JOIN public.job_postings AS jp ON jp.id = b.job_id
  WHERE b.id = p_booking_id;
END;
$$;

COMMENT ON FUNCTION public.cancel_my_booking(uuid, text, text) IS
  'V4 #19-BE1: terminal Booking cancellation by either exact active participant with required stable reason metadata. Authentication, locked participant/lifecycle checks, pending-payment enforcement, and Booking-then-Job lock order precede payload validation to preserve anti-oracle behavior. cancelled_by is auth.uid() and cancelled_at is database time. Writes no payment field, never reopens or rematches the Job, and emits one fixed counterparty notification without free-text detail.';

REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.cancel_my_booking(uuid, text, text) TO authenticated;


-- ---------- PARTICIPANT BOOKING HISTORY PROJECTIONS ----------
-- RETURNS TABLE changes require drop/recreate. Local catalog preflight
-- found no dependent database objects. Existing R3B privacy rules and
-- row ordering are retained byte-for-behavior; metadata is appended.

DROP FUNCTION public.list_my_worker_bookings();

CREATE FUNCTION public.list_my_worker_bookings()
RETURNS TABLE (
  booking_id                uuid,
  job_id                    uuid,
  booking_status            text,
  payment_status            text,
  booked_at                 timestamptz,
  completed_at              timestamptz,
  job_title                 text,
  job_description           text,
  job_scheduled_at          timestamptz,
  job_address               text,
  job_barangay              text,
  job_city                  text,
  job_budget                numeric,
  client_user_id            uuid,
  client_full_name          text,
  client_phone              text,
  cancellation_reason_code  text,
  cancellation_reason_detail text,
  cancelled_by              uuid,
  cancelled_at              timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized to view worker bookings'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    b.id,
    b.job_id,
    b.status::text,
    b.payment_status::text,
    b.created_at,
    b.completed_at,
    jp.title::text,
    jp.description,
    jp.scheduled_at,
    CASE WHEN b.status = 'confirmed' THEN jp.address END,
    jp.barangay::text,
    jp.city::text,
    jp.budget,
    b.client_id,
    CASE WHEN b.status = 'confirmed' THEN cu.full_name END,
    CASE WHEN b.status = 'confirmed' THEN cu.phone END,
    b.cancellation_reason_code,
    b.cancellation_reason_detail,
    b.cancelled_by,
    b.cancelled_at
  FROM public.bookings AS b
  JOIN public.job_postings AS jp
    ON jp.id = b.job_id
  JOIN public.users AS cu
    ON cu.id = b.client_id
  WHERE b.worker_id = auth.uid()
  ORDER BY b.created_at DESC, b.id DESC;
END;
$$;

COMMENT ON FUNCTION public.list_my_worker_bookings() IS
  'N11 as amended by R3B and V4 #19-BE1: the active Worker caller''s own Bookings in every status. Client full_name, Client phone, and exact job_address remain confirmed-only; email is never projected. Appends persisted cancellation reason code/detail, trusted participant actor, and database cancellation time. Legacy cancelled rows retain an all-NULL metadata bundle.';

REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM anon;
REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM authenticated;
REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM service_role;
GRANT EXECUTE ON FUNCTION public.list_my_worker_bookings() TO authenticated;


DROP FUNCTION public.list_my_client_bookings();

CREATE FUNCTION public.list_my_client_bookings()
RETURNS TABLE (
  booking_id                 uuid,
  job_id                     uuid,
  booking_status             text,
  payment_status             text,
  booked_at                  timestamptz,
  completed_at               timestamptz,
  job_title                  text,
  job_description            text,
  job_scheduled_at           timestamptz,
  job_address                text,
  job_barangay               text,
  job_city                   text,
  job_budget                 numeric,
  worker_user_id             uuid,
  worker_full_name           text,
  worker_phone               text,
  worker_barangay            text,
  worker_skills              text[],
  worker_is_verified         boolean,
  worker_rating_avg          numeric,
  worker_rating_count        integer,
  cancellation_reason_code   text,
  cancellation_reason_detail text,
  cancelled_by               uuid,
  cancelled_at               timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to view client bookings'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    b.id,
    b.job_id,
    b.status::text,
    b.payment_status::text,
    b.created_at,
    b.completed_at,
    jp.title::text,
    jp.description,
    jp.scheduled_at,
    CASE WHEN b.status = 'confirmed' THEN jp.address END,
    jp.barangay::text,
    jp.city::text,
    jp.budget,
    b.worker_id,
    CASE WHEN b.status = 'confirmed' THEN wu.full_name END,
    CASE WHEN b.status = 'confirmed' THEN wu.phone END,
    CASE WHEN b.status = 'confirmed' THEN wu.barangay END,
    CASE
      WHEN b.status = 'confirmed' THEN
        COALESCE(
          (
            SELECT array_agg(DISTINCT sk.skill_name::text ORDER BY sk.skill_name::text)
            FROM public.worker_profiles AS wp
            JOIN public.worker_skills AS ws
              ON ws.worker_id = wp.id
            JOIN public.skills AS sk
              ON sk.id = ws.skill_id
            WHERE wp.user_id = b.worker_id
          ),
          '{}'::text[]
        )
    END,
    CASE
      WHEN b.status = 'confirmed' THEN
        (
          SELECT wp.is_verified
          FROM public.worker_profiles AS wp
          WHERE wp.user_id = b.worker_id
        )
    END,
    CASE
      WHEN b.status = 'confirmed' THEN
        (
          SELECT avg(rt.score)::numeric
          FROM public.ratings AS rt
          WHERE rt.rated_user = b.worker_id
        )
    END,
    CASE
      WHEN b.status = 'confirmed' THEN
        (
          SELECT count(*)::integer
          FROM public.ratings AS rt
          WHERE rt.rated_user = b.worker_id
        )
    END,
    b.cancellation_reason_code,
    b.cancellation_reason_detail,
    b.cancelled_by,
    b.cancelled_at
  FROM public.bookings AS b
  JOIN public.job_postings AS jp
    ON jp.id = b.job_id
  JOIN public.users AS wu
    ON wu.id = b.worker_id
  WHERE b.client_id = auth.uid()
  ORDER BY b.created_at DESC, b.id DESC;
END;
$$;

COMMENT ON FUNCTION public.list_my_client_bookings() IS
  'N11 as amended by R3B and V4 #19-BE1: the active Client caller''s own Bookings in every status. The Worker profile block and exact job_address remain confirmed-only; Worker email and verified_by are never projected. Appends persisted cancellation reason code/detail, trusted participant actor, and database cancellation time. Legacy cancelled rows retain an all-NULL metadata bundle.';

REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM anon;
REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM authenticated;
REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM service_role;
GRANT EXECUTE ON FUNCTION public.list_my_client_bookings() TO authenticated;
