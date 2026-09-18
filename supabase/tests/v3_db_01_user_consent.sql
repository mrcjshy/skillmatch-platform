-- V3-DB1 local SQL verification: private.user_consents own-user RPC.
--
-- Seams:
--   own consent success
--   version/timestamp persistence
--   same-version idempotent timestamps
--   other-user denial (no cross-row write/read)
--   anon denial
--   invalid version 22023
--   missing users row 42501 (record_my_consent and get_my_consent)
--   direct table ACL
--
-- Disposable fixtures only. ABORT so nothing survives.

BEGIN;

CREATE TEMP TABLE v3_db1_results (
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
  INSERT INTO v3_db1_results(n, name, ok, detail)
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
    crypt('v3-db1-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );
  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'V3 DB1 Fixture', '09000000000', p_role,
    'Santa Ana', 'Pateros', true
  );
END;
$$;

DO $$
DECLARE
  user_own     uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  user_other   uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  auth_only    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa03';
  v_terms      text;
  v_privacy    text;
  v_at1        timestamptz;
  v_at2        timestamptz;
  v_count      int;
  v_uid        uuid;
BEGIN
  PERFORM pg_temp.mk_user(user_own, 'v3db1-own@example.test', 'worker');
  PERFORM pg_temp.mk_user(user_other, 'v3db1-other@example.test', 'client');

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    auth_only, 'authenticated', 'authenticated', 'v3db1-authonly@example.test',
    crypt('v3-db1-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );

  -- 1 current version helpers
  PERFORM pg_temp.pass(1, 'locked terms version is 2026-09-v1',
    private.current_legal_terms_version() = '2026-09-v1',
    private.current_legal_terms_version());
  PERFORM pg_temp.pass(2, 'locked privacy version is 2026-09-v1',
    private.current_legal_privacy_version() = '2026-09-v1',
    private.current_legal_privacy_version());

  -- 3 anon record denied
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('role', 'anon', true);
    PERFORM public.record_my_consent('2026-09-v1', '2026-09-v1');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'anon record_my_consent denied', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'anon record_my_consent denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 4 anon get denied
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('role', 'anon', true);
    PERFORM public.get_my_consent();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(4, 'anon get_my_consent denied', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(4, 'anon get_my_consent denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 5 missing public.users row
  BEGIN
    PERFORM pg_temp.jwt(auth_only);
    SET LOCAL ROLE authenticated;
    PERFORM public.record_my_consent('2026-09-v1', '2026-09-v1');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(5, 'auth-only without users row denied', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(5, 'auth-only without users row denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 6 invalid version
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.record_my_consent('not-a-version', '2026-09-v1');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'wrong terms version rejected 22023', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'wrong terms version rejected 22023',
      SQLSTATE = '22023', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 7 own record success
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    SELECT c.user_id, c.terms_version, c.privacy_version, c.terms_accepted_at
      INTO v_uid, v_terms, v_privacy, v_at1
    FROM public.record_my_consent('2026-09-v1', '2026-09-v1') AS c;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'own record_my_consent persists versions',
      v_uid = user_own AND v_terms = '2026-09-v1' AND v_privacy = '2026-09-v1'
        AND v_at1 IS NOT NULL,
      coalesce(v_uid::text, 'null') || ' ' || coalesce(v_terms, ''));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'own record_my_consent persists versions',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 8 own get
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    SELECT c.terms_version, c.privacy_version, c.terms_accepted_at
      INTO v_terms, v_privacy, v_at1
    FROM public.get_my_consent() AS c;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'own get_my_consent returns recorded row',
      v_terms = '2026-09-v1' AND v_privacy = '2026-09-v1' AND v_at1 IS NOT NULL,
      coalesce(v_terms, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'own get_my_consent returns recorded row',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 9 idempotent same-version keeps timestamps
  PERFORM pg_sleep(0.05);
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    SELECT c.terms_accepted_at, c.privacy_acknowledged_at
      INTO v_at2, v_privacy
    FROM public.record_my_consent('2026-09-v1', '2026-09-v1') AS c;
    SELECT c.terms_accepted_at INTO v_at2
    FROM public.get_my_consent() AS c;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'same-version repeat keeps terms_accepted_at',
      v_at1 IS NOT NULL AND v_at2 = v_at1,
      coalesce(v_at1::text, 'null') || ' vs ' || coalesce(v_at2::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'same-version repeat keeps terms_accepted_at',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 10 other user cannot read owner row via get_my_consent
  BEGIN
    PERFORM pg_temp.jwt(user_other);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count FROM public.get_my_consent();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'other user get_my_consent is empty',
      v_count = 0, v_count::text);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'other user get_my_consent is empty',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 11 other user record creates own row only
  BEGIN
    PERFORM pg_temp.jwt(user_other);
    SET LOCAL ROLE authenticated;
    PERFORM public.record_my_consent('2026-09-v1', '2026-09-v1');
    PERFORM pg_temp.clear_jwt();
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'other user can record own consent',
      false, SQLSTATE || ' ' || SQLERRM);
    v_count := -1;
  END;
  IF v_count IS DISTINCT FROM -1 THEN
    SELECT count(*) INTO v_count FROM private.user_consents;
    PERFORM pg_temp.pass(11, 'two own rows exist after both record',
      v_count = 2, v_count::text);
    PERFORM pg_temp.pass(12, 'owner row still belongs to owner',
      EXISTS (
        SELECT 1 FROM private.user_consents
        WHERE user_id = user_own AND terms_version = '2026-09-v1'
      ));
  END IF;

  -- 13 authenticated cannot SELECT the private table
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    PERFORM 1 FROM private.user_consents;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'authenticated SELECT private.user_consents denied',
      false, 'select succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'authenticated SELECT private.user_consents denied',
      true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'authenticated SELECT private.user_consents denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 14 authenticated cannot INSERT the private table
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    INSERT INTO private.user_consents (
      user_id, terms_version, terms_accepted_at, privacy_version, privacy_acknowledged_at
    ) VALUES (
      user_other, '2026-09-v1', now(), '2026-09-v1', now()
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'authenticated INSERT private.user_consents denied',
      false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'authenticated INSERT private.user_consents denied',
      true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'authenticated INSERT private.user_consents denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 15 EXECUTE grants
  PERFORM pg_temp.pass(15, 'authenticated EXECUTE record_my_consent',
    has_function_privilege('authenticated', 'public.record_my_consent(text,text)', 'EXECUTE'));
  PERFORM pg_temp.pass(16, 'anon EXECUTE record_my_consent revoked',
    NOT has_function_privilege('anon', 'public.record_my_consent(text,text)', 'EXECUTE'));
  PERFORM pg_temp.pass(17, 'anon EXECUTE get_my_consent revoked',
    NOT has_function_privilege('anon', 'public.get_my_consent()', 'EXECUTE'));

  -- 18 missing public.users row on get_my_consent
  BEGIN
    PERFORM pg_temp.jwt(auth_only);
    SET LOCAL ROLE authenticated;
    PERFORM public.get_my_consent();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(18, 'auth-only get_my_consent without users row denied',
      false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(18, 'auth-only get_my_consent without users row denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;
END;
$$;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM v3_db1_results WHERE NOT ok;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'V3-DB1 FAILED % case(s)', v_fail;
  END IF;
  RAISE NOTICE 'V3-DB1 % / % PASS',
    (SELECT count(*) FROM v3_db1_results WHERE ok),
    (SELECT count(*) FROM v3_db1_results);
END;
$$;

ABORT;
