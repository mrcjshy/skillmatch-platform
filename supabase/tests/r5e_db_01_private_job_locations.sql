-- R5E-DB1 local SQL verification.
--
-- Confirmed seams (docs/SECURITY.md R5E-D1):
--   atomic Job + skills + coordinates creation
--   owning Client open-Job read/update
--   unassigned Worker exact-coordinate denial
--   opportunity RPC contains no exact coordinates/address
--   confirmed assigned Worker allow
--   confirmed owning Client allow
--   nonparticipant denial
--   completed/cancelled/no_show denial
--   malformed/out-of-range/nonfinite coordinate rejection
--   matching-function fingerprints unchanged
--   legacy coordinate-null Job compatibility
--   authenticated-wide job_postings.address SELECT closed
--
-- Disposable fixtures only. ABORT so nothing survives.

BEGIN;

CREATE TEMP TABLE r5e_db1_results (
  n      int,
  name   text,
  ok     boolean,
  detail text
);

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO r5e_db1_results(n, name, ok, detail)
  VALUES (p_n, p_name, p_ok, p_detail);
  IF NOT p_ok THEN
    RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  ELSE
    RAISE NOTICE 'PASS % %', p_n, p_name;
  END IF;
END;
$$;

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

DO $$
DECLARE
  client_own     uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  client_other   uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  worker_asg     uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  worker_other   uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
  profile_asg    uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc01';
  profile_other  uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc02';
  skill_id       uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddd01';
  job_open       uuid;
  job_conf       uuid;
  job_done       uuid;
  job_cancel     uuid;
  job_noshow     uuid;
  job_legacy     uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';
  booking_conf   uuid;
  booking_done   uuid;
  booking_cancel uuid;
  booking_noshow uuid := 'ffffffff-ffff-4fff-8fff-ffffffffff01';
  booking_legacy uuid := 'ffffffff-ffff-4fff-8fff-ffffffffff02';
  v_count        int;
  v_addr         int;
  v_lat          double precision;
  v_lng          double precision;
  v_key          text;
  v_def          text;
  v_sqlstate     text;
  v_hash         text;
  v_pts          integer;
  v_skill        numeric;
  v_loc          numeric;
  v_rat          numeric;
  v_total        numeric;
  v_new          boolean;
  v_json         jsonb;
  v_address      text;
