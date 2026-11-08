-- REG-03 local SQL verification: resume skills without years of experience (owner, 2026-11-06).
-- Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE reg03_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON reg03_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO reg03_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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

-- The Worker's skill rows, read as the test runner.
CREATE OR REPLACE FUNCTION pg_temp.skill_rows(p_worker uuid)
RETURNS TABLE (skill_id text, years integer, level text) LANGUAGE sql AS $$
  SELECT ws.skill_id::text, ws.years_experience::integer, ws.proficiency_level::text
  FROM public.worker_skills AS ws JOIN public.worker_profiles AS wp ON wp.id = ws.worker_id
  WHERE wp.user_id = p_worker;
$$;

-- Fixed fixtures. Skills are two of the catalog rows every replay holds.
DO $$
DECLARE
  u uuid;
BEGIN
  FOREACH u IN ARRAY ARRAY['03030303-0000-4000-8000-000000000001'::uuid, '03030303-0000-4000-8000-000000000002'::uuid] LOOP
    INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    VALUES ('00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated','reg03-'||right(u::text,2)||'@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  END LOOP;
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    ('03030303-0000-4000-8000-000000000001','reg03-01@example.test','REG3 Admin','09300000001','administrator','Santa Ana','Pateros',true),
    ('03030303-0000-4000-8000-000000000002','reg03-02@example.test','Maria Reyes','09300000002','worker','Santa Ana','Pateros',true);
END;
$$;

DO $$
DECLARE
  admin_id uuid := '03030303-0000-4000-8000-000000000001';
  worker uuid := '03030303-0000-4000-8000-000000000002';
  carpentry text := 'ac36af46-4c0c-4c6e-a5a7-4ae375521913';
  plumbing text := 'c7f7a879-6a4c-49fa-b9f0-544a8b60b88e';
  adult date := (now() AT TIME ZONE 'Asia/Manila')::date - interval '30 years';
  save text := 'SELECT public.save_my_worker_resume(%L,%L,NULL,%L,%L)';
  s text;
  r jsonb;
BEGIN
  -- What the app sends now: skill ids only.
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s"},{"skill_id":"%s"}]', carpentry, plumbing)), worker);
  PERFORM pg_temp.pass(1, 'skills without years are accepted', s = '00000', s);
  PERFORM pg_temp.pass(2, 'they are stored with no years and the resume counts as complete',
    (SELECT count(*) FROM pg_temp.skill_rows(worker) WHERE years IS NULL AND skill_id IN (carpentry, plumbing)) = 2
    AND (SELECT resume_completed_at IS NOT NULL FROM public.worker_profiles WHERE user_id = worker));

  -- What installed builds still send: a whole number of years.
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s","years":4}]', carpentry)), worker);
  PERFORM pg_temp.pass(3, 'an older app''s whole-number years are still accepted and stored',
    s = '00000' AND (SELECT years = 4 FROM pg_temp.skill_rows(worker) WHERE skill_id = carpentry), s);

  UPDATE public.worker_skills SET proficiency_level = 'expert'
  WHERE skill_id::text = carpentry AND worker_id = (SELECT id FROM public.worker_profiles WHERE user_id = worker);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s","years":null}]', carpentry)), worker);
  PERFORM pg_temp.pass(4, 'years null is accepted', s = '00000', s);
  PERFORM pg_temp.pass(5, 'resaving a skill without years clears its years, keeps its stored level and the unlisted skill',
    (SELECT years IS NULL AND level = 'expert' FROM pg_temp.skill_rows(worker) WHERE skill_id = carpentry)
    AND (SELECT count(*) FROM pg_temp.skill_rows(worker)) = 2);

  -- Bad entries are still refused.
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s","years":61}]', carpentry)), worker);
  PERFORM pg_temp.pass(6, '61 years: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s","years":-1}]', carpentry)), worker);
  PERFORM pg_temp.pass(7, 'negative years: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s","years":2.5}]', carpentry)), worker);
  PERFORM pg_temp.pass(8, 'fractional years: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s","years":"5"}]', carpentry)), worker);
  PERFORM pg_temp.pass(9, 'years as text: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s","years":true}]', carpentry)), worker);
  PERFORM pg_temp.pass(10, 'years as a boolean: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s","level":"expert"}]', carpentry)), worker);
  PERFORM pg_temp.pass(11, 'an extra key: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', '[{"years":2}]'), worker);
  PERFORM pg_temp.pass(12, 'no skill id: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', '[{}]'), worker);
  PERFORM pg_temp.pass(13, 'an empty entry: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s"},{"skill_id":"%s"}]', carpentry, carpentry)), worker);
  PERFORM pg_temp.pass(14, 'a duplicate skill without years: 22023', s = '22023', s);
  s := pg_temp.state(format(save, adult, 'high_school', '[]', format('[{"skill_id":"%s"}]', gen_random_uuid())), worker);
  PERFORM pg_temp.pass(15, 'a skill outside the catalog without years: 22023', s = '22023', s);
  PERFORM pg_temp.pass(16, 'refused saves changed nothing',
    (SELECT years IS NULL AND level = 'expert' FROM pg_temp.skill_rows(worker) WHERE skill_id = carpentry)
    AND (SELECT count(*) FROM pg_temp.skill_rows(worker)) = 2);

  -- Installed Admin builds parse exact skill keys: name, proficiency, years.
  r := pg_temp.as_json(format('SELECT public.get_admin_account_profile(%L)', worker), admin_id);
  PERFORM pg_temp.pass(17, 'Administrator read keeps the skill keys installed builds parse; no years reads as null',
    jsonb_array_length(r->'skills') = 2
    AND (SELECT bool_and((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(e) AS k) = ARRAY['name', 'proficiency', 'years'])
         FROM jsonb_array_elements(r->'skills') AS e)
    AND (SELECT bool_and(e->'years' = 'null'::jsonb) FROM jsonb_array_elements(r->'skills') AS e), r::text);

  PERFORM pg_temp.pass(18, 'function stays SECURITY DEFINER with an empty search_path, owned by postgres, EXECUTE for authenticated only',
    (SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=""'] AND pg_get_userbyid(p.proowner) = 'postgres'
       AND p.proacl::text = '{postgres=X/postgres,authenticated=X/postgres}'
     FROM pg_proc AS p WHERE p.oid = 'public.save_my_worker_resume(date,text,text,jsonb,jsonb)'::regprocedure)
    AND NOT has_function_privilege('anon', 'public.save_my_worker_resume(date,text,text,jsonb,jsonb)', 'EXECUTE'));
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM reg03_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'REG-03 failed % assertions', failed; END IF;
  RAISE NOTICE 'REG-03: % assertions passed', (SELECT count(*) FROM reg03_results);
END;
$$;

ROLLBACK;
