-- V4-LOC-01 local-only, synthetic fixtures, always ROLLBACK. Run with ON_ERROR_STOP.
-- Load the candidate inside this transaction; it must not remain installed.
BEGIN;
CREATE TEMP TABLE loc_baseline AS
SELECT p.oid, md5(pg_get_functiondef(p.oid)) AS hash
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN ('public','private') AND p.prokind='f';
CREATE TEMP TABLE loc_table_baseline AS
SELECT count(*) AS n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname IN ('public','private') AND c.relkind IN ('r','p');
\ir ../migrations/20260924090000_v4_loc_01_worker_opportunity_location.sql
CREATE FUNCTION pg_temp.assert_ok(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', label; END IF;
  RAISE NOTICE 'PASS: %', label;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.jwt(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
    true
  );
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('role', 'authenticated', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.clear_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'postgres', true);
  RESET ROLE;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_user(
  p_user_id uuid,
  p_email text,
  p_role text,
  p_active boolean,
  p_barangay text DEFAULT 'Santa Ana',
  p_city text DEFAULT 'Pateros'
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    p_user_id, 'authenticated', 'authenticated', p_email,
    crypt('r5e-db1-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );
  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'R5E DB1 Fixture', '09000000000', p_role,
    p_barangay, p_city, p_active
  );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_worker(
  p_user_id uuid,
  p_profile_id uuid,
  p_email text,
  p_verified boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_temp.mk_user(p_user_id, p_email, 'worker', true);
  INSERT INTO public.worker_profiles (
    id, user_id, bio, badge_level, availability_status, is_verified
  ) VALUES (
    p_profile_id, p_user_id, 'local fixture', 'none', 'available', p_verified
  );
END;
$$;


CREATE FUNCTION pg_temp.expect_error(uid uuid, arg text, expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual text;
BEGIN
  PERFORM pg_temp.jwt(uid);
  BEGIN
    PERFORM public.get_my_opportunity_location(arg);
    actual := 'no error';
  EXCEPTION WHEN OTHERS THEN actual := SQLSTATE;
  END;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(actual = expected, 'authorization/argument error ' || expected);
END $$;
DO $$
DECLARE
  c uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  w uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  other_w uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
  unverified uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb03';
  inactive uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb04';
  admin_id uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  wp uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc01';
  skill uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddd01';
  j uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';
  missing uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee99';
  result jsonb;
  err text;
BEGIN
  PERFORM pg_temp.mk_user(c,'v4loc-client@example.test','client',true);
  PERFORM pg_temp.mk_user(admin_id,'v4loc-admin@example.test','administrator',true);
  PERFORM pg_temp.mk_worker(w,wp,'v4loc-worker@example.test');
  PERFORM pg_temp.mk_worker(other_w,'cccccccc-cccc-4ccc-8ccc-cccccccccc02','v4loc-other@example.test');
  PERFORM pg_temp.mk_worker(unverified,'cccccccc-cccc-4ccc-8ccc-cccccccccc03','v4loc-unverified@example.test',false);
  PERFORM pg_temp.mk_worker(inactive,'cccccccc-cccc-4ccc-8ccc-cccccccccc04','v4loc-inactive@example.test');
  UPDATE public.users SET is_active=false WHERE id=inactive;
  INSERT INTO public.skills(id,skill_name,category) VALUES(skill,'V4 LOC fixture','trade');
  INSERT INTO public.worker_skills(worker_id,skill_id,proficiency_level) VALUES(wp,skill,'intermediate');
  INSERT INTO public.job_postings(id,client_id,title,description,address,barangay,city,status,scheduled_at)
    VALUES(j,c,'Local fixture','Local test only','Selected pin street','Santa Ana','Pateros','open',now()+interval '1 day');
  INSERT INTO public.job_skills(job_id,skill_id) VALUES(j,skill);
  INSERT INTO private.job_locations(job_id,latitude,longitude) VALUES(j,14.5444514,121.07205067);

  PERFORM pg_temp.jwt(w);
  result := public.get_my_opportunity_location(j::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result = jsonb_build_object('latitude',14.5444514,'longitude',121.07205067,
    'address','Selected pin street','barangay','Santa Ana','city','Pateros'), 'eligible exact projection; five fields only');
  PERFORM pg_temp.jwt(other_w);
  result := public.get_my_opportunity_location(j::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result IS NULL,'unrelated verified Worker NULL');
  PERFORM pg_temp.jwt(w);
  result := public.get_my_opportunity_location(missing::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result IS NULL,'nonexistent Job NULL');

  DELETE FROM private.job_locations WHERE job_id=j;
  PERFORM pg_temp.jwt(w);
  result := public.get_my_opportunity_location(j::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result IS NULL,'absent location row NULL');
  INSERT INTO private.job_locations(job_id,latitude,longitude) VALUES(j,14.5444514,121.07205067);
  UPDATE public.job_postings SET status='matched' WHERE id=j;
  PERFORM pg_temp.jwt(w);
  result := public.get_my_opportunity_location(j::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result IS NULL,'unavailable Job NULL');

  UPDATE public.job_postings SET status='open', address=NULL WHERE id=j;
  PERFORM pg_temp.jwt(w);
  result := public.get_my_opportunity_location(j::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result->'address'='null'::jsonb AND result->>'latitude'='14.5444514', 'nullable legacy address explicit, pin retained');
  UPDATE public.job_postings SET address='Selected pin street' WHERE id=j;
  UPDATE public.worker_profiles SET availability_status='busy' WHERE user_id=w;
  PERFORM pg_temp.jwt(w);
  result := public.get_my_opportunity_location(j::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result IS NULL,'current opportunity authority revokes busy Worker');
  UPDATE public.worker_profiles SET availability_status='available' WHERE user_id=w;
  DELETE FROM public.worker_skills WHERE worker_id=wp AND skill_id=skill;
  PERFORM pg_temp.jwt(w);
  result := public.get_my_opportunity_location(j::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result IS NULL,'removed skill revokes exact opportunity access');
  INSERT INTO public.worker_skills(worker_id,skill_id,proficiency_level) VALUES(wp,skill,'intermediate');
  INSERT INTO public.worker_skills(worker_id,skill_id,proficiency_level)
    VALUES('cccccccc-cccc-4ccc-8ccc-cccccccccc02',skill,'beginner');
  PERFORM pg_temp.jwt(other_w);
  PERFORM public.accept_job_opportunity(j);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.jwt(w);
  result := public.get_my_opportunity_location(j::text);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result IS NULL,'losing Worker location revoked after actual acceptance');
  PERFORM pg_temp.jwt(other_w);
  SELECT to_jsonb(loc) INTO result FROM public.get_authorized_job_location(j) loc;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.assert_ok(result->>'address'='Selected pin street','winning Worker retains separate confirmed-Booking location');

  PERFORM pg_temp.expect_error(unverified,j::text,'42501');
  PERFORM pg_temp.expect_error(inactive,j::text,'42501');
  PERFORM pg_temp.expect_error(c,j::text,'42501');
  PERFORM pg_temp.expect_error(admin_id,j::text,'42501');
  PERFORM pg_temp.expect_error(NULL,j::text,'42501');
  PERFORM pg_temp.expect_error(c,'malformed','42501');
  PERFORM pg_temp.expect_error(admin_id,'malformed','42501');
  PERFORM pg_temp.expect_error(unverified,'malformed','42501');
  PERFORM pg_temp.expect_error(inactive,'malformed','42501');
  PERFORM pg_temp.expect_error(NULL,'malformed','42501');
  PERFORM pg_temp.expect_error(w,'malformed','22023');
  PERFORM pg_temp.expect_error(w,NULL,'22023');
  PERFORM pg_temp.expect_error(w,' '||j::text,'22023');

  SET LOCAL ROLE anon;
  BEGIN
    PERFORM public.get_my_opportunity_location('malformed');
    err := 'no error';
  EXCEPTION WHEN OTHERS THEN err:=SQLSTATE;
  END;
  RESET ROLE;
  PERFORM pg_temp.assert_ok(err='42501','anon ACL denial');
  PERFORM pg_temp.assert_ok(NOT has_table_privilege('authenticated','private.job_locations','SELECT'), 'no direct Worker SELECT');
  PERFORM pg_temp.assert_ok(NOT has_table_privilege('anon','private.job_locations','SELECT'), 'no anon SELECT');
  PERFORM pg_temp.assert_ok(NOT has_function_privilege('service_role','public.get_my_opportunity_location(text)','EXECUTE'), 'no service role execution grant');
  PERFORM pg_temp.assert_ok((SELECT prosecdef AND provolatile='s' AND proconfig @> ARRAY['search_path=""']
    FROM pg_proc WHERE oid='public.get_my_opportunity_location(text)'::regprocedure),'definer stable empty search path');
  PERFORM pg_temp.assert_ok((SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname IN ('public','private') AND c.relkind IN ('r','p'))=(SELECT n FROM loc_table_baseline),'zero new business/infrastructure tables');
  PERFORM pg_temp.assert_ok(NOT EXISTS(SELECT 1 FROM loc_baseline b JOIN pg_proc p ON p.oid=b.oid
    WHERE md5(pg_get_functiondef(p.oid))<>b.hash),'all preexisting function fingerprints unchanged');
END $$;
ROLLBACK;
