-- ============================================================
-- NOSHOW-01: CLIENT NO-SHOW REPORT AND PAST-DATE OPPORTUNITIES
-- ============================================================
--
-- SCOPE
-- -----
-- Owner decision 2026-11-06 (options B and C). Before this migration nothing
-- closed a confirmed booking whose time had passed, the 'no_show' booking
-- status was never set, and an open Job whose time had passed still matched
-- and could still be accepted.
--
-- B. public.report_worker_no_show(p_booking_id): the booking's own Client may
--    close it as 'no_show' once 1 hour has passed since the Job's scheduled
--    time, when the Worker has not confirmed arrival and payment has not
--    started (the same payment rule as cancel_my_booking). In one transaction:
--      * a 'no-show' report is filed through submit_my_booking_report, so the
--        Administrators are alerted as for any report (an earlier report by
--        the same Client on this booking is kept instead: one per booking);
--      * the booking becomes 'no_show' and the Job 'cancelled', so the Client
--        can post again; existing triggers end location shares and calls;
--      * the Worker gets a 'booking_no_show' notification.
--    No strike is given here: strikes stay Administrator-reviewed (FT-05).
--
-- C. An open Job whose scheduled time has passed is no longer listed by
--    list_my_job_opportunities and cannot be accepted (SM409, the same answer
--    as a Job that is no longer open). compute_job_matches is not changed.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No scheduled job and no automatic closing: a person always acts.
--   * No table, column, RLS or grant change on user data.
-- ============================================================


-- ---------- 1. NOTIFICATION TYPE ----------

ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (
  (type)::text = ANY (ARRAY[
    'booking_request', 'booking_confirmed', 'booking_cancelled', 'booking_completed',
    'no_show_strike', 'account_suspended', 'account_reinstated', 'payment_received',
    'worker_verified', 'report_submitted',
    'identity_submitted', 'worker_registered', 'client_registered',
    'booking_no_show'
  ]::text[])
);


-- ---------- 2. B: THE CLIENT REPORTS A NO-SHOW ----------

