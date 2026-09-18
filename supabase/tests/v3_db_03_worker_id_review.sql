-- V3-DB3 local SQL verification: ID review queue, approve, reject.
--
-- Seams:
--   admin pending queue
--   get_worker_identity_for_review
--   approve wraps verify_worker (sole is_verified writer)
--   reject leaves is_verified false
--   42501 non-admin / anon
--   SM409 unavailable targets
--   admin exact-object SELECT while pending
--   client/other-worker object denial
--
-- Disposable fixtures only. ABORT so nothing survives.

BEGIN;

CREATE TEMP TABLE v3_db3_results (
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
  INSERT INTO v3_db3_results(n, name, ok, detail)
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
    crypt('v3-db3-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );
  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'V3 DB3 Fixture', '09000000000', p_role,
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
  admin_user     uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  worker_own     uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  worker_other   uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa03';
  client_user    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa04';
  profile_own    uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  profile_other  uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
  file_own       uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc01';
  path_own       text;
  v_count        int;
  v_seen         int;
  v_status       text;
  v_reason       text;
  v_verified     boolean;
  v_verified_by  uuid;
  v_doc          uuid;
  v_uid          uuid;
  v_hash         text;
  v_path         text;
BEGIN
  PERFORM pg_temp.mk_user(admin_user, 'v3db3-admin@example.test', 'administrator');
  PERFORM pg_temp.mk_worker(worker_own, profile_own, 'v3db3-own@example.test');
  PERFORM pg_temp.mk_worker(worker_other, profile_other, 'v3db3-other@example.test');
  PERFORM pg_temp.mk_user(client_user, 'v3db3-client@example.test', 'client');

  path_own := profile_own::text || '/' || file_own::text || '.jpg';
  INSERT INTO storage.objects (bucket_id, name)
  VALUES ('worker-identity', path_own);

  PERFORM pg_temp.jwt(worker_own);
  SET LOCAL ROLE authenticated;
  PERFORM public.submit_my_valid_id('drivers_license', path_own);
  PERFORM pg_temp.clear_jwt();

  -- 1 admin queue contains the pending worker
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count FROM public.list_workers_pending_id_review();
    SELECT user_id, id_type INTO v_uid, v_status
    FROM public.list_workers_pending_id_review()
    WHERE user_id = worker_own;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(1, 'admin pending queue lists the submitting Worker',
      v_count = 1 AND v_uid = worker_own AND v_status = 'drivers_license',
      coalesce(v_count::text, 'null') || ' ' || coalesce(v_status, ''));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(1, 'admin pending queue lists the submitting Worker',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 2 Worker denied queue
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.list_workers_pending_id_review();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(2, 'Worker list_workers_pending_id_review 42501', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(2, 'Worker list_workers_pending_id_review 42501',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 3 Client denied queue
  BEGIN
    PERFORM pg_temp.jwt(client_user);
    SET LOCAL ROLE authenticated;
    PERFORM public.list_workers_pending_id_review();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'Client list_workers_pending_id_review 42501', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'Client list_workers_pending_id_review 42501',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 4 anon denied queue
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('role', 'anon', true);
    PERFORM public.list_workers_pending_id_review();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(4, 'anon list_workers_pending_id_review 42501', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(4, 'anon list_workers_pending_id_review 42501',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 5 admin review payload
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    SELECT user_id, storage_path, id_type
      INTO v_uid, v_path, v_status
    FROM public.get_worker_identity_for_review(worker_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(5, 'admin get_worker_identity_for_review returns pending path',
      v_uid = worker_own AND v_path = path_own AND v_status = 'drivers_license',
      coalesce(v_path, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(5, 'admin get_worker_identity_for_review returns pending path',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 6 SM409 missing target
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    PERFORM public.get_worker_identity_for_review('99999999-9999-4999-8999-999999999999');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'missing identity review target SM409', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'missing identity review target SM409',
      SQLSTATE = 'SM409', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 7 Worker cannot get another worker for review
  BEGIN
    PERFORM pg_temp.jwt(worker_other);
    SET LOCAL ROLE authenticated;
    PERFORM public.get_worker_identity_for_review(worker_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'other Worker get_worker_identity_for_review 42501', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'other Worker get_worker_identity_for_review 42501',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 8 admin SELECT pending object
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'worker-identity' AND name = path_own;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'admin SELECT pending identity object allowed',
      v_seen = 1, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'admin SELECT pending identity object allowed',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 9 Client still cannot SELECT
  BEGIN
    PERFORM pg_temp.jwt(client_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'worker-identity' AND name = path_own;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'Client SELECT identity object denied',
      v_seen = 0, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'Client SELECT identity object denied',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 10 Worker approve denied
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.approve_worker_identity(worker_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'Worker approve_worker_identity 42501', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'Worker approve_worker_identity 42501',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 11 reject leaves is_verified false
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    SELECT status, rejection_reason INTO v_status, v_reason
    FROM public.reject_worker_identity(worker_own, 'photo unreadable');
    PERFORM pg_temp.clear_jwt();
    SELECT wp.is_verified, wp.verified_by
      INTO v_verified, v_verified_by
    FROM public.worker_profiles wp WHERE wp.user_id = worker_own;
    PERFORM pg_temp.pass(11, 'reject_worker_identity keeps is_verified false',
      v_status = 'rejected' AND v_reason = 'photo unreadable'
        AND v_verified IS DISTINCT FROM true AND v_verified_by IS NULL,
      coalesce(v_status, 'null') || ' verified=' || coalesce(v_verified::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'reject_worker_identity keeps is_verified false',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 12 rejected review target SM409
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    PERFORM public.get_worker_identity_for_review(worker_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'rejected identity review target SM409', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'rejected identity review target SM409',
      SQLSTATE = 'SM409', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 13 Worker can resubmit after reject
  INSERT INTO storage.objects (bucket_id, name)
  VALUES (
    'worker-identity',
    profile_own::text || '/dddddddd-dddd-4ddd-8ddd-dddddddddd01.png'
  );
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.submit_my_valid_id(
      'umid',
      profile_own::text || '/dddddddd-dddd-4ddd-8ddd-dddddddddd01.png'
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'Worker can resubmit after reject', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'Worker can resubmit after reject',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 14 approve wraps verify_worker
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    SELECT user_id, is_verified, verified_by
      INTO v_uid, v_verified, v_verified_by
    FROM public.approve_worker_identity(worker_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'approve_worker_identity sets is_verified via verify_worker',
      v_uid = worker_own AND v_verified IS TRUE AND v_verified_by = admin_user,
      coalesce(v_verified::text, 'null') || ' by ' || coalesce(v_verified_by::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'approve_worker_identity sets is_verified via verify_worker',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  SELECT d.status INTO v_status
  FROM private.worker_id_documents d
  WHERE d.user_id = worker_own AND d.status <> 'superseded'
  ORDER BY d.submitted_at DESC
  LIMIT 1;
  PERFORM pg_temp.pass(15, 'approved document status is approved',
    v_status = 'approved', coalesce(v_status, 'null'));

  -- 16 second approve SM409
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    PERFORM public.approve_worker_identity(worker_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(16, 'second approve_worker_identity SM409', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(16, 'second approve_worker_identity SM409',
      SQLSTATE = 'SM409', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 17 verify_worker itself is still SM409 once verified (sole writer remains)
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    PERFORM public.verify_worker(worker_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(17, 'direct verify_worker after approval SM409', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(17, 'direct verify_worker after approval SM409',
      SQLSTATE = 'SM409', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 18 Worker cannot self-verify
  BEGIN
    PERFORM pg_temp.jwt(worker_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.verify_worker(worker_own);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(18, 'Worker verify_worker 42501 preserved', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(18, 'Worker verify_worker 42501 preserved',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 19 admin SELECT after approval no longer pending
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'worker-identity'
      AND name = profile_own::text || '/dddddddd-dddd-4ddd-8ddd-dddddddddd01.png';
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(19, 'admin SELECT approved identity object denied',
      v_seen = 0, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(19, 'admin SELECT approved identity object denied',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 20 blank reject reason 22023 (use worker_other pending)
  INSERT INTO storage.objects (bucket_id, name)
  VALUES (
    'worker-identity',
    profile_other::text || '/eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01.jpg'
  );
  PERFORM pg_temp.jwt(worker_other);
  SET LOCAL ROLE authenticated;
  PERFORM public.submit_my_valid_id(
    'postal_id',
    profile_other::text || '/eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01.jpg'
  );
  PERFORM pg_temp.clear_jwt();
  BEGIN
    PERFORM pg_temp.jwt(admin_user);
    SET LOCAL ROLE authenticated;
    PERFORM public.reject_worker_identity(worker_other, '   ');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(20, 'blank reject reason 22023', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(20, 'blank reject reason 22023',
      SQLSTATE = '22023', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 21 matching fingerprints unchanged
  SELECT md5(pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(21, 'compute_job_matches fingerprint unchanged',
    v_hash = 'b9b686e6b0b9a87ee8618b5600b1ed62', v_hash);
  SELECT md5(pg_get_functiondef('public.match_workers_for_job(uuid)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(22, 'match_workers_for_job fingerprint unchanged',
    v_hash = '9239550ea9da726a3002bb3503d12f73', v_hash);
  SELECT md5(pg_get_functiondef('public.list_my_job_opportunities()'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(23, 'list_my_job_opportunities fingerprint unchanged',
    v_hash = 'a135ec4ddac213df3f3ef147f93e0fc9', v_hash);

  -- 22 grants
  PERFORM pg_temp.pass(24, 'anon EXECUTE approve_worker_identity revoked',
    NOT has_function_privilege('anon', 'public.approve_worker_identity(uuid)', 'EXECUTE'));
  PERFORM pg_temp.pass(25, 'authenticated EXECUTE approve_worker_identity',
    has_function_privilege('authenticated', 'public.approve_worker_identity(uuid)', 'EXECUTE'));
END;
$$;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM v3_db3_results WHERE NOT ok;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'V3-DB3 FAILED % case(s)', v_fail;
  END IF;
  RAISE NOTICE 'V3-DB3 % / % PASS',
    (SELECT count(*) FROM v3_db3_results WHERE ok),
    (SELECT count(*) FROM v3_db3_results);
END;
$$;

ABORT;
