-- Recovered 2026-11-06 into the repository: applied to hosted on 2026-10-30 but missing here.
-- Worker-attested milestones (arrival, service completed), not GPS proof, payment settlement
-- or final Client completion. Statements as in the hosted supabase_migrations record.
DO $$ BEGIN
  IF has_table_privilege('authenticated','public.bookings','UPDATE')
     OR has_table_privilege('anon','public.bookings','UPDATE') THEN
    RAISE EXCEPTION 'Unexpected direct Booking UPDATE grant; review before migration';
  END IF;
END $$;
ALTER TABLE public.bookings
  ADD COLUMN worker_arrived_at timestamptz,
  ADD COLUMN worker_service_completed_at timestamptz,
  ADD CONSTRAINT bookings_worker_progress_order CHECK (
    worker_service_completed_at IS NULL OR
    (worker_arrived_at IS NOT NULL AND worker_service_completed_at >= worker_arrived_at)
  );
COMMENT ON COLUMN public.bookings.worker_arrived_at IS 'Assigned active Worker attests physical arrival through a narrow RPC; not location verification.';
COMMENT ON COLUMN public.bookings.worker_service_completed_at IS 'Assigned active Worker attests service completion after arrival; Booking stays confirmed, payment and final Client completion remain separate.';
REVOKE UPDATE (worker_arrived_at,worker_service_completed_at) ON public.bookings FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.get_my_worker_booking_progress(p_booking_id uuid)
RETURNS TABLE(booking_id uuid, arrived_at timestamptz, service_completed_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_arrived timestamptz; v_completed timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized for Worker progress' USING ERRCODE='42501';
  END IF;
  SELECT b.worker_arrived_at,b.worker_service_completed_at INTO v_arrived,v_completed
  FROM public.bookings b JOIN public.job_postings j ON j.id=b.job_id
  WHERE b.id=p_booking_id AND b.worker_id=auth.uid() AND b.status::text='confirmed'
    AND j.status::text='matched' AND j.client_id=b.client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking progress unavailable' USING ERRCODE='SM409'; END IF;
  RETURN QUERY SELECT p_booking_id,v_arrived,v_completed;
END $$;

CREATE FUNCTION public.confirm_my_worker_booking_progress(p_booking_id uuid,p_step text)
RETURNS TABLE(booking_id uuid, arrived_at timestamptz, service_completed_at timestamptz)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_status text; v_worker uuid; v_client uuid; v_job uuid;
  v_arrived timestamptz; v_completed timestamptz; v_stamp timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized for Worker progress' USING ERRCODE='42501';
  END IF;
  SELECT b.status::text,b.worker_id,b.client_id,b.job_id,b.worker_arrived_at,b.worker_service_completed_at
    INTO v_status,v_worker,v_client,v_job,v_arrived,v_completed
  FROM public.bookings b WHERE b.id=p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_worker IS DISTINCT FROM auth.uid() OR v_status IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'booking progress unavailable' USING ERRCODE='SM409';
  END IF;
  -- Booking then Job matches the final-completion lock order. No Job mutation.
  PERFORM 1 FROM public.job_postings j WHERE j.id=v_job AND j.status::text='matched' AND j.client_id=v_client FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'booking progress unavailable' USING ERRCODE='SM409'; END IF;
  IF p_step IS NULL OR p_step NOT IN ('arrive','complete') THEN
    RAISE EXCEPTION 'invalid Worker progress step' USING ERRCODE='22023';
  END IF;
  v_stamp := clock_timestamp();
  IF p_step='arrive' AND v_arrived IS NULL THEN
    UPDATE public.bookings SET worker_arrived_at=v_stamp WHERE id=p_booking_id;
    v_arrived := v_stamp;
  ELSIF p_step='complete' THEN
    IF v_arrived IS NULL THEN RAISE EXCEPTION 'arrival must be confirmed first' USING ERRCODE='SM409'; END IF;
    IF v_completed IS NULL THEN
      v_completed := greatest(v_stamp,v_arrived);
      UPDATE public.bookings SET worker_service_completed_at=v_completed WHERE id=p_booking_id;
    END IF;
  END IF;
  -- Repeated confirmations preserve the original timestamps and cause no extra UPDATE.
  RETURN QUERY SELECT p_booking_id,v_arrived,v_completed;
END $$;
ALTER FUNCTION public.get_my_worker_booking_progress(uuid) OWNER TO postgres;
ALTER FUNCTION public.confirm_my_worker_booking_progress(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_my_worker_booking_progress(uuid) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.confirm_my_worker_booking_progress(uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_worker_booking_progress(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_my_worker_booking_progress(uuid,text) TO authenticated;
