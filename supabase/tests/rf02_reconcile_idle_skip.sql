-- RF-02 reconcile idle skip — local SQL verification. Disposable fixtures only; ROLLBACKs.
-- Run ONLY against an identified disposable local stack with no network. The test writes
-- temporary rf02 Vault secrets pointing at a closed loopback port; requests it queues are
-- uncommitted, so the pg_net worker never sees them.
-- Expected: every NOTICE line is PASS; the final row shows failed = 0.

BEGIN;

CREATE TEMP TABLE idle_results (n int, name text, ok boolean, detail text);

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO idle_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

-- Requests queued by one dispatch call: returns how many rows it added and the last body.
CREATE OR REPLACE FUNCTION pg_temp.dispatch(p_call uuid)
RETURNS TABLE(added bigint, body text) LANGUAGE plpgsql AS $$
DECLARE v_before bigint; v_max bigint;
BEGIN
  SELECT count(*), coalesce(max(q.id), 0) INTO v_before, v_max FROM net.http_request_queue AS q;
  PERFORM private.rf02_dispatch_reconcile(p_call);
  RETURN QUERY
    SELECT (SELECT count(*) FROM net.http_request_queue) - v_before,
           (SELECT convert_from(q.body, 'UTF8') FROM net.http_request_queue AS q
            WHERE q.id > v_max ORDER BY q.id DESC LIMIT 1);
END;
$$;

DO $$
DECLARE
  c1 uuid := '02020203-0000-4000-8000-000000000001';
  w1 uuid := '02020203-0000-4000-8000-000000000002';
  job uuid := '02020203-1000-4000-8000-00000000000a';
  bk  uuid := '02020203-2000-4000-8000-00000000000a';
  call1 uuid;
  r record;
BEGIN
  -- 0 isolation preconditions
  PERFORM pg_temp.pass(0, 'no rf02 Vault secrets before the test',
    NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name LIKE 'rf02_%'));
  PERFORM pg_temp.pass(0, 'no booking calls before the test', NOT EXISTS (SELECT 1 FROM private.booking_calls));
  PERFORM vault.create_secret('http://127.0.0.1:9/rf02-local-test', 'rf02_call_reconcile_endpoint');
  PERFORM vault.create_secret('local-test-secret', 'rf02_call_reconcile_secret');

  -- 1 idle tick: no work, no request
  PERFORM pg_temp.pass(1, 'helper reports no work on an empty table', NOT private.rf02_reconcile_has_work());
  SELECT * INTO r FROM pg_temp.dispatch(NULL);
  PERFORM pg_temp.pass(1, 'idle tick queues no request', r.added = 0, r.added::text);

  -- 2 call_id fast path always dispatches, even with no work
  SELECT * INTO r FROM pg_temp.dispatch('02020203-3000-4000-8000-000000000001');
  PERFORM pg_temp.pass(2, 'call_id dispatch queues one request', r.added = 1, r.added::text);
  PERFORM pg_temp.pass(2, 'call_id dispatch body names the call',
    r.body::jsonb = jsonb_build_object('call_id', '02020203-3000-4000-8000-000000000001'::uuid), r.body);

  -- fixtures: one confirmed booking between c1 and w1
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  SELECT '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
         crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
  FROM (VALUES (c1,'rf02idle-client@example.test'),(w1,'rf02idle-worker@example.test')) AS u(id,email);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (c1,'rf02idle-client@example.test','RF02 Idle Client','09170000301','client','Santa Ana','Pateros',true),
    (w1,'rf02idle-worker@example.test','RF02 Idle Worker','09170000302','worker','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES ('02020203-0000-4000-8000-000000000012', w1, 'fixture', 'none', 'available', true);
  INSERT INTO public.job_postings(id, client_id, title, description, address, barangay, city, scheduled_at, status, budget)
  VALUES (job, c1, 'RF02 idle fixture', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros',
          now() + interval '1 day', 'matched', 500);
  INSERT INTO public.bookings(id, job_id, worker_id, client_id, status) VALUES (bk, job, w1, c1, 'confirmed');

  -- 3 a ringing call is work; the tick dispatches with the tick body
  INSERT INTO private.booking_calls(booking_id, caller_id, callee_id) VALUES (bk, c1, w1) RETURNING call_id INTO call1;
  PERFORM pg_temp.pass(3, 'ringing call is work', private.rf02_reconcile_has_work());
  SELECT * INTO r FROM pg_temp.dispatch(NULL);
  PERFORM pg_temp.pass(3, 'tick with a ringing call queues one request', r.added = 1, r.added::text);
  PERFORM pg_temp.pass(3, 'tick body is {"tick": true}', r.body::jsonb = '{"tick": true}'::jsonb, r.body);

  -- 4 an accepted call is work
  UPDATE private.booking_calls SET state = 'accepted', answered_at = now() WHERE call_id = call1;
  PERFORM pg_temp.pass(4, 'accepted call is work', private.rf02_reconcile_has_work());
  SELECT * INTO r FROM pg_temp.dispatch(NULL);
  PERFORM pg_temp.pass(4, 'tick with an accepted call queues one request', r.added = 1, r.added::text);

  -- 5 an ended call whose cleanup is not yet due is not work
  UPDATE private.booking_calls
  SET state = 'ended', end_reason = 'hung_up', ended_at = now(), cleanup_state = 'pending',
      next_cleanup_at = now() + interval '10 minutes'
  WHERE call_id = call1;
  PERFORM pg_temp.pass(5, 'cleanup not due is not work', NOT private.rf02_reconcile_has_work());
  SELECT * INTO r FROM pg_temp.dispatch(NULL);
  PERFORM pg_temp.pass(5, 'tick with cleanup not due queues no request', r.added = 0, r.added::text);

  -- 6 a due cleanup is work
  UPDATE private.booking_calls SET next_cleanup_at = now() - interval '1 second' WHERE call_id = call1;
  PERFORM pg_temp.pass(6, 'due cleanup is work', private.rf02_reconcile_has_work());
  SELECT * INTO r FROM pg_temp.dispatch(NULL);
  PERFORM pg_temp.pass(6, 'tick with a due cleanup queues one request', r.added = 1, r.added::text);

  -- 7 a recently confirmed cleanup is not work; one older than 7 days is (the batch deletes it)
  UPDATE private.booking_calls
  SET cleanup_state = 'confirmed', cleanup_confirmed_at = now() - interval '1 day', next_cleanup_at = NULL
  WHERE call_id = call1;
  PERFORM pg_temp.pass(7, 'recent confirmed cleanup is not work', NOT private.rf02_reconcile_has_work());
  SELECT * INTO r FROM pg_temp.dispatch(NULL);
  PERFORM pg_temp.pass(7, 'tick with recent confirmed cleanup queues no request', r.added = 0, r.added::text);
  UPDATE private.booking_calls SET cleanup_confirmed_at = now() - interval '8 days' WHERE call_id = call1;
  PERFORM pg_temp.pass(7, 'confirmed cleanup older than 7 days is work', private.rf02_reconcile_has_work());
  SELECT * INTO r FROM pg_temp.dispatch(NULL);
  PERFORM pg_temp.pass(7, 'tick with an expired confirmed row queues one request', r.added = 1, r.added::text);

  -- 8 a failed cleanup is not work (the batch never selects it)
  UPDATE private.booking_calls SET cleanup_state = 'failed', cleanup_confirmed_at = NULL WHERE call_id = call1;
  PERFORM pg_temp.pass(8, 'failed cleanup is not work', NOT private.rf02_reconcile_has_work());

  -- 9 the batch agrees: on a no-work state it changes nothing
  PERFORM private.rf02_reconcile_batch(50);
  PERFORM pg_temp.pass(9, 'batch leaves the no-work row unchanged',
    (SELECT cleanup_state = 'failed' AND state = 'ended' FROM private.booking_calls WHERE call_id = call1));
END;
$$;

-- 10 privileges and definition
SELECT pg_temp.pass(10, 'helper not executable by anon',
  NOT has_function_privilege('anon', 'private.rf02_reconcile_has_work()', 'EXECUTE'));
SELECT pg_temp.pass(10, 'helper not executable by authenticated',
  NOT has_function_privilege('authenticated', 'private.rf02_reconcile_has_work()', 'EXECUTE'));
SELECT pg_temp.pass(10, 'helper not executable by service_role',
  NOT has_function_privilege('service_role', 'private.rf02_reconcile_has_work()', 'EXECUTE'));
SELECT pg_temp.pass(10, 'helper is security definer with empty search_path',
  (SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=""'] FROM pg_proc AS p
   WHERE p.oid = 'private.rf02_reconcile_has_work()'::regprocedure));
SELECT pg_temp.pass(10, 'dispatch keeps security definer with empty search_path',
  (SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=""'] FROM pg_proc AS p
   WHERE p.oid = 'private.rf02_dispatch_reconcile(uuid)'::regprocedure));
SELECT pg_temp.pass(10, 'dispatch not executable by anon',
  NOT has_function_privilege('anon', 'private.rf02_dispatch_reconcile(uuid)', 'EXECUTE'));

-- 11 cron jobs: reconcile tick unchanged, history trim scheduled daily
SELECT pg_temp.pass(11, 'reconcile tick still every minute',
  EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'rf02-call-reconcile' AND schedule = '* * * * *'
          AND command = 'SELECT private.rf02_dispatch_reconcile(NULL)' AND active));
