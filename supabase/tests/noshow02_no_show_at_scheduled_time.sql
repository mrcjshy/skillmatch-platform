-- NOSHOW-02 local SQL verification: a Client may report a no-show from the scheduled time. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE noshow02_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON noshow02_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO noshow02_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.jwt(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('role', 'authenticated', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.clear_jwt()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'postgres', true);
  RESET ROLE;
END;
$$;

-- Runs p_sql as p_uid (or as anon) and returns its SQLSTATE.
CREATE OR REPLACE FUNCTION pg_temp.state(p_sql text, p_uid uuid DEFAULT NULL, p_anon boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  IF p_uid IS NOT NULL THEN PERFORM pg_temp.jwt(p_uid);
  ELSIF p_anon THEN PERFORM set_config('role', 'anon', true);
  END IF;
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE; END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_user(p_id uuid, p_role text, p_active boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000',p_id,'authenticated','authenticated','noshow2-' || right(p_id::text, 2) || '@example.test',
          crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (p_id,'noshow2-' || right(p_id::text, 2) || '@example.test','NOSHOW2 ' || p_role,'0919000' || lpad(right(p_id::text, 4), 4, '0'),p_role,'Santa Ana','Pateros',p_active);
END;
$$;

-- A confirmed booking on a matched Job scheduled at p_when.
CREATE OR REPLACE FUNCTION pg_temp.mk_booking(p_booking uuid, p_job uuid, p_client uuid, p_worker uuid, p_when timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.job_postings(id,client_id,title,description,address,barangay,city,status,scheduled_at)
  VALUES (p_job,p_client,'NOSHOW job','Local test only','Selected pin street','Santa Ana','Pateros','matched',p_when);
  INSERT INTO public.bookings(id,job_id,worker_id,client_id,status) VALUES (p_booking,p_job,p_worker,p_client,'confirmed');
END;
$$;

DO $$
DECLARE
  client_one uuid := '0e0b0202-0000-4000-8000-000000000002';
  client_two uuid := '0e0b0202-0000-4000-8000-000000000003';
  worker_one uuid := '0e0b0202-0000-4000-8000-000000000004';
  wp uuid := '0e0b0202-1000-4000-8000-000000000004';
  b_future uuid := '0e0b0202-2000-4000-8000-000000000001';
  b_now uuid := '0e0b0202-2000-4000-8000-000000000002';
  b_half uuid := '0e0b0202-2000-4000-8000-000000000003';
  b_arrived uuid := '0e0b0202-2000-4000-8000-000000000004';
  s text;
  r jsonb;
  def text := pg_get_functiondef('public.report_worker_no_show(uuid)'::regprocedure);
BEGIN
  PERFORM pg_temp.mk_user(client_one, 'client');
  PERFORM pg_temp.mk_user(client_two, 'client');
  PERFORM pg_temp.mk_user(worker_one, 'worker');
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES (wp, worker_one, 'fixture', 'none', 'available', true);

  PERFORM pg_temp.mk_booking(b_future, '0e0b0202-3000-4000-8000-000000000001', client_one, worker_one, now() + interval '10 minutes');
  PERFORM pg_temp.mk_booking(b_now, '0e0b0202-3000-4000-8000-000000000002', client_one, worker_one, now() - interval '1 minute');
  PERFORM pg_temp.mk_booking(b_half, '0e0b0202-3000-4000-8000-000000000003', client_one, worker_one, now() - interval '30 minutes');
  PERFORM pg_temp.mk_booking(b_arrived, '0e0b0202-3000-4000-8000-000000000004', client_one, worker_one, now() - interval '1 minute');
  UPDATE public.bookings SET worker_arrived_at = now() WHERE id = b_arrived;

  -- ---------- When ----------
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_future), client_one);
  PERFORM pg_temp.pass(1, 'before the scheduled time: SM409', s = 'SM409', s);
  PERFORM pg_temp.pass(2, 'and the early booking stays confirmed with no report',
    (SELECT status FROM public.bookings WHERE id = b_future) = 'confirmed'
    AND NOT EXISTS (SELECT 1 FROM public.reports WHERE booking_id = b_future));

  PERFORM pg_temp.jwt(client_one);
  SELECT to_jsonb(x) INTO r FROM public.report_worker_no_show(b_now) AS x;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(3, 'from the scheduled time the Client can close it as no_show',
    r->>'booking_status' = 'no_show' AND r->>'job_status' = 'cancelled' AND r->>'report_id' IS NOT NULL, r::text);
  PERFORM pg_temp.pass(4, 'the filed report no longer mentions 1 hour',
    (SELECT description FROM public.reports WHERE id = (r->>'report_id')::uuid)
      = 'The Worker did not arrive and had not confirmed arrival by the scheduled time.');

  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_half), client_one);
  PERFORM pg_temp.pass(5, '30 minutes after the scheduled time (NOSHOW-01 refused it) now succeeds', s = '00000', s);

  -- ---------- Unchanged rules ----------
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_arrived), client_one);
  PERFORM pg_temp.pass(6, 'the Worker confirmed arrival: still SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_arrived), client_two);
  PERFORM pg_temp.pass(7, 'another Client: still SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_arrived), worker_one);
  PERFORM pg_temp.pass(8, 'the Worker: still 42501', s = '42501', s);
  PERFORM pg_temp.pass(9, 'no strike is given',
    (SELECT coalesce(strike_count, 0) FROM public.worker_profiles WHERE id = wp) = 0);

  -- ---------- Properties ----------
  PERFORM pg_temp.pass(10, 'the time check is the scheduled time, with no 1-hour grace',
    def LIKE '%clock_timestamp() < v_scheduled THEN%' AND def NOT LIKE '%v_scheduled + interval%', def);
  PERFORM pg_temp.pass(11, 'authenticated only, SECURITY DEFINER, empty search_path, owner postgres',
    has_function_privilege('authenticated', 'public.report_worker_no_show(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.report_worker_no_show(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.report_worker_no_show(uuid)', 'EXECUTE')
    AND EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.report_worker_no_show(uuid)'::regprocedure
                AND prosecdef AND proconfig = ARRAY['search_path=""'] AND proowner = 'postgres'::regrole));
  PERFORM pg_temp.pass(12, 'the comment names NOSHOW-02',
    obj_description('public.report_worker_no_show(uuid)'::regprocedure, 'pg_proc') LIKE 'NOSHOW-02:%');
  PERFORM pg_temp.pass(13, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM noshow02_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'NOSHOW-02 failed % assertions', failed; END IF;
  RAISE NOTICE 'NOSHOW-02: % assertions passed', (SELECT count(*) FROM noshow02_results);
END;
$$;

ROLLBACK;
