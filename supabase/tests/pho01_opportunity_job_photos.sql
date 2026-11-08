-- PHO-01 local SQL verification: Workers who match an open Job can see its photos before they
-- accept it (owner, 2026-11-06). Storage metadata and RLS only; disposable fixtures.
BEGIN;

CREATE TEMP TABLE pho01_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON pho01_results TO authenticated, anon;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pho01_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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

-- True when p_uid (or anon, when p_uid is NULL) can read the object's row through Storage RLS.
CREATE OR REPLACE FUNCTION pg_temp.can_select(p_uid uuid, p_name text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_count int := 0;
BEGIN
  IF p_uid IS NULL THEN SET LOCAL ROLE anon;
  ELSE PERFORM pg_temp.jwt(p_uid); SET LOCAL ROLE authenticated;
  END IF;
  SELECT count(*) INTO v_count FROM storage.objects WHERE bucket_id = 'job-photos' AND name = p_name;
  PERFORM pg_temp.clear_jwt();
  RETURN v_count = 1;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RETURN false;
END;
$$;

-- Tries to delete the object as p_uid; returns how many rows were deleted.
CREATE OR REPLACE FUNCTION pg_temp.try_delete(p_uid uuid, p_name text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_count int := 0;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  DELETE FROM storage.objects WHERE bucket_id = 'job-photos' AND name = p_name;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  PERFORM pg_temp.clear_jwt();
  RETURN v_count;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_user(p_id uuid, p_role text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000',p_id,'authenticated','authenticated','pho01-' || right(p_id::text, 2) || '@example.test',
    crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (p_id,'pho01-' || right(p_id::text, 2) || '@example.test','PHO01 ' || p_role,'0919200' || lpad(right(p_id::text, 4), 4, '0'),p_role,'Santa Ana','Pateros',true);
END;
$$;

-- A verified Worker with one skill and the given availability.
CREATE OR REPLACE FUNCTION pg_temp.mk_worker(p_id uuid, p_profile uuid, p_skill uuid, p_availability text DEFAULT 'available')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.mk_user(p_id, 'worker');
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES (p_profile, p_id, 'fixture', 'none', p_availability, true);
  INSERT INTO public.worker_skills(worker_id, skill_id, proficiency_level) VALUES (p_profile, p_skill, 'intermediate');
END;
$$;

-- A Job needing Carpentry.
CREATE OR REPLACE FUNCTION pg_temp.mk_job(p_job uuid, p_client uuid, p_when timestamptz, p_status text DEFAULT 'open')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.job_postings(id,client_id,title,description,address,barangay,city,status,scheduled_at)
  VALUES (p_job,p_client,'PHO01 job','Local test only','Selected pin street','Santa Ana','Pateros',p_status,p_when);
  INSERT INTO public.job_skills(job_id, skill_id) VALUES (p_job, 'ac36af46-4c0c-4c6e-a5a7-4ae375521913');
END;
$$;

DO $$
DECLARE
  carpentry uuid := 'ac36af46-4c0c-4c6e-a5a7-4ae375521913';
  plumbing uuid := 'c7f7a879-6a4c-49fa-b9f0-544a8b60b88e';
  client_one uuid := '9a010101-0000-4000-8000-000000000001';
  client_two uuid := '9a010101-0000-4000-8000-000000000002';
  worker_match uuid := '9a010101-0000-4000-8000-000000000003';
  worker_plumber uuid := '9a010101-0000-4000-8000-000000000004';
  worker_busy uuid := '9a010101-0000-4000-8000-000000000005';
  worker_booked uuid := '9a010101-0000-4000-8000-000000000006';
  j_open uuid := '9a010101-3000-4000-8000-000000000001';
  j_no_time uuid := '9a010101-3000-4000-8000-000000000002';
  j_past uuid := '9a010101-3000-4000-8000-000000000003';
  j_booked uuid := '9a010101-3000-4000-8000-000000000004';
  j_other uuid := '9a010101-3000-4000-8000-000000000005';
  open_1 text;
  open_2 text;
BEGIN
  PERFORM pg_temp.mk_user(client_one, 'client');
  PERFORM pg_temp.mk_user(client_two, 'client');
  PERFORM pg_temp.mk_worker(worker_match, '9a010101-1000-4000-8000-000000000003', carpentry);
  PERFORM pg_temp.mk_worker(worker_plumber, '9a010101-1000-4000-8000-000000000004', plumbing);
  PERFORM pg_temp.mk_worker(worker_busy, '9a010101-1000-4000-8000-000000000005', carpentry, 'busy');
  PERFORM pg_temp.mk_worker(worker_booked, '9a010101-1000-4000-8000-000000000006', carpentry);

  PERFORM pg_temp.mk_job(j_open, client_one, now() + interval '2 days');
  PERFORM pg_temp.mk_job(j_no_time, client_one, NULL);
  PERFORM pg_temp.mk_job(j_past, client_one, now() - interval '5 minutes');
  PERFORM pg_temp.mk_job(j_booked, client_one, now() + interval '3 days', 'matched');
  PERFORM pg_temp.mk_job(j_other, client_two, now() + interval '2 days');
  INSERT INTO public.bookings(job_id, worker_id, client_id, status) VALUES (j_booked, worker_booked, client_one, 'confirmed');

  open_1 := client_one || '/' || j_open || '/1';
  open_2 := client_one || '/' || j_open || '/2';
  PERFORM set_config('storage.allow_delete_query', 'true', true);
  INSERT INTO storage.objects (bucket_id, name) VALUES
    ('job-photos', open_1),
    ('job-photos', open_2),
    ('job-photos', client_one || '/' || j_open || '/extra'),
    ('job-photos', client_one || '/' || j_no_time || '/1'),
    ('job-photos', client_one || '/' || j_past || '/1'),
    ('job-photos', client_one || '/' || j_booked || '/1'),
    ('job-photos', client_one || '/' || j_other || '/1'),
    ('job-photos', client_two || '/' || j_other || '/1');

  -- ---------- A matching Worker sees an open Job's photos ----------
  PERFORM pg_temp.pass(1, 'a matching Worker sees photo 1 of an open Job', pg_temp.can_select(worker_match, open_1));
  PERFORM pg_temp.pass(2, 'and photo 2', pg_temp.can_select(worker_match, open_2));
  PERFORM pg_temp.pass(3, 'and the photo of an open Job with no time set', pg_temp.can_select(worker_match, client_one || '/' || j_no_time || '/1'));
  PERFORM pg_temp.pass(4, 'and the photo of another Client''s open Job they match', pg_temp.can_select(worker_match, client_two || '/' || j_other || '/1'));

  -- ---------- Everyone else stays out ----------
  PERFORM pg_temp.pass(5, 'a Worker without the required skill cannot', NOT pg_temp.can_select(worker_plumber, open_1));
  PERFORM pg_temp.pass(6, 'a Busy Worker cannot', NOT pg_temp.can_select(worker_busy, open_1));
  PERFORM pg_temp.pass(7, 'nobody new sees a Job whose time has passed', NOT pg_temp.can_select(worker_match, client_one || '/' || j_past || '/1'));
  PERFORM pg_temp.pass(8, 'a matching Worker cannot see a Job that is already booked to someone else',
    NOT pg_temp.can_select(worker_match, client_one || '/' || j_booked || '/1'));
  PERFORM pg_temp.pass(9, 'anon cannot', NOT pg_temp.can_select(NULL, open_1));
  PERFORM pg_temp.pass(10, 'a file outside slots 1 to 3 cannot be read', NOT pg_temp.can_select(worker_match, client_one || '/' || j_open || '/extra'));
  PERFORM pg_temp.pass(11, 'a folder that is not the Job''s own Client cannot be read',
    NOT pg_temp.can_select(worker_match, client_one || '/' || j_other || '/1'));

  -- ---------- Existing access is unchanged ----------
  PERFORM pg_temp.pass(12, 'the booked Worker still sees the booked Job''s photo', pg_temp.can_select(worker_booked, client_one || '/' || j_booked || '/1'));
  PERFORM pg_temp.pass(13, 'the owner Client still sees their photos', pg_temp.can_select(client_one, open_1));
  PERFORM pg_temp.pass(14, 'a matching Worker cannot delete a Job photo',
    pg_temp.try_delete(worker_match, open_1) = 0 AND EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'job-photos' AND name = open_1));

  -- ---------- Properties ----------
  PERFORM pg_temp.pass(15, 'the photo check is SECURITY DEFINER with an empty search_path, EXECUTE for authenticated only',
    (SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=""'] AND pg_get_userbyid(p.proowner) = 'postgres'
     FROM pg_proc AS p WHERE p.oid = 'private.can_view_opportunity_job_photo(text)'::regprocedure)
    AND has_function_privilege('authenticated', 'private.can_view_opportunity_job_photo(text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'private.can_view_opportunity_job_photo(text)', 'EXECUTE'));
  PERFORM pg_temp.pass(16, 'the new Storage policy only reads, for authenticated only',
    EXISTS (SELECT 1 FROM pg_policy AS pol JOIN pg_class AS c ON c.oid = pol.polrelid JOIN pg_namespace AS n ON n.oid = c.relnamespace
            WHERE n.nspname = 'storage' AND c.relname = 'objects' AND pol.polname = 'Matched workers can select open job photos'
              AND pol.polcmd = 'r' AND pol.polroles = ARRAY['authenticated'::regrole::oid]));
  PERFORM pg_temp.pass(17, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM pho01_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'PHO-01 failed % assertions', failed; END IF;
  RAISE NOTICE 'PHO-01: % assertions passed', (SELECT count(*) FROM pho01_results);
END;
$$;

ROLLBACK;