SELECT pg_temp.pass(11, 'history trim scheduled hourly',
  EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cron-run-history-trim' AND schedule = '17 * * * *' AND active));

-- 12 the trim job's own command: deletes old runs in batches of 5,000, keeps recent and running ones
-- explicit run ids: the test role cannot use pg_cron's run id sequence (the trim never needs it)
INSERT INTO cron.job_run_details(jobid, runid, command, status, start_time, end_time)
SELECT 990001, 990000000 + g, 'fixture old', 'succeeded', now() - interval '5 days', now() - interval '5 days'
FROM generate_series(1, 5002) AS g;
INSERT INTO cron.job_run_details(jobid, runid, command, status, start_time, end_time) VALUES
  (990001, 990100001, 'fixture recent', 'succeeded', now() - interval '1 day', now() - interval '1 day'),
  (990001, 990100002, 'fixture running', 'running', now() - interval '5 days', NULL);
DO $$ BEGIN EXECUTE (SELECT command FROM cron.job WHERE jobname = 'cron-run-history-trim'); END $$;
SELECT pg_temp.pass(12, 'one run deletes at most 5,000 old rows',
  (SELECT count(*) FROM cron.job_run_details WHERE jobid = 990001 AND command = 'fixture old') = 2);
DO $$ BEGIN EXECUTE (SELECT command FROM cron.job WHERE jobname = 'cron-run-history-trim'); END $$;
SELECT pg_temp.pass(12, 'next run clears the rest of the old rows',
  NOT EXISTS (SELECT 1 FROM cron.job_run_details WHERE jobid = 990001 AND command = 'fixture old'));
SELECT pg_temp.pass(12, 'recent run history kept',
  EXISTS (SELECT 1 FROM cron.job_run_details WHERE jobid = 990001 AND command = 'fixture recent'));
SELECT pg_temp.pass(12, 'running job row (no end_time) kept',
  EXISTS (SELECT 1 FROM cron.job_run_details WHERE jobid = 990001 AND command = 'fixture running'));

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM idle_results;

ROLLBACK;
