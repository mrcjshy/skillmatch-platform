-- SCH-01 local SQL verification: a Worker cannot accept a Job scheduled within 3 hours of one of
-- their confirmed bookings (owner, 2026-11-06). Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE sch01_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON sch01_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO sch01_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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

-- Runs p_sql as p_uid and returns its SQLSTATE.
CREATE OR REPLACE FUNCTION pg_temp.state(p_sql text, p_uid uuid)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE; END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.accept(p_job uuid, p_worker uuid)
RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.state(format('SELECT * FROM public.accept_job_opportunity(%L)', p_job), p_worker);
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_user(p_id uuid, p_role text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000',p_id,'authenticated','authenticated','sch01-' || right(p_id::text, 2) || '@example.test',
    crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (p_id,'sch01-' || right(p_id::text, 2) || '@example.test','SCH01 ' || p_role,'0919100' || lpad(right(p_id::text, 4), 4, '0'),p_role,'Santa Ana','Pateros',true);
END;
$$;

-- An available, verified Worker who has Carpentry.
CREATE OR REPLACE FUNCTION pg_temp.mk_worker(p_id uuid, p_profile uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.mk_user(p_id, 'worker');
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES (p_profile, p_id, 'fixture', 'none', 'available', true);
  INSERT INTO public.worker_skills(worker_id, skill_id, proficiency_level)
  VALUES (p_profile, 'ac36af46-4c0c-4c6e-a5a7-4ae375521913', 'intermediate');
END;
$$;

-- A Job needing Carpentry at p_when (NULL means no time set).
CREATE OR REPLACE FUNCTION pg_temp.mk_job(p_job uuid, p_client uuid, p_when timestamptz, p_status text DEFAULT 'open')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.job_postings(id,client_id,title,description,address,barangay,city,status,scheduled_at)
  VALUES (p_job,p_client,'SCH01 job ' || right(p_job::text, 2),'Local test only','Selected pin street','Santa Ana','Pateros',p_status,p_when);
  INSERT INTO public.job_skills(job_id, skill_id) VALUES (p_job, 'ac36af46-4c0c-4c6e-a5a7-4ae375521913');
END;
$$;

DO $$
DECLARE
  client_one uuid := '5c400101-0000-4000-8000-000000000001';
  worker_one uuid := '5c400101-0000-4000-8000-000000000002';
  worker_two uuid := '5c400101-0000-4000-8000-000000000003';
  base timestamptz := date_trunc('hour', now()) + interval '2 days';
  day_two timestamptz := date_trunc('hour', now()) + interval '3 days';
  j_first uuid := '5c400101-3000-4000-8000-000000000001';
  j_same_time uuid := '5c400101-3000-4000-8000-000000000002';
  j_after uuid := '5c400101-3000-4000-8000-000000000003';
  j_before uuid := '5c400101-3000-4000-8000-000000000004';
  j_edge_after uuid := '5c400101-3000-4000-8000-000000000005';
  j_edge_before uuid := '5c400101-3000-4000-8000-000000000006';
  j_no_time uuid := '5c400101-3000-4000-8000-000000000007';
  j_other_worker uuid := '5c400101-3000-4000-8000-000000000008';
  j_done uuid := '5c400101-3000-4000-8000-000000000009';
  j_cancelled uuid := '5c400101-3000-4000-8000-000000000010';
  j_no_show uuid := '5c400101-3000-4000-8000-000000000011';
  j_day_two uuid := '5c400101-3000-4000-8000-000000000012';
  s text;
BEGIN
  PERFORM pg_temp.mk_user(client_one, 'client');
  PERFORM pg_temp.mk_worker(worker_one, '5c400101-1000-4000-8000-000000000002');
  PERFORM pg_temp.mk_worker(worker_two, '5c400101-1000-4000-8000-000000000003');

  PERFORM pg_temp.mk_job(j_first, client_one, base);
  PERFORM pg_temp.mk_job(j_same_time, client_one, base);
  PERFORM pg_temp.mk_job(j_after, client_one, base + interval '2 hours 59 minutes');
  PERFORM pg_temp.mk_job(j_before, client_one, base - interval '1 hour');
  PERFORM pg_temp.mk_job(j_edge_after, client_one, base + interval '3 hours');
  PERFORM pg_temp.mk_job(j_edge_before, client_one, base - interval '3 hours');
  PERFORM pg_temp.mk_job(j_no_time, client_one, NULL);
  PERFORM pg_temp.mk_job(j_other_worker, client_one, base + interval '1 hour');

  s := pg_temp.accept(j_first, worker_one);
  PERFORM pg_temp.pass(1, 'the first booking is accepted', s = '00000', s);

  -- ---------- Within 3 hours of the confirmed booking ----------
  s := pg_temp.accept(j_same_time, worker_one);
  PERFORM pg_temp.pass(2, 'a Job at the same time: SM422', s = 'SM422', s);
  s := pg_temp.accept(j_after, worker_one);
  PERFORM pg_temp.pass(3, 'a Job 2 h 59 min after the booking: SM422', s = 'SM422', s);
  s := pg_temp.accept(j_before, worker_one);
  PERFORM pg_temp.pass(4, 'a Job 1 hour before the booking: SM422', s = 'SM422', s);
  PERFORM pg_temp.pass(5, 'refused Jobs stay open, with no booking',
    (SELECT bool_and(status = 'open') FROM public.job_postings WHERE id IN (j_same_time, j_after, j_before))
    AND NOT EXISTS (SELECT 1 FROM public.bookings WHERE job_id IN (j_same_time, j_after, j_before)));

  -- ---------- Exactly 3 hours apart, no time, another Worker ----------
  s := pg_temp.accept(j_edge_after, worker_one);
  PERFORM pg_temp.pass(6, 'a Job exactly 3 hours after the booking is accepted', s = '00000', s);
  s := pg_temp.accept(j_edge_before, worker_one);
  PERFORM pg_temp.pass(7, 'a Job exactly 3 hours before the booking is accepted', s = '00000', s);
  s := pg_temp.accept(j_no_time, worker_one);
  PERFORM pg_temp.pass(8, 'a Job with no scheduled time is never a conflict', s = '00000', s);
  s := pg_temp.accept(j_other_worker, worker_two);
  PERFORM pg_temp.pass(9, 'another Worker is not blocked by worker one''s bookings', s = '00000', s);

  -- ---------- Only confirmed bookings occupy time ----------
  PERFORM pg_temp.mk_job(j_done, client_one, day_two, 'completed');
  PERFORM pg_temp.mk_job(j_cancelled, client_one, day_two + interval '30 minutes', 'cancelled');
  PERFORM pg_temp.mk_job(j_no_show, client_one, day_two - interval '30 minutes', 'cancelled');
  INSERT INTO public.bookings(job_id, worker_id, client_id, status) VALUES (j_done, worker_one, client_one, 'completed');
  INSERT INTO public.bookings(job_id, worker_id, client_id, status, cancellation_reason_code, cancelled_by, cancelled_at)
  VALUES (j_cancelled, worker_one, client_one, 'cancelled', 'schedule_conflict', worker_one, now());
  INSERT INTO public.bookings(job_id, worker_id, client_id, status) VALUES (j_no_show, worker_one, client_one, 'no_show');
  PERFORM pg_temp.mk_job(j_day_two, client_one, day_two + interval '1 hour');
  s := pg_temp.accept(j_day_two, worker_one);
  PERFORM pg_temp.pass(10, 'completed, cancelled and no-show bookings do not block', s = '00000', s);

  -- ---------- Properties ----------
  PERFORM pg_temp.pass(11, 'accept_job_opportunity stays SECURITY DEFINER with an empty search_path, owned by postgres, EXECUTE for authenticated only',
    (SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=""'] AND pg_get_userbyid(p.proowner) = 'postgres'
       AND p.proacl::text = '{postgres=X/postgres,authenticated=X/postgres}'
     FROM pg_proc AS p WHERE p.oid = 'public.accept_job_opportunity(uuid)'::regprocedure));
  PERFORM pg_temp.pass(12, 'one Worker''s acceptances are serialized (transaction advisory lock)',
    (SELECT p.prosrc LIKE '%pg_advisory_xact_lock%' FROM pg_proc AS p WHERE p.oid = 'public.accept_job_opportunity(uuid)'::regprocedure));
  PERFORM pg_temp.pass(13, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM sch01_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'SCH-01 failed % assertions', failed; END IF;
  RAISE NOTICE 'SCH-01: % assertions passed', (SELECT count(*) FROM sch01_results);
END;
$$;

ROLLBACK;
