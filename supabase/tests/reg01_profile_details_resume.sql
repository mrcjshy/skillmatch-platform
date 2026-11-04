-- REG-01 local SQL verification: profile details, Worker resume, Administrator profile read.
-- Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE reg01_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON reg01_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO reg01_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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

CREATE OR REPLACE FUNCTION pg_temp.state(p_sql text, p_uid uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  IF p_uid IS NOT NULL THEN PERFORM pg_temp.jwt(p_uid); END IF;
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE; END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.as_json(p_sql text, p_uid uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  EXECUTE p_sql INTO v;
  PERFORM pg_temp.clear_jwt();
  RETURN v;
END;
$$;

-- Fixed fixtures. Skills are two of the catalog rows every replay holds.
DO $$
DECLARE
  u uuid;
BEGIN
  FOREACH u IN ARRAY ARRAY[
    '02020202-0000-4000-8000-000000000001'::uuid, '02020202-0000-4000-8000-000000000002'::uuid,
    '02020202-0000-4000-8000-000000000003'::uuid, '02020202-0000-4000-8000-000000000004'::uuid,
    '02020202-0000-4000-8000-000000000005'::uuid] LOOP
    INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    VALUES ('00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated','reg01-'||right(u::text,2)||'@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  END LOOP;
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    ('02020202-0000-4000-8000-000000000001','reg01-01@example.test','REG Admin','09200000001','administrator','Santa Ana','Pateros',true),
    ('02020202-0000-4000-8000-000000000002','reg01-02@example.test','Juan Cruz','09200000002','worker','Santa Ana','Pateros',true),
    ('02020202-0000-4000-8000-000000000003','reg01-03@example.test','Ana Santos','09200000003','client','Santa Ana','Pateros',true),
    ('02020202-0000-4000-8000-000000000004','reg01-04@example.test','Inactive Worker','09200000004','worker','Santa Ana','Pateros',false),
    ('02020202-0000-4000-8000-000000000005','reg01-05@example.test','Other Worker','09200000005','worker','Santa Ana','Pateros',true);
END;
$$;

-- ---------- Profile details ----------
DO $$
DECLARE
  admin_id uuid := '02020202-0000-4000-8000-000000000001';
  worker uuid := '02020202-0000-4000-8000-000000000002';
  client uuid := '02020202-0000-4000-8000-000000000003';
  inactive uuid := '02020202-0000-4000-8000-000000000004';
  s text;
  r jsonb;
  ok_call text := $q$SELECT to_jsonb(r) FROM public.save_my_profile_details('  Juan ', 'Dela', 'Cruz', 'Jr.', '12 M. Almeda St.', 'San Roque', 'Pateros', 'Metro Manila', NULL, NULL) AS r$q$;
BEGIN
  s := pg_temp.state($q$SELECT public.save_my_profile_details('A','B','C',NULL,'x','y','z','w',NULL,NULL)$q$, NULL);
  PERFORM pg_temp.pass(1, 'anonymous caller: 42501', s = '42501', s);
  s := pg_temp.state($q$SELECT public.save_my_profile_details('A',NULL,'C',NULL,'x','y','z','w',NULL,NULL)$q$, inactive);
  PERFORM pg_temp.pass(2, 'inactive Worker: 42501', s = '42501', s);
  s := pg_temp.state($q$SELECT public.save_my_profile_details('A',NULL,'C',NULL,'x','y','z','w',NULL,NULL)$q$, admin_id);
  PERFORM pg_temp.pass(3, 'Administrator caller: 42501', s = '42501', s);
  s := pg_temp.state($q$SELECT public.save_my_profile_details('  ',NULL,'Cruz',NULL,'x','y','z','w',NULL,NULL)$q$, worker);
  PERFORM pg_temp.pass(4, 'blank first name: 22023', s = '22023', s);
  s := pg_temp.state($q$SELECT public.save_my_profile_details('Juan',NULL,'Cruz',NULL,NULL,'y','z','w',NULL,NULL)$q$, worker);
  PERFORM pg_temp.pass(5, 'missing street: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_profile_details(%L,NULL,%L,NULL,%L,%L,%L,%L,NULL,NULL)', repeat('a', 61), 'Cruz', 'x', 'y', 'z', 'w'), worker);
  PERFORM pg_temp.pass(6, '61-character first name: 22023', s = '22023', s);
  s := pg_temp.state($q$SELECT public.save_my_profile_details('Juan',NULL,'Cruz',NULL,'x','y','z','w','business','Shop')$q$, worker);
  PERFORM pg_temp.pass(7, 'Worker cannot send a Client account type: 22023', s = '22023', s);
  PERFORM pg_temp.pass(8, 'denials changed nothing',
    (SELECT first_name IS NULL AND profile_completed_at IS NULL AND full_name = 'Juan Cruz' FROM public.users WHERE id = worker));

  r := pg_temp.as_json(ok_call, worker);
  PERFORM pg_temp.pass(9, 'Worker saves details; full_name recomposed from trimmed parts',
    r->>'full_name' = 'Juan Dela Cruz Jr.' AND r->>'profile_completed_at' IS NOT NULL, r::text);
  PERFORM pg_temp.pass(10, 'home address stored apart from the deployment scope',
    (SELECT address_barangay = 'San Roque' AND barangay = 'Santa Ana' AND city = 'Pateros' AND address_province = 'Metro Manila'
       AND role = 'worker' AND is_active FROM public.users WHERE id = worker));

  s := pg_temp.state($q$SELECT public.save_my_profile_details('Ana',NULL,'Santos',NULL,'x','y','z','w',NULL,NULL)$q$, client);
  -- REG-02 (2026-11-04) made the Client account type optional.
  PERFORM pg_temp.pass(11, 'Client without account type saves (optional since REG-02)', s = '00000', s);
  s := pg_temp.state($q$SELECT public.save_my_profile_details('Ana',NULL,'Santos',NULL,'x','y','z','w','business',NULL)$q$, client);
  PERFORM pg_temp.pass(12, 'business Client without business name: 22023', s = '22023', s);
  r := pg_temp.as_json($q$SELECT to_jsonb(r) FROM public.save_my_profile_details('Ana',NULL,'Santos',NULL,'5 B. Morcilla','Poblacion','Pateros','Metro Manila','business','Santos Bakery') AS r$q$, client);
  PERFORM pg_temp.pass(13, 'business Client saves name, address and business',
    r->>'full_name' = 'Ana Santos' AND (SELECT client_account_type = 'business' AND business_name = 'Santos Bakery' FROM public.users WHERE id = client), r::text);
  r := pg_temp.as_json($q$SELECT to_jsonb(r) FROM public.save_my_profile_details('Ana',NULL,'Santos',NULL,'5 B. Morcilla','Poblacion','Pateros','Metro Manila','individual','Ignored') AS r$q$, client);
  PERFORM pg_temp.pass(14, 'switching to individual clears the business name',
    (SELECT client_account_type = 'individual' AND business_name IS NULL FROM public.users WHERE id = client));

  s := pg_temp.state(format('UPDATE public.users SET profile_completed_at = now(), first_name = NULL WHERE id = %L', client), client);
  PERFORM pg_temp.pass(15, 'a direct self-update cannot keep completion without the details: 23514', s = '23514', s);
END;
$$;

-- ---------- Worker resume ----------
DO $$
DECLARE
  worker uuid := '02020202-0000-4000-8000-000000000002';
  client uuid := '02020202-0000-4000-8000-000000000003';
  carpentry text := 'ac36af46-4c0c-4c6e-a5a7-4ae375521913';
  plumbing text := 'c7f7a879-6a4c-49fa-b9f0-544a8b60b88e';
  jobs text := '[{"employer":"  ABC Builders ","role":"Carpenter","start_year":2018,"end_year":2021},{"employer":"Self-employed","role":"Plumber","start_year":2021,"end_year":null}]';
  skills text;
  s text;
  r jsonb;
  adult date := (now() AT TIME ZONE 'Asia/Manila')::date - interval '30 years';
BEGIN
  skills := format('[{"skill_id":"%s","years":6},{"skill_id":"%s","years":3}]', carpentry, plumbing);

  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school', '[]', skills), client);
  PERFORM pg_temp.pass(16, 'Client cannot save a Worker resume: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', (now() AT TIME ZONE 'Asia/Manila')::date - interval '17 years', 'high_school', '[]', skills), worker);
  PERFORM pg_temp.pass(17, 'under 18: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'phd', '[]', skills), worker);
  PERFORM pg_temp.pass(18, 'unknown education level: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school',
    '[{"employer":"a","role":"b","start_year":2020},{"employer":"a","role":"b","start_year":2020},{"employer":"a","role":"b","start_year":2020},{"employer":"a","role":"b","start_year":2020}]', skills), worker);
  PERFORM pg_temp.pass(19, 'four jobs: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school', '[{"employer":"a","role":"b"}]', skills), worker);
  PERFORM pg_temp.pass(20, 'job without a start year: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school', '[{"employer":"a","role":"b","start_year":2020,"end_year":2019}]', skills), worker);
  PERFORM pg_temp.pass(21, 'job ending before it starts: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school', '[{"employer":"a","role":"b","start_year":2020,"salary":1}]', skills), worker);
  PERFORM pg_temp.pass(22, 'job with an extra key: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school', '[]', '[]'), worker);
  PERFORM pg_temp.pass(23, 'no skills: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school', '[]', format('[{"skill_id":"%s","years":61}]', carpentry)), worker);
  PERFORM pg_temp.pass(24, '61 years of experience: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school', '[]', format('[{"skill_id":"%s","years":2}]', gen_random_uuid())), worker);
  PERFORM pg_temp.pass(25, 'skill not in the catalog: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)', adult, 'high_school', '[]', format('[{"skill_id":"%s","years":2},{"skill_id":"%s","years":3}]', carpentry, carpentry)), worker);
  PERFORM pg_temp.pass(26, 'duplicate skill: 22023', s = '22023', s);
  PERFORM pg_temp.pass(27, 'denials created no profile', NOT EXISTS (SELECT 1 FROM public.worker_profiles WHERE user_id = worker));

  r := pg_temp.as_json(format('SELECT to_jsonb(r) FROM public.save_my_worker_resume(%L,%L,%L,%L,%L) AS r', adult, 'vocational', 'TESDA Pateros', jobs, skills), worker);
  PERFORM pg_temp.pass(28, 'Worker saves the resume and gets a new profile row', r->>'resume_completed_at' IS NOT NULL, r::text);
  PERFORM pg_temp.pass(29, 'new profile keeps guarded defaults',
    (SELECT is_verified = false AND verified_by IS NULL AND rating_avg = 0 AND strike_count = 0 AND badge_level = 'none'
       FROM public.worker_profiles WHERE user_id = worker));
  PERFORM pg_temp.pass(30, 'work history stored trimmed with present job end_year null',
    (SELECT work_history = '[{"employer":"ABC Builders","role":"Carpenter","start_year":2018,"end_year":2021},{"employer":"Self-employed","role":"Plumber","start_year":2021,"end_year":null}]'::jsonb
       FROM public.worker_profiles WHERE user_id = worker));
  PERFORM pg_temp.pass(31, 'skills stored with years of experience',
    (SELECT count(*) FROM public.worker_skills ws JOIN public.worker_profiles wp ON wp.id = ws.worker_id
       WHERE wp.user_id = worker AND ((ws.skill_id::text = carpentry AND ws.years_experience = 6) OR (ws.skill_id::text = plumbing AND ws.years_experience = 3))) = 2);

  UPDATE public.worker_skills SET proficiency_level = 'expert' WHERE skill_id::text = carpentry;
  r := pg_temp.as_json(format('SELECT to_jsonb(r) FROM public.save_my_worker_resume(%L,%L,NULL,%L,%L) AS r', adult, 'vocational', '[]', format('[{"skill_id":"%s","years":7}]', carpentry)), worker);
  PERFORM pg_temp.pass(32, 'resaving updates years, keeps proficiency and unlisted skills',
    (SELECT count(*) FROM public.worker_skills ws JOIN public.worker_profiles wp ON wp.id = ws.worker_id WHERE wp.user_id = worker) = 2
    AND (SELECT years_experience = 7 AND proficiency_level = 'expert' FROM public.worker_skills WHERE skill_id::text = carpentry));

  s := pg_temp.state(format('UPDATE public.worker_profiles SET education_level = NULL WHERE user_id = %L', worker), worker);
  PERFORM pg_temp.pass(33, 'a direct self-update cannot keep resume completion without education: 23514', s = '23514', s);
  PERFORM pg_temp.pass(42, 'birth date is stored on the own-row-only users table, not on worker_profiles',
    (SELECT birth_date = adult::date FROM public.users WHERE id = worker)
    AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'worker_profiles' AND column_name = 'birth_date'));
