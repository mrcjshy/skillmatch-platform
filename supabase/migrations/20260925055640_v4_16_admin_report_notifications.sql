-- ============================================================
-- V4 #16-N2-BE1: TRUSTED ADMIN REPORT NOTIFICATIONS
-- ============================================================
-- Extends the existing notification type domain and replaces only
-- the two R3 report submission RPCs. Each successful submission emits
-- one fixed, privacy-safe notification per active Administrator in
-- the same transaction. No report INSERT trigger is introduced.


-- ---------- 1. NOTIFICATION TYPE DOMAIN ----------

ALTER TABLE public.notifications
  DROP CONSTRAINT notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (
    (type)::text = ANY (
      ARRAY[
        'booking_request'::character varying,
        'booking_confirmed'::character varying,
        'booking_cancelled'::character varying,
        'booking_completed'::character varying,
        'no_show_strike'::character varying,
        'account_suspended'::character varying,
        'payment_received'::character varying,
        'worker_verified'::character varying,
        'report_submitted'::character varying
      ]::text[]
    )
  );


-- ---------- 2. BOOKING REPORT PRODUCER ----------

CREATE OR REPLACE FUNCTION public.submit_my_booking_report(
  p_booking_id uuid,
  p_category text,
  p_description text
)
RETURNS TABLE (report_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller          uuid := auth.uid();
  v_role            text;
  v_category        text;
  v_description     text;
  v_booking_status  text;
  v_booking_worker  uuid;
  v_booking_client  uuid;
  v_reported        uuid;
  v_report_id       uuid;
  v_admin_id        uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to submit booking reports'
      USING ERRCODE = '42501';
  END IF;

  SELECT u.role::text
    INTO v_role
  FROM public.users AS u
  WHERE u.id = v_caller;

  IF NOT FOUND OR v_role NOT IN ('worker', 'client') THEN
    RAISE EXCEPTION 'not authorized to submit booking reports'
      USING ERRCODE = '42501';
  END IF;

  v_category := NULLIF(btrim(COALESCE(p_category, '')), '');

  IF v_category IS NULL
     OR v_category = 'app_issue'
     OR v_category NOT IN (
          'behavior',
          'no-show',
          'harassment',
          'safety',
          'payment',
          'incorrect_details',
          'fraud',
          'other'
        )
  THEN
    RAISE EXCEPTION 'report category is not valid'
      USING ERRCODE = '22023';
  END IF;

  v_description := btrim(COALESCE(p_description, ''));

  IF length(v_description) < 1 OR length(v_description) > 2000 THEN
    RAISE EXCEPTION 'report description must be between 1 and 2000 characters'
      USING ERRCODE = '22023';
  END IF;

  SELECT b.status::text, b.worker_id, b.client_id
    INTO v_booking_status, v_booking_worker, v_booking_client
  FROM public.bookings AS b
  WHERE b.id = p_booking_id;

  IF NOT FOUND
     OR v_booking_status NOT IN ('confirmed', 'completed', 'cancelled')
     OR (v_role = 'worker' AND v_booking_worker IS DISTINCT FROM v_caller)
     OR (v_role = 'client' AND v_booking_client IS DISTINCT FROM v_caller)
  THEN
    RAISE EXCEPTION 'this booking is not available for reporting'
      USING ERRCODE = 'SM409';
  END IF;

  IF v_role = 'worker' THEN
    v_reported := v_booking_client;
  ELSE
    v_reported := v_booking_worker;
  END IF;

  IF v_reported IS NULL OR v_reported = v_caller THEN
    RAISE EXCEPTION 'this booking is not available for reporting'
      USING ERRCODE = 'SM409';
  END IF;

  BEGIN
    INSERT INTO public.reports (
      reporter_id,
      reported_user_id,
      booking_id,
      category,
      description,
      status,
      admin_response,
      reviewed_by,
      reviewed_at
    )
    VALUES (
      v_caller,
      v_reported,
      p_booking_id,
      v_category,
      v_description,
      'submitted',
      NULL,
      NULL,
      NULL
    )
    RETURNING id INTO v_report_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'this booking is not available for reporting'
        USING ERRCODE = 'SM409';
  END;

  FOR v_admin_id IN
    SELECT u.id
    FROM public.users AS u
    WHERE u.role = 'administrator'
      AND u.is_active = true
    ORDER BY u.id
  LOOP
    PERFORM private.emit_notification(
      v_admin_id,
      'report_submitted',
      'A new report needs Admin review.'
    );
  END LOOP;

  RETURN QUERY SELECT v_report_id;
END;
$$;

ALTER FUNCTION public.submit_my_booking_report(uuid, text, text) OWNER TO postgres;

COMMENT ON FUNCTION public.submit_my_booking_report(uuid, text, text) IS
  'R3 + V4 #16: Worker or Client counterpart report on a reportable '
  'Booking they participate in. Preserves R3 role, validation, '
  'participant derivation, duplicate, submitted-status, and error '
  'contracts. After INSERT, emits fixed report_submitted copy through '
  'private.emit_notification once per server-derived active '
  'Administrator. Report and persistent notifications are atomic; zero '
  'active Administrators is valid. No automatic disciplinary effect.';

REVOKE ALL ON FUNCTION public.submit_my_booking_report(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_my_booking_report(uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.submit_my_booking_report(uuid, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.submit_my_booking_report(uuid, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.submit_my_booking_report(uuid, text, text) TO authenticated;


-- ---------- 3. APP ISSUE PRODUCER ----------

CREATE OR REPLACE FUNCTION public.submit_my_app_issue(
  p_description text
)
RETURNS TABLE (report_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_role        text;
  v_description text;
  v_report_id   uuid;
  v_admin_id    uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to submit app issues'
      USING ERRCODE = '42501';
  END IF;

  SELECT u.role::text
    INTO v_role
  FROM public.users AS u
  WHERE u.id = v_caller;

  IF NOT FOUND OR v_role NOT IN ('worker', 'client') THEN
    RAISE EXCEPTION 'not authorized to submit app issues'
      USING ERRCODE = '42501';
  END IF;

  v_description := btrim(COALESCE(p_description, ''));

  IF length(v_description) < 1 OR length(v_description) > 2000 THEN
    RAISE EXCEPTION 'report description must be between 1 and 2000 characters'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.reports (
    reporter_id,
    reported_user_id,
    booking_id,
    category,
    description,
    status,
    admin_response,
    reviewed_by,
    reviewed_at
  )
  VALUES (
    v_caller,
    NULL,
    NULL,
    'app_issue',
    v_description,
    'submitted',
    NULL,
    NULL,
    NULL
  )
  RETURNING id INTO v_report_id;

  FOR v_admin_id IN
    SELECT u.id
    FROM public.users AS u
    WHERE u.role = 'administrator'
      AND u.is_active = true
    ORDER BY u.id
  LOOP
    PERFORM private.emit_notification(
      v_admin_id,
      'report_submitted',
      'A new report needs Admin review.'
    );
  END LOOP;

  RETURN QUERY SELECT v_report_id;
END;
$$;

ALTER FUNCTION public.submit_my_app_issue(text) OWNER TO postgres;

COMMENT ON FUNCTION public.submit_my_app_issue(text) IS
  'R3 + V4 #16: repeatable general app issue from an authenticated '
  'Worker or Client, preserving R3 validation, forced app_issue class, '
  'submitted status, and error contracts. After INSERT, emits fixed '
  'report_submitted copy through private.emit_notification once per '
  'server-derived active Administrator. Report and persistent '
  'notifications are atomic; zero active Administrators is valid. No '
  'automatic disciplinary effect.';

REVOKE ALL ON FUNCTION public.submit_my_app_issue(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_my_app_issue(text) FROM anon;
REVOKE ALL ON FUNCTION public.submit_my_app_issue(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.submit_my_app_issue(text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.submit_my_app_issue(text) TO authenticated;
