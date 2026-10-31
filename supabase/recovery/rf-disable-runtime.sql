-- Compatible fail-closed RF recovery. Rehearse only on disposable local data.
-- Hosted execution requires a reviewed recovery decision. This retains every
-- table, row, migration-history entry, existing Admin RPC, and RF03 hardening.
-- It refuses to abandon active shares or unconfirmed provider cleanup.
-- OPERATOR PRECONDITION: disable the booking-call, booking-call-reconcile and
-- livekit-webhook Edge entry points, stop the reconcile scheduler, and drain
-- in-flight Edge/provider/DB work before execution. Confirm provider cleanup
-- independently. REVOKE does not cancel a definer function already executing;
-- this SQL guard does not establish endpoint or in-flight quiescence itself.
-- No hosted recovery was performed by the local rehearsal.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
LOCK TABLE private.booking_location_shares, private.booking_calls IN ACCESS EXCLUSIVE MODE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM private.booking_location_shares)
     OR EXISTS (SELECT 1 FROM private.booking_calls
                WHERE state IN ('ringing', 'accepted') OR cleanup_state <> 'confirmed') THEN
    RAISE EXCEPTION 'RF recovery requires no shares and provider-confirmed cleanup for every retained call';
  END IF;
END $$;
-- Use pg_cron's owner-checked API; cron.job is not directly writable.
SELECT cron.alter_job(jobid, active := false)
FROM cron.job WHERE jobname = 'rf02-call-reconcile';
REVOKE ALL ON FUNCTION public.start_my_booking_location_share(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.publish_my_booking_location(uuid,uuid,integer,double precision,double precision,real,timestamptz) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_booking_location_pins(uuid,uuid) FROM authenticated;
DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
           WHERE n.nspname='public' AND p.proname LIKE 'rf02_call_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role', f);
  END LOOP;
END $$;
DROP TRIGGER rf02_end_calls_for_booking ON public.bookings;
DROP TRIGGER rf02_end_calls_for_user ON public.users;
-- Location expiry/termination cleanup and explicit Stop RPCs stay available.
-- Original native clients retain their existing operations. Re-enabling RF
-- requires a new reviewed forward change, never migration-history deletion.
COMMIT;