END;
$$;

-- ---------- Administrator profile read ----------
DO $$
DECLARE
  admin_id uuid := '02020202-0000-4000-8000-000000000001';
  worker uuid := '02020202-0000-4000-8000-000000000002';
  client uuid := '02020202-0000-4000-8000-000000000003';
  other uuid := '02020202-0000-4000-8000-000000000005';
  r jsonb;
  s text;
BEGIN
  s := pg_temp.state(format('SELECT public.get_admin_account_profile(%L)', worker), other);
  PERFORM pg_temp.pass(34, 'Worker cannot read another profile: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT public.get_admin_account_profile(%L)', admin_id), admin_id);
  PERFORM pg_temp.pass(35, 'Administrator target: SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT public.get_admin_account_profile(%L)', gen_random_uuid()), admin_id);
  PERFORM pg_temp.pass(36, 'missing target: SM409', s = 'SM409', s);

  r := pg_temp.as_json(format('SELECT public.get_admin_account_profile(%L)', worker), admin_id);
  PERFORM pg_temp.pass(37, 'Administrator reads the full Worker resume with contact details',
    r->>'full_name' = 'Juan Dela Cruz Jr.' AND r->>'email' = 'reg01-02@example.test' AND r->>'phone' = '09200000002'
    AND r->>'address_street' = '12 M. Almeda St.' AND r->>'education_level' = 'vocational' AND r->>'school_name' IS NULL
    AND jsonb_array_length(r->'work_history') = 0 AND jsonb_array_length(r->'skills') = 2
    AND r->'skills'->0->>'name' = 'Carpentry' AND (r->'skills'->0->>'years')::int = 7, r::text);
  r := pg_temp.as_json(format('SELECT public.get_admin_account_profile(%L)', client), admin_id);
  PERFORM pg_temp.pass(38, 'Client profile has account type and no resume keys',
    r->>'client_account_type' = 'individual' AND NOT r ? 'birth_date' AND NOT r ? 'skills', r::text);
  r := pg_temp.as_json(format('SELECT public.get_admin_account_profile(%L)', other), admin_id);
  PERFORM pg_temp.pass(39, 'Worker without a profile reads as an empty resume',
    r->'birth_date' = 'null'::jsonb AND r->'skills' = '[]'::jsonb AND r->'resume_completed_at' = 'null'::jsonb, r::text);

  PERFORM pg_temp.pass(40, 'EXECUTE granted to authenticated only',
    has_function_privilege('authenticated', 'public.get_admin_account_profile(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_admin_account_profile(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.save_my_worker_resume(date,text,text,jsonb,jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.save_my_profile_details(text,text,text,text,text,text,text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.reg01_text(text,integer,boolean,text)', 'EXECUTE'));
  -- REG-02: a Client is complete only with a home pin; this fixture Client has none.
  PERFORM pg_temp.pass(43, 'own completion: Worker complete, Client without home pin incomplete, unsaved Worker incomplete, Administrator no row',
    pg_temp.as_json('SELECT to_jsonb(r) FROM public.get_my_profile_completion() AS r', worker) = '{"profile_complete":true,"resume_complete":true}'::jsonb
    AND pg_temp.as_json('SELECT to_jsonb(r) FROM public.get_my_profile_completion() AS r', client) = '{"profile_complete":false,"resume_complete":true}'::jsonb
    AND pg_temp.as_json('SELECT to_jsonb(r) FROM public.get_my_profile_completion() AS r', other) = '{"profile_complete":false,"resume_complete":false}'::jsonb
    AND pg_temp.as_json('SELECT to_jsonb(r) FROM public.get_my_profile_completion() AS r', admin_id) IS NULL);
  PERFORM pg_temp.pass(41, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM reg01_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'REG-01 failed % assertions', failed; END IF;
  RAISE NOTICE 'REG-01: % assertions passed', (SELECT count(*) FROM reg01_results);
END;
$$;

ROLLBACK;
