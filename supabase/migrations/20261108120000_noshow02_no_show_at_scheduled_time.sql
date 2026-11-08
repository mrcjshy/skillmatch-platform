-- ============================================================
-- NOSHOW-02: A CLIENT MAY REPORT A NO-SHOW FROM THE SCHEDULED TIME
-- ============================================================
--
-- SCOPE
-- -----
-- Owner decision 2026-11-08: the Client's "Worker didn't show up" is offered
-- from the Job's scheduled time, not 1 hour after it (NOSHOW-01). This
-- migration re-creates public.report_worker_no_show(uuid) from the NOSHOW-01
-- body with three changes only:
--   * the time check is clock_timestamp() < scheduled_at (was + 1 hour);
--   * its SM409 message and the filed report's description no longer say
--     "1 hour";
--   * the function comment.
-- Everything else is unchanged: who may call it, the booking/Job lock order,
-- the arrival and payment rules, the one-report-per-booking rule, the
-- booking/Job status changes, the Worker notification, no strike, owner,
-- SECURITY DEFINER, the empty search_path and the grants.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No table, column, constraint, RLS or grant change on user data.
--   * No change to list_my_job_opportunities or accept_job_opportunity.
--
-- ROLLBACK
-- --------
-- Re-run section 2 of 20261106140000_noshow01_client_no_show_and_expiry.sql
-- (the NOSHOW-01 report_worker_no_show, its comment and grants).
-- ============================================================

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

  -- NOSHOW-02: from the scheduled time (NOSHOW-01 waited 1 hour after it).
  IF v_scheduled IS NULL OR clock_timestamp() < v_scheduled THEN
    RAISE EXCEPTION 'a no-show can be reported from the scheduled time' USING ERRCODE = 'SM409';
  END IF;

  -- The report for the Administrators (one per Client per booking: an earlier one is kept).
  IF NOT EXISTS (
    SELECT 1 FROM public.reports AS r WHERE r.reporter_id = v_caller AND r.booking_id = p_booking_id
  ) THEN
    SELECT s.report_id INTO v_report
    FROM public.submit_my_booking_report(
      p_booking_id,
      'no-show',
      'The Worker did not arrive and had not confirmed arrival by the scheduled time.'
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
  'NOSHOW-02: the booking''s active Client closes a confirmed booking as no_show from the '
  'Job''s scheduled time when the Worker has not confirmed arrival and payment has not '
  'started. Files a no-show report (unless the Client already reported this booking), cancels '
  'the Job and notifies the Worker. No strike. 42501 not a Client; SM409 not available/too early/'
  'arrived; SM403 payment started.';

REVOKE ALL ON FUNCTION public.report_worker_no_show(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.report_worker_no_show(uuid) TO authenticated;