BEGIN
  PERFORM pg_temp.mk_user(client_own, 'r5e-db1-cown@example.test', 'client', true);
  PERFORM pg_temp.mk_user(client_other, 'r5e-db1-coth@example.test', 'client', true);
  PERFORM pg_temp.mk_worker(worker_asg, profile_asg, 'r5e-db1-wasg@example.test', true);
  PERFORM pg_temp.mk_worker(worker_other, profile_other, 'r5e-db1-woth@example.test', true);

  INSERT INTO public.skills (id, skill_name, category)
  VALUES (skill_id, 'R5E DB1 Plumbing', 'trade');

  INSERT INTO public.worker_skills (worker_id, skill_id, proficiency_level)
  VALUES (profile_asg, skill_id, 'intermediate'),
         (profile_other, skill_id, 'beginner');

  -- 1-4 catalog
  PERFORM pg_temp.pass(1, 'private.job_locations exists',
    to_regclass('private.job_locations') IS NOT NULL);

  PERFORM pg_temp.pass(2, 'public application table count remains 13',
    (SELECT count(*) FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r') = 13);

  PERFORM pg_temp.pass(3, 'no latitude/longitude on job_postings',
    NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'job_postings'
        AND column_name IN ('latitude', 'longitude', 'lat', 'lng')
    ));

  PERFORM pg_temp.pass(4, 'authenticated/anon have no private.job_locations privileges',
    NOT has_table_privilege('authenticated', 'private.job_locations', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.job_locations', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'private.job_locations', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'private.job_locations', 'DELETE')
    AND NOT has_table_privilege('anon', 'private.job_locations', 'SELECT')
    AND NOT has_table_privilege('anon', 'private.job_locations', 'INSERT'));

  PERFORM pg_temp.pass(5, 'authenticated cannot SELECT job_postings.address',
    NOT has_column_privilege('authenticated', 'public.job_postings', 'address', 'SELECT')
    AND NOT has_column_privilege('anon', 'public.job_postings', 'address', 'SELECT'));

  PERFORM pg_temp.pass(6, 'authenticated still SELECT non-address job columns',
    has_column_privilege('authenticated', 'public.job_postings', 'id', 'SELECT')
    AND has_column_privilege('authenticated', 'public.job_postings', 'title', 'SELECT')
    AND has_column_privilege('authenticated', 'public.job_postings', 'barangay', 'SELECT')
    AND has_column_privilege('authenticated', 'public.job_postings', 'payment_method', 'SELECT'));

  -- 7-9 matching fingerprints (pre-change local baseline)
  SELECT md5(pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(7, 'compute_job_matches fingerprint unchanged',
    v_hash = 'b9b686e6b0b9a87ee8618b5600b1ed62', v_hash);

  SELECT md5(pg_get_functiondef('public.match_workers_for_job(uuid)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(8, 'match_workers_for_job fingerprint unchanged',
    v_hash = '9239550ea9da726a3002bb3503d12f73', v_hash);

  SELECT md5(pg_get_functiondef('private.location_points(text,text,text,text)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(9, 'location_points fingerprint unchanged',
    v_hash = '3da08e1ce3b7b7089ff51285a7c33dae', v_hash);

  SELECT md5(pg_get_functiondef('public.list_my_job_opportunities()'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(10, 'list_my_job_opportunities fingerprint unchanged',
    v_hash = 'a135ec4ddac213df3f3ef147f93e0fc9', v_hash);

  v_def := pg_get_function_result('public.list_my_job_opportunities()'::regprocedure);
  PERFORM pg_temp.pass(11, 'opportunity RPC result type has no address/coordinates',
    v_def NOT ILIKE '%address%'
    AND v_def NOT ILIKE '%latitude%'
    AND v_def NOT ILIKE '%longitude%',
    v_def);

  -- 12 location_points behavior
  SELECT private.location_points('Santa Ana', 'Pateros', 'Santa Ana', 'Pateros') INTO v_pts;
  PERFORM pg_temp.pass(12, 'location_points same barangay+city = 30', v_pts = 30, v_pts::text);
  SELECT private.location_points('San Roque', 'Pateros', 'Santa Ana', 'Pateros') INTO v_pts;
  PERFORM pg_temp.pass(13, 'location_points same city only = 10', v_pts = 10, v_pts::text);
  SELECT private.location_points('Santa Ana', 'Makati', 'Santa Ana', 'Pateros') INTO v_pts;
  PERFORM pg_temp.pass(14, 'location_points otherwise = 0', v_pts = 0, v_pts::text);

  -- 15-18 direct private table denial
  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM 1 FROM private.job_locations;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(15, 'authenticated SELECT private.job_locations denied', false, 'select succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(15, 'authenticated SELECT private.job_locations denied', true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(15, 'authenticated SELECT private.job_locations denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    INSERT INTO private.job_locations (job_id, latitude, longitude)
    VALUES (job_legacy, 14.55, 121.07);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(16, 'authenticated INSERT private.job_locations denied', false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(16, 'authenticated INSERT private.job_locations denied', true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(16, 'authenticated INSERT private.job_locations denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 17 atomic create success
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    job_open := public.create_my_job_with_location(
      'R5E-DB1 Open',
      'fixture open',
      '123 Test Street, Santa Ana',
      now() + interval '2 days',
      500,
      'cod',
      ARRAY[skill_id],
      14.54445140,
      121.07205067
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(17, 'owning Client atomic create returns job id',
      job_open IS NOT NULL, coalesce(job_open::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(17, 'owning Client atomic create returns job id', false, SQLSTATE || ' ' || SQLERRM);
  END;

  SELECT count(*) INTO v_count FROM public.job_skills WHERE job_id = job_open;
  SELECT count(*) INTO v_addr FROM private.job_locations WHERE job_id = job_open;
  PERFORM pg_temp.pass(18, 'atomic create wrote job skills and private location',
    job_open IS NOT NULL AND v_count = 1 AND v_addr = 1,
    'skills=' || v_count || ' loc=' || v_addr);

  PERFORM pg_temp.pass(19, 'create forces Santa Ana / Pateros and stores address',
    EXISTS (
      SELECT 1 FROM public.job_postings
      WHERE id = job_open AND barangay = 'Santa Ana' AND city = 'Pateros'
        AND address = '123 Test Street, Santa Ana'
    ));

  -- 20 owner open exact read
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    SELECT latitude, longitude INTO v_lat, v_lng
    FROM public.get_authorized_job_location(job_open);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(20, 'owning Client reads exact pin while Job is open',
      v_lat = 14.54445140 AND v_lng = 121.07205067,
      coalesce(v_lat::text, 'null') || ',' || coalesce(v_lng::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(20, 'owning Client reads exact pin while Job is open', false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 21 other Client denied on open Job
  BEGIN
    PERFORM pg_temp.jwt(client_other);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_open);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(21, 'other Client denied exact pin on open Job', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(21, 'other Client denied exact pin on open Job',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  -- 22 unassigned Worker denied exact
  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_open);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(22, 'unassigned Worker denied exact pin', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(22, 'unassigned Worker denied exact pin',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  -- 23 approximate area for eligible Worker, no coordinates
  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT to_jsonb(t) INTO v_json
    FROM public.get_job_approximate_area(job_open) AS t;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(23, 'eligible Worker approximate area has no coordinates',
      (v_json ->> 'approximate_area_key') = 'santa_ana_pateros'
      AND NOT (v_json ? 'latitude')
      AND NOT (v_json ? 'longitude')
      AND NOT (v_json ? 'address'),
      coalesce(v_json::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(23, 'eligible Worker approximate area has no coordinates',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 24 opportunity row has no address/lat/lng
  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT to_jsonb(t) INTO v_json FROM public.list_my_job_opportunities() AS t
    WHERE t.job_id = job_open;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(24, 'opportunity row omits address and coordinates',
      v_json IS NOT NULL
      AND NOT (v_json ? 'address')
      AND NOT (v_json ? 'latitude')
      AND NOT (v_json ? 'longitude')
      AND (v_json ->> 'barangay') = 'Santa Ana',
      coalesce(v_json::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(24, 'opportunity row omits address and coordinates',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 25-28 invalid create rolls back
  SELECT count(*) INTO v_count FROM public.job_postings WHERE client_id = client_own;
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'R5E-DB1 Bad Lat', 'x', '1 Street', now() + interval '2 days',
      100, 'cod', ARRAY[skill_id], 95, 121.07);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(25, 'invalid latitude rejected', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(25, 'invalid latitude rejected', SQLSTATE = '22023', SQLSTATE);
  END;
  PERFORM pg_temp.pass(26, 'invalid latitude left no orphan Job',
    (SELECT count(*) FROM public.job_postings WHERE client_id = client_own) = v_count);

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'R5E-DB1 Bad Lng', 'x', '1 Street', now() + interval '2 days',
      100, 'cod', ARRAY[skill_id], 14.55, 200);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(27, 'invalid longitude rejected', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(27, 'invalid longitude rejected', SQLSTATE = '22023', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'R5E-DB1 NaN', 'x', '1 Street', now() + interval '2 days',
      100, 'cod', ARRAY[skill_id], 'NaN'::float8, 121.07);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(28, 'nonfinite latitude rejected', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(28, 'nonfinite latitude rejected', SQLSTATE = '22023', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'R5E-DB1 Bad Skill', 'x', '1 Street', now() + interval '2 days',
      100, 'cod', ARRAY['99999999-9999-4999-8999-999999999999'::uuid],
      14.54445140, 121.07205067);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(29, 'invalid skill rejected', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(29, 'invalid skill rejected', SQLSTATE = '22023', SQLSTATE);
  END;
  PERFORM pg_temp.pass(30, 'invalid skill left no orphan Job or location',
    (SELECT count(*) FROM public.job_postings WHERE client_id = client_own) = v_count
    AND (SELECT count(*) FROM private.job_locations) = 1);

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'R5E-DB1 Worker Create', 'x', '1 Street', now() + interval '2 days',
      100, 'cod', ARRAY[skill_id], 14.54445140, 121.07205067);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(31, 'Worker create denied', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(31, 'Worker create denied', SQLSTATE = '42501', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'R5E-DB1 Blank Addr', 'x', '   ', now() + interval '2 days',
      100, 'cod', ARRAY[skill_id], 14.54445140, 121.07205067);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(32, 'blank address rejected', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(32, 'blank address rejected', SQLSTATE = '22023', SQLSTATE);
  END;

  -- 33 matching score for created open Job
  SELECT skill_points, location_points, rating_points, total_points, is_new_worker
    INTO v_skill, v_loc, v_rat, v_total, v_new
  FROM private.compute_job_matches(job_open)
  WHERE worker_id = worker_asg;
  PERFORM pg_temp.pass(33, 'matching 50/30/12 unchanged by coordinates',
    v_skill = 50 AND v_loc = 30 AND v_rat = 12 AND v_total = 92 AND v_new IS TRUE,
    coalesce(v_skill::text,'n') || '/' || coalesce(v_loc::text,'n') || '/' ||
    coalesce(v_rat::text,'n') || '/' || coalesce(v_total::text,'n'));

  -- 34 owner update while open
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.update_my_open_job_location(
      job_open, '456 Other Street, Santa Ana', 14.54525377225, 121.07293277825);
    SELECT latitude, longitude
      INTO v_lat, v_lng
    FROM public.get_authorized_job_location(job_open);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(34, 'owning Client can update open Job pin and address',
      v_lat = 14.54525377225 AND v_lng = 121.07293277825,
      coalesce(v_lat::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(34, 'owning Client can update open Job pin and address',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 35-36 confirmed participant path via real N9 accept
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    job_conf := public.create_my_job_with_location(
      'R5E-DB1 Confirmed',
      'fixture confirmed',
      '789 Confirmed Street',
      now() + interval '3 days',
      800,
      'cod',
      ARRAY[skill_id],
      14.54359874,
      121.0719468515
    );
    PERFORM pg_temp.clear_jwt();
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    RAISE NOTICE 'create confirmed fixture failed % %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT booking_id INTO booking_conf
    FROM public.accept_job_opportunity(job_conf);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(35, 'N9 accept still creates confirmed Booking',
      booking_conf IS NOT NULL, coalesce(booking_conf::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(35, 'N9 accept still creates confirmed Booking',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT address, latitude, longitude INTO v_address, v_lat, v_lng
    FROM public.get_authorized_job_location(job_conf);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(36, 'confirmed assigned Worker receives exact pin',
      v_address = '789 Confirmed Street' AND v_lat = 14.54359874 AND v_lng = 121.0719468515,
      coalesce(v_address, 'null') || ' ' || coalesce(v_lat::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(36, 'confirmed assigned Worker receives exact pin',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_other);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_conf);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(37, 'different Worker denied confirmed exact pin', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(37, 'different Worker denied confirmed exact pin',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    SELECT latitude INTO v_lat FROM public.get_authorized_job_location(job_conf);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(38, 'owning Client receives exact pin while confirmed',
      v_lat = 14.54359874, coalesce(v_lat::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(38, 'owning Client receives exact pin while confirmed',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_other);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_conf);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(39, 'unrelated Client denied confirmed exact pin', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(39, 'unrelated Client denied confirmed exact pin',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.update_my_open_job_location(
      job_conf, 'should fail', 14.54445140, 121.07205067);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(40, 'owner cannot update pin after acceptance', false, 'updated');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(40, 'owner cannot update pin after acceptance',
      SQLSTATE IN ('SM409', '42501'), SQLSTATE);
  END;

  -- 41 completed denial via real completion RPC
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    job_done := public.create_my_job_with_location(
      'R5E-DB1 Completed', 'fixture done', '1 Done Street',
      now() + interval '4 days', 200, 'cod', ARRAY[skill_id], 14.54355724325, 121.07118653675);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT booking_id INTO booking_done FROM public.accept_job_opportunity(job_done);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.complete_my_client_booking(booking_done);
    PERFORM pg_temp.clear_jwt();
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    RAISE NOTICE 'completed fixture failed % %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_done);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(41, 'completed Booking denies exact location', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(41, 'completed Booking denies exact location',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_done);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(42, 'completed owning Client denied exact location', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(42, 'completed owning Client denied exact location',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  -- 43 cancelled
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    job_cancel := public.create_my_job_with_location(
      'R5E-DB1 Cancelled', 'fixture cancel', '1 Cancel Street',
      now() + interval '5 days', 200, 'cod', ARRAY[skill_id], 14.544682182, 121.07129711875);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT booking_id INTO booking_cancel FROM public.accept_job_opportunity(job_cancel);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.cancel_my_booking(
      booking_cancel,
      'unable_to_continue',
      NULL
    );
    PERFORM pg_temp.clear_jwt();
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    RAISE NOTICE 'cancelled fixture failed % %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_cancel);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(43, 'cancelled Booking denies exact location', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(43, 'cancelled Booking denies exact location',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  -- 44 no_show (no producer; postgres writes the terminal status)
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    job_noshow := public.create_my_job_with_location(
      'R5E-DB1 NoShow', 'fixture noshow', '1 Noshow Street',
      now() + interval '6 days', 200, 'cod', ARRAY[skill_id], 14.54508736575, 121.07325456375);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM public.accept_job_opportunity(job_noshow);
    PERFORM pg_temp.clear_jwt();
    UPDATE public.bookings SET status = 'no_show'
    WHERE job_id = job_noshow AND worker_id = worker_asg;
    UPDATE public.job_postings SET status = 'cancelled' WHERE id = job_noshow;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    RAISE NOTICE 'noshow fixture failed % %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_noshow);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(44, 'no_show Booking denies exact location', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(44, 'no_show Booking denies exact location',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  -- 45 stale/deep-link missing id
  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(
      '00000000-0000-4000-8000-000000000000');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(45, 'unknown job id fail-closed', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(45, 'unknown job id fail-closed',
      SQLSTATE IN ('SM409', '42501'), SQLSTATE);
  END;

  -- 46-47 authenticated cannot SELECT another Job's address
  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM address FROM public.job_postings WHERE id = job_open;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(46, 'direct SELECT address denied for authenticated Worker',
      false, 'select succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(46, 'direct SELECT address denied for authenticated Worker', true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(46, 'direct SELECT address denied for authenticated Worker',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM id, title, barangay, city FROM public.job_postings WHERE id = job_open;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(47, 'direct SELECT of non-address Job columns still works', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(47, 'direct SELECT of non-address Job columns still works',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 48 legacy Job without coordinates
  INSERT INTO public.job_postings (
    id, client_id, title, description, address, barangay, city, status, payment_method
  ) VALUES (
    job_legacy, client_own, 'R5E-DB1 Legacy', 'text only',
    'Legacy House 9', 'Santa Ana', 'Pateros', 'matched', 'cod'
  );
  INSERT INTO public.bookings (
    id, job_id, worker_id, client_id, status
  ) VALUES (
    booking_legacy, job_legacy, worker_asg, client_own, 'confirmed'
  );

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT address, latitude, longitude
      INTO v_address, v_lat, v_lng
    FROM public.get_authorized_job_location(job_legacy);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(48, 'legacy confirmed Job returns address with null coordinates',
      v_address = 'Legacy House 9' AND v_lat IS NULL AND v_lng IS NULL,
      coalesce(v_address, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(48, 'legacy confirmed Job returns address with null coordinates',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 49 one location row per Job
  PERFORM pg_temp.pass(49, 'one private location row per located Job',
    (SELECT count(*) FROM private.job_locations jl
     JOIN public.job_postings jp ON jp.id = jl.job_id) =
    (SELECT count(DISTINCT job_id) FROM private.job_locations),
    'rows=' || (SELECT count(*) FROM private.job_locations)::text);

  -- 50 R3B booking list still suppresses terminal address
  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT job_address INTO v_address
    FROM public.list_my_worker_bookings()
    WHERE booking_id = booking_done;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(50, 'R3B worker list suppresses completed job_address',
      v_address IS NULL, coalesce(v_address, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(50, 'R3B worker list suppresses completed job_address',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 51 two different pins share the same non-pin area key
  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    SELECT approximate_area_key INTO v_key
    FROM public.get_job_approximate_area(job_open);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(51, 'approximate area key is independent of the exact pin',
      v_key = 'santa_ana_pateros'
      AND EXISTS (
        SELECT 1 FROM private.job_locations WHERE job_id = job_open
          AND latitude = 14.54525377225 AND longitude = 121.07293277825
      )
      AND EXISTS (
        SELECT 1 FROM private.job_locations WHERE job_id = job_conf
          AND latitude = 14.54359874 AND longitude = 121.0719468515
      ),
      coalesce(v_key, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(51, 'approximate area key is independent of the exact pin',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_job_approximate_area(job_conf);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(52, 'matched Job denies pre-accept approximate area', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(52, 'matched Job denies pre-accept approximate area',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_authorized_job_location(job_cancel);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(53, 'cancelled owning Client denied exact location', false, 'returned row');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(53, 'cancelled owning Client denied exact location',
      SQLSTATE = 'SM409', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'R5E-DB1 No Skills', 'x', '1 Street', now() + interval '2 days',
      100, 'cod', ARRAY[]::uuid[], 14.54445140, 121.07205067);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(54, 'empty skill list rejected', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(54, 'empty skill list rejected', SQLSTATE = '22023', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM address FROM public.job_postings WHERE id = job_open;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(55, 'owning Client cannot direct-SELECT address', false, 'select succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(55, 'owning Client cannot direct-SELECT address', true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(55, 'owning Client cannot direct-SELECT address',
      SQLSTATE = '42501', SQLSTATE);
  END;

  BEGIN
    PERFORM pg_temp.jwt(worker_asg);
    SET LOCAL ROLE authenticated;
    UPDATE private.job_locations SET latitude = 1 WHERE job_id = job_open;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(56, 'authenticated UPDATE/DELETE private.job_locations denied', false, 'update succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(56, 'authenticated UPDATE/DELETE private.job_locations denied', true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(56, 'authenticated UPDATE/DELETE private.job_locations denied',
      SQLSTATE = '42501', SQLSTATE);
  END;
END;
$$;

SELECT n, name, ok, detail
FROM r5e_db1_results
ORDER BY n;

SELECT
  count(*) FILTER (WHERE ok) AS passed,
  count(*) FILTER (WHERE NOT ok) AS failed,
  count(*) AS total
FROM r5e_db1_results;

ABORT;
