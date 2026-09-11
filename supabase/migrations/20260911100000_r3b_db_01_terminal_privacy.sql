-- ============================================================
-- R3B-DB-01: TERMINAL BOOKING PRIVACY + REPORT-SCOPED EVIDENCE
-- ============================================================
--
-- SCOPE
-- -----
-- Hardens terminal Booking privacy and adds one Admin-only historical
-- message evidence RPC. No application table, column, index, constraint
-- or trigger is created, so D-001 table count stays 12 and the ERD is
-- unchanged.
--
-- This migration:
--   1. CREATE OR REPLACE public.list_my_worker_bookings() and
--      public.list_my_client_bookings() with the SAME signatures and
--      RETURNS TABLE columns/types/order. Contact/profile release
--      becomes confirmed-only. Exact job_address is projected only
--      while confirmed. Counterpart UUIDs stay unconditional. Owned
--      rows remain listed in every status.
--   2. DROP/CREATE the public.messages SELECT policy so ordinary
--      participant history is readable only while the Booking is
--      confirmed. INSERT is not rewritten.
--   3. Adds public.get_report_booking_messages(p_report_id uuid).
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No DELETE/UPDATE on public.messages. Rows remain stored after
--     completion, cancellation, and report review.
--   * No Admin SELECT policy on public.messages.
--   * No change to R3 report RPCs or public.reports.
--   * No notification type, no punishment, no no_show producer.
--   * No public.job_postings RLS change. Authenticated-wide job
--     SELECT remains an acknowledged residual; this piece only
--     suppresses job_address in the participant Booking RPCs.
--
-- SUPERSEDED LIVE RULES (provenance retained in docs)
-- ---------------------------------------------------
-- N11 originally released counterpart contact/profile for confirmed
-- AND completed. BL-01C originally left message SELECT status-
-- independent so terminal history stayed readable. R3B amends both
-- live rules. Historical rows and historical documentation remain.
--
-- TDD SEAMS (public behavior; hosted matrix is the next gate)
-- ----------------------------------------------------------
--   * confirmed participant projection retains approved contact
--   * completed/cancelled contact/profile projection is NULL
--   * exact job_address is NULL unless confirmed
--   * history rows remain listable
--   * counterpart UUID remains non-null
--   * confirmed participant message SELECT allowed
--   * non-confirmed ordinary message SELECT returns 0
--   * INSERT remains confirmed-only
--   * message rows are not deleted
--   * evidence RPC is report->booking scoped
--   * app_issue / missing report -> SM409
--   * non-admin evidence -> 42501
--   * Admin direct messages SELECT remains 0
--
-- ERROR CLASSES
-- -------------
--   42501  not authorized (signed out / non-admin)
--   22023  invalid argument (NULL report id)
--   SM409  evidence context unavailable (collapsed)
-- ============================================================


-- ---------- 1. WORKER BOOKING LIST (signature unchanged) ----------

