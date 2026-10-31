-- RF-04 Worker-only live location — local SQL verification. Disposable fixtures only.
-- Run ONLY against an identified disposable local stack after
-- `npx supabase db reset --local` (which applies RF-01..RF-04). The outer transaction ROLLBACKs.
-- Expected: every NOTICE line is PASS; the final row shows failed = 0.

BEGIN;

CREATE TEMP TABLE rf04_results (n int, name text, ok boolean, detail text);
GRANT INSERT ON rf04_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO rf04_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.q(p_sql text, p_uid uuid)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('role', 'authenticated', true);
  BEGIN
    EXECUTE p_sql INTO v;
  EXCEPTION WHEN OTHERS THEN v := 'ERR:' || SQLSTATE;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'postgres', true);
  RETURN v;
END;
$$;

DO $$
DECLARE
  c1 uuid := '04040404-0000-4000-8000-000000000001';
  w1 uuid := '04040404-0000-4000-8000-000000000002';
  c2 uuid := '04040404-0000-4000-8000-000000000003';
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  SELECT '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
         crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
  FROM (VALUES (c1,'rf04-client1@example.test'),(w1,'rf04-worker1@example.test'),(c2,'rf04-client2@example.test')) AS u(id,email);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (c1,'rf04-client1@example.test','RF04 Client One','09170000401','client','Santa Ana','Pateros',true),
    (w1,'rf04-worker1@example.test','RF04 Worker One','09170000402','worker','Santa Ana','Pateros',true),
    (c2,'rf04-client2@example.test','RF04 Client Two','09170000403','client','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified) VALUES
    ('04040404-0000-4000-8000-000000000012',w1,'fixture','none','available',true);
  -- A: confirmed c1/w1.  P: pending c1/w1.
  INSERT INTO public.job_postings(id, client_id, title, description, address, barangay, city, scheduled_at, status, budget) VALUES
    ('04040404-1000-4000-8000-00000000000a', c1, 'RF04 fixture', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day', 'matched', 500),
    ('04040404-1000-4000-8000-00000000000c', c1, 'RF04 fixture', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day', 'matched', 500);
  INSERT INTO public.bookings(id, job_id, worker_id, client_id, status) VALUES
    ('04040404-2000-4000-8000-00000000000a','04040404-1000-4000-8000-00000000000a',w1,c1,'confirmed'),
    ('04040404-2000-4000-8000-00000000000c','04040404-1000-4000-8000-00000000000c',w1,c1,'pending');
END;
$$;

DO $$
DECLARE
  c1 uuid := '04040404-0000-4000-8000-000000000001';
  w1 uuid := '04040404-0000-4000-8000-000000000002';
  c2 uuid := '04040404-0000-4000-8000-000000000003';
  a  uuid := '04040404-2000-4000-8000-00000000000a';
  p  uuid := '04040404-2000-4000-8000-00000000000c';
  s_w1 text; r text; v_json jsonb;
  pub text := 'SELECT public.publish_my_booking_location(%L,%L,%s,%s,121.0686,5,now())';
BEGIN
  -- 1 the Booking's Worker may start
  s_w1 := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), w1);
  PERFORM pg_temp.pass(1, 'Worker start returns share uuid', s_w1 ~ '^[0-9a-f-]{36}$', s_w1);

  -- 2 the Booking's Client may not start (no Client GPS)
  r := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), c1);
  PERFORM pg_temp.pass(2, 'Client start 42501', r = 'ERR:42501', r);
  PERFORM pg_temp.pass(2, 'no Client row created',
    NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = a AND user_id = c1));

  -- 3 an obsolete Client build cannot publish, even with a guessed share id
  r := pg_temp.q(format(pub, a, s_w1, 1, '14.547'), c1);
  PERFORM pg_temp.pass(3, 'Client publish 42501', r = 'ERR:42501', r);
  r := pg_temp.q(format(pub, a, gen_random_uuid(), 1, '14.547'), c1);
  PERFORM pg_temp.pass(3, 'Client publish with random share 42501', r = 'ERR:42501', r);

  -- 4 the Worker publishes
  r := pg_temp.q(format(pub, a, s_w1, 1, '14.5456'), w1);
  PERFORM pg_temp.pass(4, 'Worker publish ok', r = 'ok', r);

  -- 5 the Client reads the Worker's position
  v_json := pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), c1)::jsonb;
  PERFORM pg_temp.pass(5, 'Client receives the Worker pin',
    v_json->'counterpart'->>'role' = 'worker' AND (v_json->'counterpart'->>'latitude')::float8 = 14.5456, v_json::text);
  PERFORM pg_temp.pass(5, 'share id never returned to the Client', position(s_w1 in v_json::text) = 0);

  -- 6 a legacy Client row (written under RF-01) is never released to the Worker
  INSERT INTO private.booking_location_shares (booking_id, user_id, share_id, last_seq, latitude, longitude, accuracy_m, captured_at, last_received_at)
  VALUES (a, c1, gen_random_uuid(), 1, 14.547, 121.0715, 5, now(), now());
  v_json := pg_temp.q(format('SELECT public.get_booking_location_pins(%L,%L)::text', a, s_w1), w1)::jsonb;
  PERFORM pg_temp.pass(6, 'Worker counterpart is always null', v_json->'counterpart' = 'null'::jsonb, v_json::text);
  PERFORM pg_temp.pass(6, 'Worker still sees own share status', v_json->>'my_share' = 'yours_active', v_json::text);
  PERFORM pg_temp.pass(6, 'no Client coordinate in the Worker response', position('121.0715' in v_json::text) = 0, v_json::text);

  -- 7 the Client still receives the Worker (not the legacy Client row) while one exists
  v_json := pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), c1)::jsonb;
  PERFORM pg_temp.pass(7, 'Client counterpart is the Worker row', v_json->'counterpart'->>'role' = 'worker'
    AND (v_json->'counterpart'->>'longitude')::float8 = 121.0686, v_json::text);
  PERFORM pg_temp.pass(7, 'Client sees its legacy row only as own status', v_json->>'my_share' = 'active_on_other_device', v_json::text);

  -- 8 a Client can still delete its own legacy data (stop-all stays open to both roles)
  r := pg_temp.q(format('SELECT public.stop_all_my_booking_location_shares(%L)::text', a), c1);
  PERFORM pg_temp.pass(8, 'Client stop-all deletes its legacy row', r = '1', r);

  -- 9 when the Worker stops, the Client's map has no Worker pin
  r := pg_temp.q(format('SELECT public.stop_my_booking_location_share(%L,%L)', a, s_w1), w1);
  PERFORM pg_temp.pass(9, 'Worker stop', r = 'stopped', r);
  v_json := pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), c1)::jsonb;
  PERFORM pg_temp.pass(9, 'Client counterpart null after Worker stop', v_json->'counterpart' = 'null'::jsonb, v_json::text);
  PERFORM pg_temp.pass(9, 'no rows remain', NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = a));

  -- 10 unchanged RF-01 boundaries
  r := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', p), w1);
  PERFORM pg_temp.pass(10, 'Worker start on pending booking 42501', r = 'ERR:42501', r);
  r := pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), c2);
  PERFORM pg_temp.pass(10, 'unrelated Client read 42501', r = 'ERR:42501', r);
  PERFORM pg_temp.pass(10, 'anon has no EXECUTE on start/publish/read',
    NOT has_function_privilege('anon', 'public.start_my_booking_location_share(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.publish_my_booking_location(uuid, uuid, integer, double precision, double precision, real, timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_booking_location_pins(uuid, uuid)', 'EXECUTE'));
  PERFORM pg_temp.pass(10, 'authenticated has no direct table access',
    NOT has_table_privilege('authenticated', 'private.booking_location_shares', 'SELECT'));
END;
$$;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM rf04_results;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM rf04_results WHERE NOT ok) THEN
    RAISE EXCEPTION 'RF04 SQL assertions failed';
  END IF;
END $$;

ROLLBACK;
