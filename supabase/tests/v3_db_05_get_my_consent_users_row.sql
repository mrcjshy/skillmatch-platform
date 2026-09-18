-- V3-DB5 local SQL verification: get_my_consent requires public.users.
--
-- Seams:
--   unsigned / no auth.uid() is 42501
--   authenticated missing public.users is 42501
--   public.users exists and no consent is empty
--   current consent is the exact own row
--   EXECUTE remains authenticated-only (no PUBLIC / anon)
--
-- Does not rewrite DB1. Disposable fixtures only. ABORT so nothing survives.

BEGIN;

CREATE TEMP TABLE v3_db5_results (
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
  INSERT INTO v3_db5_results(n, name, ok, detail)
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

DO $$
DECLARE
  user_own   uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa51';
  auth_only  uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa53';
  v_count    int;
  v_uid      uuid;
  v_terms    text;
  v_privacy  text;
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    user_own, 'authenticated', 'authenticated', 'v3db5-own@example.test',
    crypt('v3-db5-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  ), (
    '00000000-0000-0000-0000-000000000000',
    auth_only, 'authenticated', 'authenticated', 'v3db5-authonly@example.test',
    crypt('v3-db5-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );

  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    user_own, 'v3db5-own@example.test', 'V3 DB5 Fixture', '09000000000',
    'worker', 'Santa Ana', 'Pateros', true
  );

  -- 1 unsigned / no auth.uid()
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('role', 'anon', true);
    PERFORM public.get_my_consent();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(1, 'unsigned get_my_consent denied', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(1, 'unsigned get_my_consent denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 2 authenticated missing public.users
  BEGIN
    PERFORM pg_temp.jwt(auth_only);
    SET LOCAL ROLE authenticated;
    PERFORM public.get_my_consent();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(2, 'auth-only get_my_consent without users row denied',
      false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(2, 'auth-only get_my_consent without users row denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 3 public.users exists, no consent
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count FROM public.get_my_consent();
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'users row without consent returns empty',
      v_count = 0, v_count::text);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'users row without consent returns empty',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 4 current consent is the exact own row
  BEGIN
    PERFORM pg_temp.jwt(user_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.record_my_consent('2026-09-v1', '2026-09-v1');
    SELECT c.user_id, c.terms_version, c.privacy_version
      INTO v_uid, v_terms, v_privacy
    FROM public.get_my_consent() AS c;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(4, 'own get_my_consent returns recorded row',
      v_uid = user_own AND v_terms = '2026-09-v1' AND v_privacy = '2026-09-v1',
      coalesce(v_uid::text, 'null') || ' ' || coalesce(v_terms, ''));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(4, 'own get_my_consent returns recorded row',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 5-10 ACLs remain authenticated-only (DB1 contract: no PUBLIC / anon / service_role EXECUTE)
  PERFORM pg_temp.pass(5, 'authenticated EXECUTE get_my_consent',
    has_function_privilege('authenticated', 'public.get_my_consent()', 'EXECUTE'));
  PERFORM pg_temp.pass(6, 'anon EXECUTE get_my_consent revoked',
    NOT has_function_privilege('anon', 'public.get_my_consent()', 'EXECUTE'));
  PERFORM pg_temp.pass(7, 'service_role EXECUTE get_my_consent revoked',
    NOT has_function_privilege('service_role', 'public.get_my_consent()', 'EXECUTE'));
  PERFORM pg_temp.pass(8, 'PUBLIC EXECUTE get_my_consent revoked',
    NOT EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      CROSS JOIN aclexplode(COALESCE(p.proacl, acldefault('f'::"char", p.proowner))) a
      WHERE n.nspname = 'public'
        AND p.proname = 'get_my_consent'
        AND pg_get_function_identity_arguments(p.oid) = ''
        AND a.grantee = 0
        AND a.privilege_type = 'EXECUTE'
    ));
  PERFORM pg_temp.pass(9, 'authenticated EXECUTE record_my_consent',
    has_function_privilege('authenticated', 'public.record_my_consent(text,text)', 'EXECUTE'));
  PERFORM pg_temp.pass(10, 'anon EXECUTE record_my_consent revoked',
    NOT has_function_privilege('anon', 'public.record_my_consent(text,text)', 'EXECUTE'));
  PERFORM pg_temp.pass(11, 'PUBLIC EXECUTE record_my_consent revoked',
    NOT EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      CROSS JOIN aclexplode(COALESCE(p.proacl, acldefault('f'::"char", p.proowner))) a
      WHERE n.nspname = 'public'
        AND p.proname = 'record_my_consent'
        AND pg_get_function_identity_arguments(p.oid) = 'text, text'
        AND a.grantee = 0
        AND a.privilege_type = 'EXECUTE'
    ));
END;
$$;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM v3_db5_results WHERE NOT ok;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'V3-DB5 FAILED % case(s)', v_fail;
  END IF;
  RAISE NOTICE 'V3-DB5 % / % PASS',
    (SELECT count(*) FROM v3_db5_results WHERE ok),
    (SELECT count(*) FROM v3_db5_results);
END;
$$;

ABORT;
