-- V3-DB2 local SQL verification: private.worker_id_documents + worker-identity bucket.
--
-- Seams:
--   private table / private bucket
--   own-worker submit + get
--   other-worker / client / anon denial
--   invalid type/path/missing object
--   upload does not set is_verified
--   pending supersede
--   approved resubmit SM409
--   storage SELECT/INSERT ACL
--
-- Disposable fixtures only. ABORT so nothing survives.

BEGIN;

CREATE TEMP TABLE v3_db2_results (
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
  INSERT INTO v3_db2_results(n, name, ok, detail)
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
  p_role text
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
    crypt('v3-db2-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );
  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'V3 DB2 Fixture', '09000000000', p_role,
    'Santa Ana', 'Pateros', true
  );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_worker(
  p_user_id uuid,
  p_profile_id uuid,
  p_email text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_temp.mk_user(p_user_id, p_email, 'worker');
  INSERT INTO public.worker_profiles (
    id, user_id, bio, badge_level, availability_status, is_verified
  ) VALUES (
    p_profile_id, p_user_id, 'local fixture', 'none', 'available', false
  );
END;
$$;

DO $$
DECLARE
  worker_own     uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  worker_other   uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  client_user    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa03';
  profile_own    uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  profile_other  uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
  file_own       uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc01';
  file_own2      uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc02';
  file_other     uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc03';
  path_own       text;
  path_own2      text;
  path_other     text;
  v_public       boolean;
  v_limit        bigint;
  v_mimes        text[];
  v_count        int;
  v_seen         int;
  v_status       text;
  v_type         text;
  v_verified     boolean;
  v_id           uuid;
BEGIN
  PERFORM pg_temp.mk_worker(worker_own, profile_own, 'v3db2-own@example.test');
  PERFORM pg_temp.mk_worker(worker_other, profile_other, 'v3db2-other@example.test');
  PERFORM pg_temp.mk_user(client_user, 'v3db2-client@example.test', 'client');

  path_own := profile_own::text || '/' || file_own::text || '.jpg';
  path_own2 := profile_own::text || '/' || file_own2::text || '.png';
  path_other := profile_other::text || '/' || file_other::text || '.jpg';

  -- 1-4 catalog
  PERFORM pg_temp.pass(1, 'private.worker_id_documents exists',
    to_regclass('private.worker_id_documents') IS NOT NULL);

  PERFORM pg_temp.pass(2, 'no public.worker_id_documents',
    to_regclass('public.worker_id_documents') IS NULL);

  PERFORM pg_temp.pass(3, 'public application table count remains 13',
    (SELECT count(*) FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r') = 13);

  SELECT public, file_size_limit, allowed_mime_types
    INTO v_public, v_limit, v_mimes
  FROM storage.buckets
  WHERE id = 'worker-identity';
  PERFORM pg_temp.pass(4, 'worker-identity bucket is private jpeg/png/webp 5MiB',
    v_public IS FALSE
    AND v_limit = 5242880
    AND v_mimes @> ARRAY['image/jpeg','image/png','image/webp']::text[]
    AND cardinality(v_mimes) = 3,
    coalesce(v_public::text, 'null') || ' ' || coalesce(v_limit::text, 'null'));

  PERFORM pg_temp.pass(5, 'authenticated has no private.worker_id_documents privileges',
    NOT has_table_privilege('authenticated', 'private.worker_id_documents', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.worker_id_documents', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'private.worker_id_documents', 'UPDATE')
    AND NOT has_table_privilege('anon', 'private.worker_id_documents', 'SELECT'));

  -- 6 owner storage INSERT
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('worker-identity', path_own);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'own Worker can INSERT identity object',
      v_count = 1, 'inserted=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'own Worker can INSERT identity object',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 7 other Worker cannot INSERT into owner folder
  BEGIN
    PERFORM pg_temp.jwt(worker_other);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('worker-identity', profile_own::text || '/' || file_other::text || '.jpg');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'other Worker INSERT into owner folder denied', false, 'inserted');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'other Worker INSERT into owner folder denied', true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'other Worker INSERT into owner folder denied',
      SQLSTATE IN ('42501', 'P0001'), SQLSTATE || ' ' || SQLERRM);
  END;

  -- 8 Client INSERT denied
  BEGIN
    PERFORM pg_temp.jwt(client_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('worker-identity', path_own2);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'Client INSERT identity object denied', false, 'inserted');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'Client INSERT identity object denied', true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'Client INSERT identity object denied',
      SQLSTATE IN ('42501', 'P0001'), SQLSTATE || ' ' || SQLERRM);
  END;

  -- 9 own submit success, is_verified stays false
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    SELECT s.id, s.status, s.id_type
      INTO v_id, v_status, v_type
    FROM public.submit_my_valid_id('national_id', path_own) AS s;
    PERFORM pg_temp.clear_jwt();
    SELECT wp.is_verified INTO v_verified
    FROM public.worker_profiles wp WHERE wp.user_id = worker_own;
    PERFORM pg_temp.pass(9, 'own submit_my_valid_id pending and does not verify',
      v_id IS NOT NULL AND v_status = 'pending' AND v_type = 'national_id'
        AND v_verified IS DISTINCT FROM true,
      coalesce(v_status, 'null') || ' verified=' || coalesce(v_verified::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'own submit_my_valid_id pending and does not verify',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 10 own get
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    SELECT s.status, s.id_type INTO v_status, v_type
    FROM public.get_my_identity_submission() AS s;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'own get_my_identity_submission returns pending',
      v_status = 'pending' AND v_type = 'national_id',
      coalesce(v_status, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'own get_my_identity_submission returns pending',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 11 other Worker get is empty
  BEGIN
    PERFORM pg_temp.jwt(worker_other);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count FROM public.get_my_identity_submission();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'other Worker get_my_identity_submission is empty',
      v_count = 0, v_count::text);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'other Worker get_my_identity_submission is empty',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 12 Client get empty (no worker_id_documents row)
  BEGIN
    PERFORM pg_temp.jwt(client_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count FROM public.get_my_identity_submission();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'Client get_my_identity_submission is empty',
      v_count = 0, v_count::text);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'Client get_my_identity_submission is empty',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 13 Client submit denied
  BEGIN
    PERFORM pg_temp.jwt(client_user);
    SET LOCAL ROLE authenticated;
    PERFORM public.submit_my_valid_id('national_id', path_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'Client submit_my_valid_id denied', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'Client submit_my_valid_id denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 14 anon submit denied
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('role', 'anon', true);
    PERFORM public.submit_my_valid_id('national_id', path_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'anon submit_my_valid_id denied', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'anon submit_my_valid_id denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 15 invalid type
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.submit_my_valid_id('sss_id', path_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(15, 'invalid id_type rejected 22023', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(15, 'invalid id_type rejected 22023',
      SQLSTATE = '22023', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 16 invalid path
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.submit_my_valid_id('passport', 'not-a-path.jpg');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(16, 'invalid storage_path rejected 22023', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(16, 'invalid storage_path rejected 22023',
      SQLSTATE = '22023', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 17 missing object
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.submit_my_valid_id(
      'umid',
      profile_own::text || '/dddddddd-dddd-4ddd-8ddd-dddddddddd01.jpg'
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(17, 'missing identity object rejected 22023', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(17, 'missing identity object rejected 22023',
      SQLSTATE = '22023', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 18 other Worker SELECT owner object denied
  BEGIN
    PERFORM pg_temp.jwt(worker_other);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'worker-identity' AND name = path_own;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(18, 'other Worker cannot SELECT owner identity object',
      v_seen = 0, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(18, 'other Worker cannot SELECT owner identity object',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 19 Client SELECT denied
  BEGIN
    PERFORM pg_temp.jwt(client_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'worker-identity' AND name = path_own;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(19, 'Client cannot SELECT identity object',
      v_seen = 0, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(19, 'Client cannot SELECT identity object',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 20 owner SELECT allowed
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'worker-identity' AND name = path_own;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(20, 'own Worker can SELECT identity object',
      v_seen = 1, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(20, 'own Worker can SELECT identity object',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 21 authenticated cannot SELECT private table
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM 1 FROM private.worker_id_documents;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(21, 'authenticated SELECT private.worker_id_documents denied',
      false, 'select succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(21, 'authenticated SELECT private.worker_id_documents denied',
      true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(21, 'authenticated SELECT private.worker_id_documents denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 22 resubmit supersedes pending
  INSERT INTO storage.objects (bucket_id, name)
  VALUES ('worker-identity', path_own2);
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    SELECT s.status, s.storage_path INTO v_status, v_type
    FROM public.submit_my_valid_id('passport', path_own2) AS s;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(22, 'resubmit creates new pending passport',
      v_status = 'pending' AND v_type = path_own2, coalesce(v_status, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(22, 'resubmit creates new pending passport',
      false, SQLSTATE || ' ' || SQLERRM);
  END;
  SELECT count(*) INTO v_count
  FROM private.worker_id_documents
  WHERE user_id = worker_own AND status = 'superseded';
  PERFORM pg_temp.pass(23, 'previous pending row is superseded',
    v_count = 1, v_count::text);

  -- 24 approved resubmit SM409
  UPDATE private.worker_id_documents
  SET status = 'approved'
  WHERE user_id = worker_own AND status = 'pending';
  INSERT INTO storage.objects (bucket_id, name)
  VALUES (
    'worker-identity',
    profile_own::text || '/eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01.webp'
  );
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.submit_my_valid_id(
      'postal_id',
      profile_own::text || '/eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01.webp'
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(24, 'approved Worker resubmit SM409', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(24, 'approved Worker resubmit SM409',
      SQLSTATE = 'SM409', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 25 still not flipping is_verified
  SELECT wp.is_verified INTO v_verified
  FROM public.worker_profiles wp WHERE wp.user_id = worker_own;
  PERFORM pg_temp.pass(25, 'is_verified remains false after submit paths',
    v_verified IS DISTINCT FROM true, coalesce(v_verified::text, 'null'));

  -- 26 grants
  PERFORM pg_temp.pass(26, 'authenticated EXECUTE submit_my_valid_id',
    has_function_privilege('authenticated', 'public.submit_my_valid_id(text,text)', 'EXECUTE'));
  PERFORM pg_temp.pass(27, 'anon EXECUTE submit_my_valid_id revoked',
    NOT has_function_privilege('anon', 'public.submit_my_valid_id(text,text)', 'EXECUTE'));
  PERFORM pg_temp.pass(28, 'anon EXECUTE get_my_identity_submission revoked',
    NOT has_function_privilege('anon', 'public.get_my_identity_submission()', 'EXECUTE'));

  -- 29 allowed types exist as check
  PERFORM pg_temp.pass(29, 'id_type check lists the five locked values',
    EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'private.worker_id_documents'::regclass
        AND conname = 'worker_id_documents_id_type_chk'
        AND pg_get_constraintdef(oid) LIKE '%national_id%'
        AND pg_get_constraintdef(oid) LIKE '%drivers_license%'
        AND pg_get_constraintdef(oid) LIKE '%passport%'
        AND pg_get_constraintdef(oid) LIKE '%umid%'
        AND pg_get_constraintdef(oid) LIKE '%postal_id%'
    ));
END;
$$;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM v3_db2_results WHERE NOT ok;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'V3-DB2 FAILED % case(s)', v_fail;
  END IF;
  RAISE NOTICE 'V3-DB2 % / % PASS',
    (SELECT count(*) FROM v3_db2_results WHERE ok),
    (SELECT count(*) FROM v3_db2_results);
END;
$$;

ABORT;