CREATE OR REPLACE FUNCTION public.list_my_worker_bookings()
RETURNS TABLE (
  booking_id       uuid,
  job_id           uuid,
  booking_status   text,
  payment_status   text,
  booked_at        timestamptz,
  completed_at     timestamptz,
  job_title        text,
  job_description  text,
  job_scheduled_at timestamptz,
  job_address      text,
  job_barangay     text,
  job_city         text,
  job_budget       numeric,
  client_user_id   uuid,
  client_full_name text,
  client_phone     text
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

  -- client_user_id stays unconditional so existing mobile coercion
  -- cannot drop terminal history rows. Name, phone, and exact address
  -- are confirmed-only. Email is never projected.
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
    CASE WHEN b.status = 'confirmed' THEN cu.phone END
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
  'N11 as amended by R3B: the calling Worker''s own Bookings. Requires '
  'an active Worker account (private.is_active_worker()); every other '
  'caller receives 42501. Rows are worker_id = auth.uid() in EVERY '
  'status. Client full_name, Client phone, and exact job_address are '
  'released only while confirmed and are NULL otherwise. job_barangay '
  'and job_city remain. client_user_id is always projected. Client '
  'email is never projected.';


REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM anon;

REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM authenticated;

REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM service_role;

GRANT EXECUTE ON FUNCTION public.list_my_worker_bookings() TO authenticated;


-- ---------- 2. CLIENT BOOKING LIST (signature unchanged) ----------

CREATE OR REPLACE FUNCTION public.list_my_client_bookings()
RETURNS TABLE (
  booking_id          uuid,
  job_id              uuid,
  booking_status      text,
  payment_status      text,
  booked_at           timestamptz,
  completed_at        timestamptz,
  job_title           text,
  job_description     text,
  job_scheduled_at    timestamptz,
  job_address         text,
  job_barangay        text,
  job_city            text,
  job_budget          numeric,
  worker_user_id      uuid,
  worker_full_name    text,
  worker_phone        text,
  worker_barangay     text,
  worker_skills       text[],
  worker_is_verified  boolean,
  worker_rating_avg   numeric,
  worker_rating_count integer
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

  -- Worker profile block remains one unit. R3B gates that unit on
  -- confirmed only. Exact job_address is likewise confirmed-only.
  -- worker_user_id stays unconditional.
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
    END
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
  'N11 as amended by R3B: the calling Client''s own Bookings. Requires '
  'an active Client account (private.is_active_client()); every other '
  'caller receives 42501. Rows are client_id = auth.uid() in EVERY '
  'status. The Worker profile block and exact job_address are released '
  'only while confirmed and are NULL otherwise. job_barangay and '
  'job_city remain. worker_user_id is always projected. Worker email '
  'and verified_by are never projected. worker_skills is NULL when '
  'suppressed and ''{}'' when released for a Worker with no skills.';


REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM anon;

REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM authenticated;

REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM service_role;

GRANT EXECUTE ON FUNCTION public.list_my_client_bookings() TO authenticated;


-- ---------- 3. ORDINARY MESSAGE SELECT: CONFIRMED ONLY ----------
--
-- INSERT is intentionally not rewritten. Sending remains the BL-01C
-- confirmed / participant / sender_id / content contract.

DROP POLICY "Users can view messages in their bookings" ON public.messages;

CREATE POLICY "Users can view messages in their bookings"
  ON public.messages
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.bookings b
      WHERE b.id = messages.booking_id
        AND b.status = 'confirmed'
        AND (b.worker_id = auth.uid() OR b.client_id = auth.uid())
    )
  );

COMMENT ON POLICY "Users can view messages in their bookings" ON public.messages IS
  'R3B: participant-only read of a Booking''s message history, and only '
  'while that Booking is confirmed. completed, cancelled, pending and '
  'no_show yield zero rows. Historical rows remain stored. A '
  'non-participant sees zero rows rather than an error. Admin historical '
  'access is only through public.get_report_booking_messages.';


-- ---------- 4. REPORT-SCOPED ADMIN EVIDENCE ----------

CREATE OR REPLACE FUNCTION public.get_report_booking_messages(p_report_id uuid)
RETURNS TABLE (
  message_id   uuid,
  sender_role  text,
  content      text,
  created_at   timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_booking_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to view report messages'
      USING ERRCODE = '42501';
  END IF;

  IF p_report_id IS NULL THEN
    RAISE EXCEPTION 'invalid report id'
      USING ERRCODE = '22023';
  END IF;

  SELECT r.booking_id
    INTO v_booking_id
  FROM public.reports AS r
  WHERE r.id = p_report_id;

  -- Missing report, app_issue, and any other NULL booking_id share one
  -- SM409 so the caller cannot distinguish those cases.
  IF NOT FOUND OR v_booking_id IS NULL THEN
    RAISE EXCEPTION 'this report is not available'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    CASE
      WHEN m.sender_id = b.worker_id THEN 'worker'::text
      ELSE 'client'::text
    END,
    m.content,
    m.created_at
  FROM public.messages AS m
  JOIN public.bookings AS b
    ON b.id = m.booking_id
  WHERE m.booking_id = v_booking_id
    AND (m.sender_id = b.worker_id OR m.sender_id = b.client_id)
  ORDER BY m.created_at ASC, m.id ASC;
END;
$$;


COMMENT ON FUNCTION public.get_report_booking_messages(uuid) IS
  'R3B: Administrator historical messages for the Booking bound to one '
  'report. Requires private.is_admin(); every other caller receives '
  '42501. NULL id returns 22023. Missing report, app_issue, and any '
  'report without booking_id return the same SM409. Scope is derived '
  'from reports.booking_id only. Returns message_id, sender_role '
  '(worker/client), content and created_at in chronological order. No '
  'sender UUID, name, phone, email, address or is_read. Does not dump '
  'messages into get_report().';


REVOKE ALL ON FUNCTION public.get_report_booking_messages(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.get_report_booking_messages(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.get_report_booking_messages(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.get_report_booking_messages(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.get_report_booking_messages(uuid) TO authenticated;