CREATE OR REPLACE FUNCTION public.report_worker_no_show(p_booking_id uuid)
RETURNS TABLE(booking_id uuid, booking_status text, job_status text, report_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_status     text;
  v_client     uuid;
  v_worker     uuid;
  v_job        uuid;
  v_arrived    timestamptz;
  v_method     text;
  v_payment    text;
  v_ref        text;
  v_job_status text;
  v_job_client uuid;
  v_title      text;
  v_scheduled  timestamptz;
  v_report     uuid := NULL;
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to report a no-show' USING ERRCODE = '42501';
  END IF;

  -- Booking, then Job: the same lock order as cancel_my_booking.
  SELECT b.status::text, b.client_id, b.worker_id, b.job_id, b.worker_arrived_at,
         b.payment_method::text, b.payment_status::text, b.paymongo_ref::text
    INTO v_status, v_client, v_worker, v_job, v_arrived, v_method, v_payment, v_ref
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND OR v_client IS DISTINCT FROM v_caller OR v_status IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'this booking is not available for a no-show report' USING ERRCODE = 'SM409';
  END IF;

  IF v_arrived IS NOT NULL THEN
    RAISE EXCEPTION 'the Worker already confirmed arrival' USING ERRCODE = 'SM409';
  END IF;

  IF (
       (v_method IS NULL AND v_payment = 'pending' AND v_ref IS NULL)
    OR (v_method = 'cod' AND v_payment = 'pending' AND v_ref IS NULL)
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'this booking cannot be closed in its current payment state' USING ERRCODE = 'SM403';
  END IF;

  SELECT jp.status::text, jp.client_id, jp.title::text, jp.scheduled_at
    INTO v_job_status, v_job_client, v_title, v_scheduled
  FROM public.job_postings AS jp
  WHERE jp.id = v_job
  FOR UPDATE;

  IF NOT FOUND OR v_job_status IS DISTINCT FROM 'matched' OR v_job_client IS DISTINCT FROM v_client THEN
    RAISE EXCEPTION 'this booking is not available for a no-show report' USING ERRCODE = 'SM409';
  END IF;

  IF v_scheduled IS NULL OR clock_timestamp() < v_scheduled + interval '1 hour' THEN
    RAISE EXCEPTION 'a no-show can be reported 1 hour after the scheduled time' USING ERRCODE = 'SM409';
  END IF;

  -- The report for the Administrators (one per Client per booking: an earlier one is kept).
  IF NOT EXISTS (
    SELECT 1 FROM public.reports AS r WHERE r.reporter_id = v_caller AND r.booking_id = p_booking_id
  ) THEN
    SELECT s.report_id INTO v_report
    FROM public.submit_my_booking_report(
      p_booking_id,
      'no-show',
      'The Worker did not arrive and did not confirm arrival within 1 hour of the scheduled time.'
    ) AS s;
  END IF;

  UPDATE public.bookings SET status = 'no_show' WHERE id = p_booking_id;
  UPDATE public.job_postings SET status = 'cancelled' WHERE id = v_job;

  PERFORM private.emit_notification(
    v_worker,
    'booking_no_show',
    'The Client reported that you did not arrive for "' || v_title || '". An Administrator will review it.'
  );

  RETURN QUERY SELECT p_booking_id, 'no_show'::text, 'cancelled'::text, v_report;
END;
$$;

ALTER FUNCTION public.report_worker_no_show(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.report_worker_no_show(uuid) IS
  'NOSHOW-01: the booking''s active Client closes a confirmed booking as no_show 1 hour after '
  'the Job''s scheduled time when the Worker has not confirmed arrival and payment has not '
  'started. Files a no-show report (unless the Client already reported this booking), cancels '
  'the Job and notifies the Worker. No strike. 42501 not a Client; SM409 not available/too early/'
  'arrived; SM403 payment started.';

REVOKE ALL ON FUNCTION public.report_worker_no_show(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.report_worker_no_show(uuid) TO authenticated;


-- ---------- 3. C: PAST-DATE JOBS ARE NOT LISTED ----------

CREATE OR REPLACE FUNCTION public.list_my_job_opportunities()
RETURNS TABLE(job_id uuid, title character varying, description text, barangay character varying, city character varying, budget numeric, scheduled_at timestamp with time zone, skill_points numeric, location_points numeric, rating_points numeric, total_points numeric, payment_method character varying)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  ----------------------------------------------------------------
  -- CALLER GATE -- unchanged from N8-W-01
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized for worker opportunities'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- OPPORTUNITIES
  --
  -- Same open-Job filter, same LATERAL scorer, same privacy: no join
  -- to the Client's public.users row, no address. R4 adds the Job's
  -- posting-time payment_method (cod, qrph, or NULL for legacy).
  -- NOSHOW-01 leaves out a Job whose scheduled time has passed.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT
    jp.id,
    jp.title,
    jp.description,
    jp.barangay,
    jp.city,
    jp.budget,
    jp.scheduled_at,
    m.skill_points,
    m.location_points,
    m.rating_points,
    m.total_points,
    jp.payment_method
  FROM public.job_postings AS jp
  CROSS JOIN LATERAL private.compute_job_matches(jp.id) AS m
  WHERE jp.status = 'open'
    AND (jp.scheduled_at IS NULL OR jp.scheduled_at > now())
    AND m.worker_id = v_caller
  ORDER BY
    m.total_points DESC,
    jp.scheduled_at ASC NULLS LAST,
    jp.id ASC;
END;
$$;


-- ---------- 4. C: PAST-DATE JOBS CANNOT BE ACCEPTED ----------

CREATE OR REPLACE FUNCTION public.accept_job_opportunity(p_job_id uuid)
RETURNS TABLE(booking_id uuid, job_id uuid, booking_status text, job_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_job_status text;
  v_client_id  uuid;
  v_job_title  text;
  v_scheduled  timestamptz;
  v_booking_id uuid;
BEGIN
  -- 1. Caller authorization (account level); every denial raises the same error.
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized to accept opportunities'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Lock the target Job before any eligibility work: one Job, one winner.
  SELECT jp.status::text, jp.client_id, jp.title::text, jp.scheduled_at
    INTO v_job_status, v_client_id, v_job_title, v_scheduled
  FROM public.job_postings AS jp
  WHERE jp.id = p_job_id
  FOR UPDATE;

  -- 3. The Job must still be open, and (NOSHOW-01) its scheduled time must not
  --    have passed. All three cases give the same answer, so a Worker learns
  --    nothing about Jobs they were never matched to.
  IF NOT FOUND OR v_job_status IS DISTINCT FROM 'open'
     OR (v_scheduled IS NOT NULL AND v_scheduled <= now()) THEN
    RAISE EXCEPTION 'this opportunity is no longer available'
      USING ERRCODE = 'SM409';
  END IF;

  -- 4. Acceptance-time eligibility through the authoritative scorer (D-002 Stage 1).
  PERFORM 1
  FROM private.compute_job_matches(p_job_id) AS m
  WHERE m.worker_id = v_caller;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'you are no longer eligible for this opportunity'
      USING ERRCODE = 'SM403';
  END IF;

  -- 5. Atomic writes: the Worker's acceptance is the confirmation (D-003).
  INSERT INTO public.bookings (job_id, worker_id, client_id, status)
  VALUES (p_job_id, v_caller, v_client_id, 'confirmed')
  RETURNING public.bookings.id INTO v_booking_id;

  UPDATE public.job_postings AS jp
  SET status = 'matched'
  WHERE jp.id = p_job_id;

  -- 5b. Notifications (N12), same transaction, no exception handler.
  PERFORM private.emit_notification(
    v_client_id,
    'booking_confirmed',
    'Your job "' || v_job_title || '" has been accepted.'
  );

  PERFORM private.emit_notification(
    v_caller,
    'booking_confirmed',
    'Your booking for "' || v_job_title || '" is confirmed.'
  );

  -- 6. The minimum projection, read back from the persisted rows.
  RETURN QUERY
  SELECT b.id, b.job_id, b.status::text, jp.status::text
  FROM public.bookings AS b
  JOIN public.job_postings AS jp ON jp.id = b.job_id
  WHERE b.id = v_booking_id;
END;
$$;
