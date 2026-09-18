-- V3-BE-5 local SQL verification: availability_status is available | busy.
--
-- Seams:
--   available accepted
--   busy accepted
--   offline rejected
--   unexpected value rejected
--   column default remains available
--   availability UPDATE does not change protected Worker-profile fields
--   matching fingerprints unchanged
--
-- No data rewrite. Disposable fixtures only. ABORT so nothing survives.

BEGIN;

CREATE TEMP TABLE v3_be5_results (
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
  INSERT INTO v3_be5_results(n, name, ok, detail)
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
  p_email text
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
    crypt('v3-be5-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );
  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'V3 BE5 Fixture', '09000000000', 'worker',
    'Santa Ana', 'Pateros', true
  );
END;
$$;

DO $$
DECLARE
  user_avail     uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa61';
  user_busy      uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa62';
  user_off       uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa63';
  user_bad       uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa64';
  user_default   uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa65';
  user_own       uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa66';
  profile_own    uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb66';
  v_status       text;
  v_default      text;
  v_check        text;
  v_hash         text;
  v_verified     boolean;
  v_verified_by  uuid;
  v_rating       double precision;
  v_strike       integer;
  v_badge        text;
BEGIN
  PERFORM pg_temp.mk_user(user_avail, 'v3be5-avail@example.test');
  PERFORM pg_temp.mk_user(user_busy, 'v3be5-busy@example.test');
  PERFORM pg_temp.mk_user(user_off, 'v3be5-off@example.test');
  PERFORM pg_temp.mk_user(user_bad, 'v3be5-bad@example.test');
  PERFORM pg_temp.mk_user(user_default, 'v3be5-default@example.test');
  PERFORM pg_temp.mk_user(user_own, 'v3be5-own@example.test');

  -- 1 catalog: CHECK is available | busy only
  SELECT pg_get_constraintdef(c.oid) INTO v_check
  FROM pg_constraint c
  JOIN pg_class rel ON rel.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = rel.relnamespace
  WHERE n.nspname = 'public'
    AND rel.relname = 'worker_profiles'
    AND c.conname = 'worker_profiles_availability_status_check';
  PERFORM pg_temp.pass(1, 'availability CHECK is available|busy only',
    v_check IS NOT NULL
      AND v_check LIKE '%available%'
      AND v_check LIKE '%busy%'
      AND v_check NOT LIKE '%offline%',
    coalesce(v_check, 'null'));

  -- 2 DEFAULT remains available
  SELECT column_default INTO v_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'worker_profiles'
    AND column_name = 'availability_status';
  PERFORM pg_temp.pass(2, 'availability_status default remains available',
    v_default IS NOT NULL AND v_default LIKE '%available%',
    coalesce(v_default, 'null'));

  -- 3 available accepted
  INSERT INTO public.worker_profiles (user_id, bio, availability_status)
  VALUES (user_avail, NULL, 'available');
  SELECT availability_status INTO v_status
  FROM public.worker_profiles WHERE user_id = user_avail;
  PERFORM pg_temp.pass(3, 'available accepted',
    v_status = 'available', coalesce(v_status, 'null'));

  -- 4 busy accepted
  INSERT INTO public.worker_profiles (user_id, bio, availability_status)
  VALUES (user_busy, NULL, 'busy');
  SELECT availability_status INTO v_status
  FROM public.worker_profiles WHERE user_id = user_busy;
  PERFORM pg_temp.pass(4, 'busy accepted',
    v_status = 'busy', coalesce(v_status, 'null'));

  -- 5 offline rejected
  BEGIN
    INSERT INTO public.worker_profiles (user_id, bio, availability_status)
    VALUES (user_off, NULL, 'offline');
    PERFORM pg_temp.pass(5, 'offline rejected', false, 'insert succeeded');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.pass(5, 'offline rejected',
      SQLSTATE = '23514', SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.pass(5, 'offline rejected',
      SQLSTATE = '23514', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 6 unexpected value rejected
  BEGIN
    INSERT INTO public.worker_profiles (user_id, bio, availability_status)
    VALUES (user_bad, NULL, 'away');
    PERFORM pg_temp.pass(6, 'unexpected availability rejected', false, 'insert succeeded');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.pass(6, 'unexpected availability rejected',
      SQLSTATE = '23514', SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.pass(6, 'unexpected availability rejected',
      SQLSTATE = '23514', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 7 omitted availability uses default available
  INSERT INTO public.worker_profiles (user_id, bio)
  VALUES (user_default, NULL);
  SELECT availability_status INTO v_status
  FROM public.worker_profiles WHERE user_id = user_default;
  PERFORM pg_temp.pass(7, 'omitted availability defaults to available',
    v_status = 'available', coalesce(v_status, 'null'));

  -- 8-9 own-profile availability UPDATE does not change protected fields
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.worker_profiles (
      id, user_id, bio, availability_status
    ) VALUES (
      profile_own, user_own, NULL, 'available'
    );
    PERFORM pg_temp.clear_jwt();
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'own minimal profile insert',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  SELECT is_verified, verified_by, rating_avg, strike_count, badge_level::text,
         availability_status
    INTO v_verified, v_verified_by, v_rating, v_strike, v_badge, v_status
  FROM public.worker_profiles
  WHERE id = profile_own;

  PERFORM pg_temp.pass(8, 'own insert keeps trusted protected initial state',
    v_verified IS FALSE
      AND v_verified_by IS NULL
      AND v_rating = 0
      AND v_strike = 0
      AND v_badge = 'none'
      AND v_status = 'available',
    format('verified=%s by=%s rating=%s strike=%s badge=%s status=%s',
      coalesce(v_verified::text, 'null'),
      coalesce(v_verified_by::text, 'null'),
      coalesce(v_rating::text, 'null'),
      coalesce(v_strike::text, 'null'),
      coalesce(v_badge, 'null'),
      coalesce(v_status, 'null')));

  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    UPDATE public.worker_profiles
       SET availability_status = 'busy'
     WHERE user_id = user_own;
    PERFORM pg_temp.clear_jwt();
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'availability update leaves protected fields',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  SELECT is_verified, verified_by, rating_avg, strike_count, badge_level::text,
         availability_status
    INTO v_verified, v_verified_by, v_rating, v_strike, v_badge, v_status
  FROM public.worker_profiles
  WHERE id = profile_own;

  PERFORM pg_temp.pass(9, 'availability update leaves protected fields',
    v_status = 'busy'
      AND v_verified IS FALSE
      AND v_verified_by IS NULL
      AND v_rating = 0
      AND v_strike = 0
      AND v_badge = 'none',
    format('verified=%s by=%s rating=%s strike=%s badge=%s status=%s',
      coalesce(v_verified::text, 'null'),
      coalesce(v_verified_by::text, 'null'),
      coalesce(v_rating::text, 'null'),
      coalesce(v_strike::text, 'null'),
      coalesce(v_badge, 'null'),
      coalesce(v_status, 'null')));

  -- 10-13 matching fingerprints unchanged
  SELECT md5(pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(10, 'compute_job_matches fingerprint unchanged',
    v_hash = 'b9b686e6b0b9a87ee8618b5600b1ed62', v_hash);
  SELECT md5(pg_get_functiondef('public.match_workers_for_job(uuid)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(11, 'match_workers_for_job fingerprint unchanged',
    v_hash = '9239550ea9da726a3002bb3503d12f73', v_hash);
  SELECT md5(pg_get_functiondef('private.location_points(text,text,text,text)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(12, 'location_points fingerprint unchanged',
    v_hash = '3da08e1ce3b7b7089ff51285a7c33dae', v_hash);
  SELECT md5(pg_get_functiondef('public.list_my_job_opportunities()'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(13, 'list_my_job_opportunities fingerprint unchanged',
    v_hash = 'a135ec4ddac213df3f3ef147f93e0fc9', v_hash);
END;
$$;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM v3_be5_results WHERE NOT ok;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'V3-BE5 FAILED % case(s)', v_fail;
  END IF;
  RAISE NOTICE 'V3-BE5 % / % PASS',
    (SELECT count(*) FROM v3_be5_results WHERE ok),
    (SELECT count(*) FROM v3_be5_results);
END;
$$;

ABORT;
