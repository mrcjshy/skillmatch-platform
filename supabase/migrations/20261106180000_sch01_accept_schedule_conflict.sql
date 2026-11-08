-- ============================================================
-- SCH-01: A WORKER CANNOT ACCEPT TWO JOBS AT THE SAME TIME
-- ============================================================
--
-- Owner decision 2026-11-06: a Worker may not accept a Job scheduled within
-- 3 hours (before or after) of one of their confirmed bookings. Jobs only have
-- a start time (scheduled_at), so 3 hours either side is the occupied window.
-- Completed, cancelled and no-show bookings do not occupy time.
--
-- Only public.accept_job_opportunity changes. It is copied from NOSHOW-01
-- (20261106140000, the version on hosted) with two additions:
--   1b. a transaction advisory lock per Worker, so two acceptances by the same
--       Worker run one after the other and cannot both pass the check;
--   4b. the schedule check, which raises SM422. Installed builds show their
--       generic "couldn't accept" message for this code.
-- Grants, owner, SECURITY DEFINER and search_path are unchanged.
--
-- Rollback: re-run the NOSHOW-01 definition of accept_job_opportunity.

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

  -- 1b. SCH-01: one acceptance at a time per Worker, so two Jobs accepted at once cannot both
  --     pass the schedule check below. Only this function takes this lock.
  PERFORM pg_advisory_xact_lock(hashtextextended('sch01:accept:' || v_caller::text, 0));

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

  -- 4b. SCH-01 (owner, 2026-11-06): no two bookings within 3 hours of each other. A Job has no
  --     duration, so a confirmed booking occupies its scheduled time plus or minus 3 hours.
  --     Exactly 3 hours apart is allowed. A Job with no time set never conflicts.
  IF v_scheduled IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.bookings AS b
    JOIN public.job_postings AS other ON other.id = b.job_id
    WHERE b.worker_id = v_caller
      AND b.status = 'confirmed'
      AND other.id <> p_job_id
      AND other.scheduled_at > v_scheduled - interval '3 hours'
      AND other.scheduled_at < v_scheduled + interval '3 hours'
  ) THEN
    RAISE EXCEPTION 'you already have a booking within 3 hours of this job'
      USING ERRCODE = 'SM422';
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

ALTER FUNCTION public.accept_job_opportunity(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.accept_job_opportunity(uuid) TO authenticated;
