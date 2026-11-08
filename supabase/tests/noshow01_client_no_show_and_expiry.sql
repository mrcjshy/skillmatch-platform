-- NOSHOW-01 local SQL verification: Client no-show report and past-date opportunities. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE noshow_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON noshow_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO noshow_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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
  VALUES ('00000000-0000-0000-0000-000000000000',p_id,'authenticated','authenticated','noshow-' || right(p_id::text, 2) || '@example.test',
          crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (p_id,'noshow-' || right(p_id::text, 2) || '@example.test','NOSHOW ' || p_role,'0919000' || lpad(right(p_id::text, 4), 4, '0'),p_role,'Santa Ana','Pateros',p_active);
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
  admin_one uuid := '0e0b0101-0000-4000-8000-000000000001';
  client_one uuid := '0e0b0101-0000-4000-8000-000000000002';
  client_two uuid := '0e0b0101-0000-4000-8000-000000000003';
  worker_one uuid := '0e0b0101-0000-4000-8000-000000000004';
  wp uuid := '0e0b0101-1000-4000-8000-000000000004';
  b_ok uuid := '0e0b0101-2000-4000-8000-000000000001';
  b_early uuid := '0e0b0101-2000-4000-8000-000000000002';
  b_arrived uuid := '0e0b0101-2000-4000-8000-000000000003';
  b_paying uuid := '0e0b0101-2000-4000-8000-000000000004';
  b_reported uuid := '0e0b0101-2000-4000-8000-000000000005';
  b_nodate uuid := '0e0b0101-2000-4000-8000-000000000006';
  j uuid;
  s text;
  r jsonb;
BEGIN
  PERFORM pg_temp.mk_user(admin_one, 'administrator');
  PERFORM pg_temp.mk_user(client_one, 'client');
  PERFORM pg_temp.mk_user(client_two, 'client');
  PERFORM pg_temp.mk_user(worker_one, 'worker');
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES (wp, worker_one, 'fixture', 'none', 'available', true);

  PERFORM pg_temp.mk_booking(b_ok, '0e0b0101-3000-4000-8000-000000000001', client_one, worker_one, now() - interval '2 hours');
  PERFORM pg_temp.mk_booking(b_early, '0e0b0101-3000-4000-8000-000000000002', client_one, worker_one, now() + interval '30 minutes');
  PERFORM pg_temp.mk_booking(b_arrived, '0e0b0101-3000-4000-8000-000000000003', client_one, worker_one, now() - interval '2 hours');
  UPDATE public.bookings SET worker_arrived_at = now() - interval '90 minutes' WHERE id = b_arrived;
  PERFORM pg_temp.mk_booking(b_paying, '0e0b0101-3000-4000-8000-000000000004', client_one, worker_one, now() - interval '2 hours');
  UPDATE public.bookings SET payment_method = 'qrph' WHERE id = b_paying;
  PERFORM pg_temp.mk_booking(b_reported, '0e0b0101-3000-4000-8000-000000000005', client_one, worker_one, now() - interval '3 hours');
  PERFORM pg_temp.mk_booking(b_nodate, '0e0b0101-3000-4000-8000-000000000006', client_one, worker_one, NULL);

  -- ---------- Who may report ----------
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_ok), worker_one);
  PERFORM pg_temp.pass(1, 'the Worker cannot report a no-show: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_ok), NULL, true);
  PERFORM pg_temp.pass(2, 'anon cannot report: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_ok), client_two);
  PERFORM pg_temp.pass(3, 'another Client cannot report this booking: SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_ok), admin_one);
  PERFORM pg_temp.pass(4, 'an Administrator cannot report on the Client''s behalf: 42501', s = '42501', s);

  -- ---------- When ----------
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_early), client_one);
  PERFORM pg_temp.pass(5, 'before the scheduled time: SM409 (NOSHOW-02; was 1 hour after)', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_nodate), client_one);
  PERFORM pg_temp.pass(6, 'a Job with no scheduled time: SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_arrived), client_one);
  PERFORM pg_temp.pass(7, 'the Worker confirmed arrival: SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_paying), client_one);
  PERFORM pg_temp.pass(8, 'payment has started: SM403', s = 'SM403', s);
  PERFORM pg_temp.pass(9, 'refused calls changed nothing',
    (SELECT bool_and(status = 'confirmed') FROM public.bookings WHERE id IN (b_ok, b_early, b_arrived, b_paying, b_nodate))
    AND NOT EXISTS (SELECT 1 FROM public.reports WHERE reporter_id = client_one));

  -- ---------- Success ----------
  PERFORM pg_temp.jwt(client_one);
  SELECT to_jsonb(x) INTO r FROM public.report_worker_no_show(b_ok) AS x;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(10, 'returns no_show / cancelled and a report id',
    r->>'booking_status' = 'no_show' AND r->>'job_status' = 'cancelled' AND r->>'report_id' IS NOT NULL, r::text);
  PERFORM pg_temp.pass(11, 'the booking is no_show and the Job is cancelled',
    (SELECT status FROM public.bookings WHERE id = b_ok) = 'no_show'
    AND (SELECT status FROM public.job_postings WHERE id = '0e0b0101-3000-4000-8000-000000000001') = 'cancelled');
  PERFORM pg_temp.pass(12, 'a no-show report against the Worker waits for the Administrator',
    EXISTS (SELECT 1 FROM public.reports WHERE id = (r->>'report_id')::uuid AND reporter_id = client_one
            AND reported_user_id = worker_one AND booking_id = b_ok AND category = 'no-show' AND status = 'submitted'));
  PERFORM pg_temp.pass(13, 'the Administrator is alerted about the new report',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id = admin_one AND type = 'report_submitted'));
  PERFORM pg_temp.pass(14, 'the Worker is told, with the fixed wording',
    (SELECT message FROM public.notifications WHERE user_id = worker_one AND type = 'booking_no_show')
      = 'The Client reported that you did not arrive for "NOSHOW job". An Administrator will review it.');
  PERFORM pg_temp.pass(15, 'no strike is given by the report itself',
    (SELECT coalesce(strike_count, 0) FROM public.worker_profiles WHERE id = wp) = 0);
  s := pg_temp.state(format('SELECT * FROM public.report_worker_no_show(%L)', b_ok), client_one);
  PERFORM pg_temp.pass(16, 'a second report on the same booking: SM409', s = 'SM409', s);

  -- ---------- An earlier report by the same Client is kept ----------
  PERFORM pg_temp.jwt(client_one);
  PERFORM public.submit_my_booking_report(b_reported, 'behavior', 'Earlier report');
  SELECT to_jsonb(x) INTO r FROM public.report_worker_no_show(b_reported) AS x;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(17, 'with an earlier report the booking still closes and no second report is made',
    r->>'booking_status' = 'no_show' AND r->'report_id' = 'null'::jsonb
    AND (SELECT count(*) FROM public.reports WHERE booking_id = b_reported) = 1, r::text);

  -- ---------- Past-date opportunities ----------
  j := '0e0b0101-3000-4000-8000-000000000101';
  INSERT INTO public.job_postings(id,client_id,title,description,address,barangay,city,status,scheduled_at)
  VALUES (j, client_two, 'NOSHOW past open job', 'Local test only', 'Selected pin street', 'Santa Ana', 'Pateros', 'open', now() - interval '5 minutes');
  s := pg_temp.state(format('SELECT * FROM public.accept_job_opportunity(%L)', j), worker_one);
  PERFORM pg_temp.pass(18, 'a Job whose time has passed cannot be accepted: SM409', s = 'SM409', s);
  PERFORM pg_temp.pass(19, 'and it stays open with no booking',
    (SELECT status FROM public.job_postings WHERE id = j) = 'open' AND NOT EXISTS (SELECT 1 FROM public.bookings WHERE job_id = j));

  -- ---------- Properties ----------
  PERFORM pg_temp.pass(20, 'report_worker_no_show: authenticated only, SECURITY DEFINER, empty search_path',
    has_function_privilege('authenticated', 'public.report_worker_no_show(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.report_worker_no_show(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.report_worker_no_show(uuid)', 'EXECUTE')
    AND EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.report_worker_no_show(uuid)'::regprocedure
                AND prosecdef AND proconfig = ARRAY['search_path=""']));
  PERFORM pg_temp.pass(21, 'list_my_job_opportunities leaves out Jobs whose time has passed',
    pg_get_functiondef('public.list_my_job_opportunities()'::regprocedure) LIKE '%jp.scheduled_at > now()%');
  PERFORM pg_temp.pass(22, 'booking_no_show is an allowed notification type',
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'notifications_type_check')) LIKE '%booking_no_show%');
  PERFORM pg_temp.pass(23, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM noshow_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'NOSHOW-01 failed % assertions', failed; END IF;
  RAISE NOTICE 'NOSHOW-01: % assertions passed', (SELECT count(*) FROM noshow_results);
END;
$$;

ROLLBACK;
