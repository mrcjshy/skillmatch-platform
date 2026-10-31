-- RF-01/RF-02 concurrent termination — no resurrection after cancellation or
-- deactivation. Uses two extra sessions through dblink, so its fixtures are
-- COMMITTED and deleted again at the end.
--
-- Run ONLY on an identified disposable local stack right after
-- `npx supabase db reset --local`, with psql in autocommit mode:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/rf_termination_concurrency.sql
-- The dblink connection string targets the database from INSIDE the local
-- container (port 5432). Never point this file at a hosted project.
-- Expected: every NOTICE line is PASS and failed = 0.

CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE rfc_results (n int, name text, ok boolean, detail text);

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO rfc_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

-- ---------- committed disposable fixtures ----------
DO $$
DECLARE
  c1 uuid := '0c0c0c0c-0000-4000-8000-000000000001';
  w1 uuid := '0c0c0c0c-0000-4000-8000-000000000002';
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  SELECT '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
         crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
  FROM (VALUES (c1,'rfc-client@example.test'),(w1,'rfc-worker@example.test')) AS u(id,email);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (c1,'rfc-client@example.test','RFC Client','09170000301','client','Santa Ana','Pateros',true),
    (w1,'rfc-worker@example.test','RFC Worker','09170000302','worker','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES ('0c0c0c0c-0000-4000-8000-000000000012', w1, 'fixture', 'none', 'available', true);
  INSERT INTO public.job_postings(id, client_id, title, description, address, barangay, city, scheduled_at, status, budget) VALUES
    ('0c0c0c0c-1000-4000-8000-00000000000a', c1, 'RFC fixture A', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day', 'matched', 500),
    ('0c0c0c0c-1000-4000-8000-00000000000b', c1, 'RFC fixture B', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day', 'matched', 500),
    ('0c0c0c0c-1000-4000-8000-00000000000c', c1, 'RFC fixture C', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day', 'matched', 500);
  INSERT INTO public.bookings(id, job_id, worker_id, client_id, status) VALUES
    ('0c0c0c0c-2000-4000-8000-00000000000a', '0c0c0c0c-1000-4000-8000-00000000000a', w1, c1, 'confirmed'),
    ('0c0c0c0c-2000-4000-8000-00000000000b', '0c0c0c0c-1000-4000-8000-00000000000b', w1, c1, 'confirmed'),
    ('0c0c0c0c-2000-4000-8000-00000000000c', '0c0c0c0c-1000-4000-8000-00000000000c', w1, c1, 'confirmed');
END;
$$;

SELECT dblink_connect('rfc_b', 'host=localhost port=5432 dbname=postgres user=postgres password=postgres');
SELECT dblink_connect('rfc_a', 'host=localhost port=5432 dbname=postgres user=postgres password=postgres');

-- Session-local helper in each extra session: run one statement as a user.
SELECT dblink_exec(conn, $f$
  CREATE FUNCTION pg_temp.as_user(p_uid uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $b$
  DECLARE v text;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
    PERFORM set_config('role', 'authenticated', true);
    BEGIN
      EXECUTE p_sql INTO v;
    EXCEPTION WHEN OTHERS THEN v := 'ERR:' || SQLSTATE;
    END;
    PERFORM set_config('role', 'postgres', true);
    RETURN v;
  END $b$
$f$) FROM (VALUES ('rfc_a'), ('rfc_b')) AS t(conn);

-- ---------- 1. cancellation commits first; a waiting start must be denied ----------
SELECT dblink_exec('rfc_a', 'BEGIN');
SELECT dblink_exec('rfc_a', $$UPDATE public.bookings SET status = 'cancelled'
                              WHERE id = '0c0c0c0c-2000-4000-8000-00000000000a'$$);
SELECT dblink_send_query('rfc_b', $$SELECT pg_temp.as_user('0c0c0c0c-0000-4000-8000-000000000002',
  $q$SELECT public.start_my_booking_location_share('0c0c0c0c-2000-4000-8000-00000000000a')::text$q$)$$);
SELECT pg_sleep(0.5);
SELECT pg_temp.pass(1, 'start is blocked behind the uncommitted cancellation',
  dblink_is_busy('rfc_b') = 1);
SELECT dblink_exec('rfc_a', 'COMMIT');
SELECT pg_temp.pass(1, 'start after committed cancellation is denied 42501',
  (SELECT r FROM dblink_get_result('rfc_b') AS t(r text)) = 'ERR:42501');
SELECT * FROM dblink_get_result('rfc_b') AS t(r text);  -- drain
SELECT pg_temp.pass(1, 'no share row exists for the cancelled booking',
  NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = '0c0c0c0c-2000-4000-8000-00000000000a'));

-- ---------- 2. start commits first; the waiting cancellation deletes it ----------
SELECT dblink_exec('rfc_b', 'BEGIN');
SELECT pg_temp.pass(2, 'start inside open transaction succeeds',
  (SELECT r FROM dblink('rfc_b', $$SELECT pg_temp.as_user('0c0c0c0c-0000-4000-8000-000000000002',
     $q$SELECT public.start_my_booking_location_share('0c0c0c0c-2000-4000-8000-00000000000b')::text$q$)$$) AS t(r text)) ~ '^[0-9a-f-]{36}$');
SELECT dblink_send_query('rfc_a', $$UPDATE public.bookings SET status = 'cancelled'
                                   WHERE id = '0c0c0c0c-2000-4000-8000-00000000000b'$$);
SELECT pg_sleep(0.5);
SELECT pg_temp.pass(2, 'cancellation waits for the open start', dblink_is_busy('rfc_a') = 1);
SELECT dblink_exec('rfc_b', 'COMMIT');
SELECT * FROM dblink_get_result('rfc_a') AS t(r text);
SELECT * FROM dblink_get_result('rfc_a') AS t(r text);  -- drain
SELECT pg_temp.pass(2, 'row inserted before cancellation was deleted by the trigger',
  NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = '0c0c0c0c-2000-4000-8000-00000000000b'));

-- ---------- 3. deactivation commits first; a waiting call start is denied ----------
SELECT dblink_exec('rfc_a', 'BEGIN');
SELECT dblink_exec('rfc_a', $$UPDATE public.users SET is_active = false
                              WHERE id = '0c0c0c0c-0000-4000-8000-000000000002'$$);
SELECT dblink_send_query('rfc_b', $$SELECT public.rf02_call_start('0c0c0c0c-0000-4000-8000-000000000001',
                                  '0c0c0c0c-2000-4000-8000-00000000000c')::text$$);
SELECT pg_sleep(0.5);
SELECT pg_temp.pass(3, 'call start is blocked behind the uncommitted deactivation', dblink_is_busy('rfc_b') = 1);
SELECT dblink_exec('rfc_a', 'COMMIT');
SELECT * FROM dblink_get_result('rfc_b', false) AS t(r text);  -- expected: error 42501 (not fatal)
SELECT * FROM dblink_get_result('rfc_b', false) AS t(r text);  -- drain
SELECT pg_temp.pass(3, 'call start after committed deactivation creates no live call',
  NOT EXISTS (SELECT 1 FROM private.booking_calls
              WHERE booking_id = '0c0c0c0c-2000-4000-8000-00000000000c' AND state IN ('ringing', 'accepted')));
-- ---------- 4. accept/rejoin must lock Booking/users before Call ----------
-- A third session holds Call while the real action and termination queue.
-- With the old Call-first order they form a deadlock after the holder exits.
SELECT dblink_connect('rfc_hold', 'host=localhost port=5432 dbname=postgres user=postgres password=postgres');
SELECT dblink_exec('rfc_a', 'SET statement_timeout = ''6s''');
SELECT dblink_exec('rfc_b', 'SET statement_timeout = ''6s''');
SELECT dblink_exec('rfc_b', $f$
  CREATE FUNCTION pg_temp.exec_outcome(p_sql text) RETURNS text LANGUAGE plpgsql AS $b$
  BEGIN
    EXECUTE p_sql;
    RETURN 'ok';
  EXCEPTION WHEN OTHERS THEN RETURN 'ERR:' || SQLSTATE;
  END $b$
$f$);
DO $$
DECLARE
  v_action text;
  v_termination text;
  v_call uuid;
  v_json text;
  v_action_result text;
  v_termination_result text;
  v_booking uuid := '0c0c0c0c-2000-4000-8000-00000000000c';
  v_client uuid := '0c0c0c0c-0000-4000-8000-000000000001';
  v_worker uuid := '0c0c0c0c-0000-4000-8000-000000000002';
BEGIN
  FOREACH v_action IN ARRAY ARRAY['accept', 'rejoin'] LOOP
    FOREACH v_termination IN ARRAY ARRAY['cancellation', 'deactivation'] LOOP
      PERFORM dblink_exec('rfc_a', format('UPDATE public.users SET is_active = true WHERE id = %L', v_worker));
      PERFORM dblink_exec('rfc_a', format('UPDATE public.bookings SET status = ''cancelled'' WHERE id = %L', v_booking));
      PERFORM dblink_exec('rfc_a', format('UPDATE public.bookings SET status = ''confirmed'' WHERE id = %L', v_booking));
      SELECT r INTO v_json FROM dblink('rfc_a', format('SELECT public.rf02_call_start(%L,%L)::text', v_client, v_booking)) AS t(r text);
      v_call := (v_json::jsonb->'call'->>'call_id')::uuid;
      PERFORM r FROM dblink('rfc_a', format('SELECT public.rf02_call_record_provisioning(%L,''ready'')::text', v_call)) AS t(r text);
      IF v_action = 'rejoin' THEN
        PERFORM r FROM dblink('rfc_a', format('SELECT public.rf02_call_act(%L,%L,''accept'')::text', v_worker, v_call)) AS t(r text);
      END IF;
      PERFORM dblink_exec('rfc_hold', 'BEGIN');
      PERFORM r FROM dblink('rfc_hold', format('SELECT call_id::text FROM private.booking_calls WHERE call_id=%L FOR UPDATE', v_call)) AS t(r text);
      PERFORM dblink_send_query('rfc_a', format('SELECT public.rf02_call_act(%L,%L,%L)::text', v_worker, v_call, v_action));
      PERFORM pg_sleep(0.15);
      PERFORM dblink_send_query('rfc_b', format('SELECT pg_temp.exec_outcome(%L)',
        CASE WHEN v_termination = 'cancellation'
          THEN format('UPDATE public.bookings SET status=''cancelled'' WHERE id=%L', v_booking)
          ELSE format('UPDATE public.users SET is_active=false WHERE id=%L', v_worker) END));
      PERFORM pg_sleep(0.15);
      PERFORM pg_temp.pass(4, v_action || '/' || v_termination || ': both operations are waiting',
        dblink_is_busy('rfc_a') = 1 AND dblink_is_busy('rfc_b') = 1);
      PERFORM dblink_exec('rfc_hold', 'COMMIT');
      SELECT r INTO v_action_result FROM dblink_get_result('rfc_a', false) AS t(r text);
      PERFORM r FROM dblink_get_result('rfc_a', false) AS t(r text);
      SELECT r INTO v_termination_result FROM dblink_get_result('rfc_b', false) AS t(r text);
      PERFORM r FROM dblink_get_result('rfc_b', false) AS t(r text);
      PERFORM pg_temp.pass(4, v_action || '/' || v_termination || ': action and termination finish without deadlock',
        coalesce((v_action_result::jsonb->>'ok')::boolean, false) AND v_termination_result = 'ok',
        coalesce(v_action_result, 'no action result') || '/' || coalesce(v_termination_result, 'no termination result'));
      PERFORM pg_temp.pass(4, v_action || '/' || v_termination || ': termination leaves no live call',
        NOT EXISTS (SELECT 1 FROM private.booking_calls WHERE call_id = v_call AND state IN ('ringing','accepted')));
    END LOOP;
  END LOOP;
END $$;
SELECT dblink_disconnect('rfc_hold');
SELECT dblink_disconnect('rfc_a');
SELECT dblink_disconnect('rfc_b');

-- ---------- cleanup of committed fixtures ----------
DELETE FROM private.booking_calls WHERE booking_id::text LIKE '0c0c0c0c-%';
DELETE FROM private.booking_location_shares WHERE booking_id::text LIKE '0c0c0c0c-%';
DELETE FROM public.bookings WHERE id::text LIKE '0c0c0c0c-%';
DELETE FROM public.job_postings WHERE id::text LIKE '0c0c0c0c-%';
DELETE FROM public.worker_profiles WHERE user_id::text LIKE '0c0c0c0c-%';
DELETE FROM public.users WHERE id::text LIKE '0c0c0c0c-%';
DELETE FROM auth.users WHERE id::text LIKE '0c0c0c0c-%';

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM rfc_results;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM rfc_results WHERE NOT ok) THEN
    RAISE EXCEPTION 'RF concurrency SQL assertions failed';
  END IF;
END $$;
