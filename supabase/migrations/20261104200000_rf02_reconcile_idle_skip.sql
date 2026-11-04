-- RF-02 call reconcile: skip the idle network round trip (2026-11-04).
--
-- On 2026-11-04 the hosted project depleted its free Disk IO Budget and stopped serving
-- Database, Auth and REST. pg_cron runs private.rf02_dispatch_reconcile(NULL) every
-- minute; each tick decrypts two Vault secrets, queues a pg_net request to the
-- booking-call-reconcile Edge Function, and that function calls rf02_call_reconcile_batch
-- back in the database: 1,440 round trips a day even when no call exists.
--
-- A tick now dispatches only when private.rf02_reconcile_batch would act on something,
-- using the same four conditions it acts on (ringing calls, accepted calls, cleanups that
-- are due, confirmed cleanups older than 7 days). A call_id dispatch (the termination fast
-- path) is unchanged. Function body below is the 20261015100000 body plus the guard.
--
-- Also: pg_cron never prunes cron.job_run_details. An hourly job keeps three days of run
-- history, deleting at most 5,000 rows per run so the existing backlog drains in small
-- batches instead of one large write on a project with a tight Disk IO budget.

CREATE OR REPLACE FUNCTION private.rf02_reconcile_has_work()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM private.booking_calls AS c WHERE c.state IN ('ringing', 'accepted'))
      OR EXISTS (SELECT 1 FROM private.booking_calls AS c
                 WHERE c.cleanup_state = 'pending' AND c.next_cleanup_at <= now())
      OR EXISTS (SELECT 1 FROM private.booking_calls AS c
                 WHERE c.cleanup_state = 'confirmed' AND c.cleanup_confirmed_at < now() - interval '7 days');
$$;

REVOKE ALL ON FUNCTION private.rf02_reconcile_has_work() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION private.rf02_dispatch_reconcile(p_call_id uuid DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_endpoint text;
  v_secret   text;
BEGIN
  -- Idle tick: nothing for the reconcile pass to do, so no Vault read and no request.
  IF p_call_id IS NULL AND NOT private.rf02_reconcile_has_work() THEN
    RETURN;
  END IF;
  SELECT ds.decrypted_secret INTO v_endpoint
  FROM vault.decrypted_secrets AS ds WHERE ds.name = 'rf02_call_reconcile_endpoint' LIMIT 1;
  SELECT ds.decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets AS ds WHERE ds.name = 'rf02_call_reconcile_secret' LIMIT 1;
  IF v_endpoint IS NULL OR btrim(v_endpoint) = '' OR v_secret IS NULL OR btrim(v_secret) = '' THEN
    RAISE WARNING 'RF-02 call reconcile dispatch skipped: vault config missing';
    RETURN;
  END IF;
  BEGIN
    PERFORM net.http_post(
      url := btrim(v_endpoint),
      body := CASE WHEN p_call_id IS NULL THEN jsonb_build_object('tick', true)
                   ELSE jsonb_build_object('call_id', p_call_id) END,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-skillmatch-dispatch-secret', v_secret),
      timeout_milliseconds := 5000
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'RF-02 call reconcile dispatch request failed';
  END;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'RF-02 call reconcile dispatch failed open';
END;
$$;

SELECT cron.schedule(
  'cron-run-history-trim',
  '17 * * * *',
  $$DELETE FROM cron.job_run_details WHERE runid IN (SELECT d.runid FROM cron.job_run_details AS d WHERE d.end_time < now() - interval '3 days' LIMIT 5000)$$
);
