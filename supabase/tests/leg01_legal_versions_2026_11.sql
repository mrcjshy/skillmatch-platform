-- LEG-01 local SQL verification: Terms and Privacy 2026-11-v1 transition window.
--
-- Seams:
--   current Terms and Privacy are 2026-11-v1
--   installed build pairs (2026-09-v1 / 2026-10-v1 and 2026-09-v1 / 2026-09-v1) still record
--   new build pair re-stamps both acknowledgements; same-version repeat keeps timestamps
--   unknown / blank / null versions 22023; missing users row 42501; get_my_consent round trip
--   helpers not executable by API roles; record_my_consent grants unchanged
--
-- Disposable fixtures only. ABORT so nothing survives.

BEGIN;

CREATE TEMP TABLE leg01_results (n int, name text, ok boolean, detail text);

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO leg01_results(n, name, ok, detail) VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN
    RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE
    RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.jwt(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
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

CREATE OR REPLACE FUNCTION pg_temp.mk_user(p_user_id uuid, p_email text, p_role text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', p_user_id, 'authenticated', 'authenticated',
    p_email, crypt('leg01-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()
  );
  INSERT INTO public.users (id, email, full_name, phone, role, barangay, city, is_active)
  VALUES (p_user_id, p_email, 'LEG01 Fixture', '09000000000', p_role, 'Santa Ana', 'Pateros', true);
END;
$$;

-- Records as p_uid and returns the stored row; raises on error.
CREATE OR REPLACE FUNCTION pg_temp.rec(p_uid uuid, p_terms text, p_privacy text,
  OUT terms text, OUT privacy text, OUT terms_at timestamptz, OUT privacy_at timestamptz)
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  SELECT c.terms_version, c.privacy_version, c.terms_accepted_at, c.privacy_acknowledged_at
    INTO terms, privacy, terms_at, privacy_at
  FROM public.record_my_consent(p_terms, p_privacy) AS c;
  PERFORM pg_temp.clear_jwt();
END;
$$;

-- SQLSTATE of a record attempt, or 'ok'.
CREATE OR REPLACE FUNCTION pg_temp.rec_state(p_uid uuid, p_terms text, p_privacy text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_temp.rec(p_uid, p_terms, p_privacy);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RETURN SQLSTATE;
END;
$$;

DO $$
DECLARE
  u_old   uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';
  u_new   uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02';
  a record;
  b record;
  c record;
BEGIN
  PERFORM pg_temp.mk_user(u_old, 'leg01-old@example.test', 'client');
  PERFORM pg_temp.mk_user(u_new, 'leg01-new@example.test', 'worker');

  PERFORM pg_temp.pass(1, 'current terms is 2026-11-v1',
    private.current_legal_terms_version() = '2026-11-v1', private.current_legal_terms_version());
  PERFORM pg_temp.pass(2, 'current privacy is 2026-11-v1',
    private.current_legal_privacy_version() = '2026-11-v1', private.current_legal_privacy_version());

  -- installed build (RC3) keeps working
  a := pg_temp.rec(u_old, '2026-09-v1', '2026-10-v1');
  PERFORM pg_temp.pass(3, 'installed build pair (2026-09-v1, 2026-10-v1) still records',
    a.terms = '2026-09-v1' AND a.privacy = '2026-10-v1', a.terms || '/' || a.privacy);

  -- same user moves to the new build: both acknowledgements re-stamped
  PERFORM pg_sleep(0.05);
  b := pg_temp.rec(u_old, '2026-11-v1', '2026-11-v1');
  PERFORM pg_temp.pass(4, 'new build pair records 2026-11-v1 for both',
    b.terms = '2026-11-v1' AND b.privacy = '2026-11-v1', b.terms || '/' || b.privacy);
  PERFORM pg_temp.pass(5, 'terms acceptance re-stamped', b.terms_at > a.terms_at,
    a.terms_at::text || ' -> ' || b.terms_at::text);
  PERFORM pg_temp.pass(6, 'privacy acknowledgement re-stamped', b.privacy_at > a.privacy_at,
    a.privacy_at::text || ' -> ' || b.privacy_at::text);

  -- repeat is idempotent
  PERFORM pg_sleep(0.05);
  c := pg_temp.rec(u_old, '2026-11-v1', '2026-11-v1');
  PERFORM pg_temp.pass(7, 'same-version repeat keeps timestamps',
    c.privacy_at = b.privacy_at AND c.terms_at = b.terms_at, c.terms_at::text);

  -- a fresh user on the new build
  a := pg_temp.rec(u_new, '2026-11-v1', '2026-11-v1');
  PERFORM pg_temp.pass(8, 'fresh new-build consent records 2026-11-v1',
    a.terms = '2026-11-v1' AND a.privacy = '2026-11-v1', a.terms || '/' || a.privacy);

  -- the oldest installed pair is still accepted during the window
  PERFORM pg_temp.pass(9, 'oldest pair (2026-09-v1, 2026-09-v1) still accepted',
    pg_temp.rec_state(u_new, '2026-09-v1', '2026-09-v1') = 'ok');
  PERFORM pg_temp.rec(u_new, '2026-11-v1', '2026-11-v1');

  -- rejected versions
  PERFORM pg_temp.pass(10, 'unknown terms version 22023',
    pg_temp.rec_state(u_new, '2026-12-v1', '2026-11-v1') = '22023');
  PERFORM pg_temp.pass(11, 'terms 2026-10-v1 was never a terms version 22023',
    pg_temp.rec_state(u_new, '2026-10-v1', '2026-11-v1') = '22023');
  PERFORM pg_temp.pass(12, 'unknown privacy version 22023',
    pg_temp.rec_state(u_new, '2026-11-v1', '2026-08-v1') = '22023');
  PERFORM pg_temp.pass(13, 'blank and null versions 22023',
    pg_temp.rec_state(u_new, '  ', '2026-11-v1') = '22023'
    AND pg_temp.rec_state(u_new, '2026-11-v1', NULL) = '22023');
  PERFORM pg_temp.pass(14, 'rejected calls left the stored row unchanged',
    (SELECT terms_version || '/' || privacy_version FROM private.user_consents WHERE user_id = u_new) = '2026-11-v1/2026-11-v1');
  PERFORM pg_temp.pass(15, 'caller without a users row 42501',
    pg_temp.rec_state('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee99', '2026-11-v1', '2026-11-v1') = '42501');

  -- get_my_consent returns the stored pair
  PERFORM pg_temp.jwt(u_new);
  SET LOCAL ROLE authenticated;
  SELECT g.terms_version, g.privacy_version INTO a FROM public.get_my_consent() AS g;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(16, 'get_my_consent returns the 2026-11-v1 pair',
    a.terms_version = '2026-11-v1' AND a.privacy_version = '2026-11-v1');

  -- grants and function properties
  PERFORM pg_temp.pass(17, 'version helpers not executable by API roles',
    NOT has_function_privilege('anon', 'private.is_accepted_legal_terms_version(text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.is_accepted_legal_terms_version(text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'private.is_accepted_legal_terms_version(text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.is_accepted_legal_privacy_version(text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.current_legal_terms_version()', 'EXECUTE'));
  PERFORM pg_temp.pass(18, 'record_my_consent: authenticated only',
    has_function_privilege('authenticated', 'public.record_my_consent(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.record_my_consent(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.record_my_consent(text,text)', 'EXECUTE'));
  PERFORM pg_temp.pass(19, 'record_my_consent SECURITY DEFINER with empty search_path',
    EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.record_my_consent(text,text)'::regprocedure
      AND prosecdef AND proconfig = ARRAY['search_path=""']));
  PERFORM pg_temp.pass(20, 'user_consents columns unchanged',
    (SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns
      WHERE table_schema = 'private' AND table_name = 'user_consents')
    = 'user_id,terms_version,terms_accepted_at,privacy_version,privacy_acknowledged_at');
END;
$$;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM leg01_results WHERE NOT ok;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'LEG-01 FAILED % case(s)', v_fail;
  END IF;
  RAISE NOTICE 'LEG-01 % / % PASS',
    (SELECT count(*) FROM leg01_results WHERE ok), (SELECT count(*) FROM leg01_results);
END;
$$;

ABORT;
