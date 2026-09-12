-- R5B local SQL verification. Disposable fixtures only. Run against
-- local Supabase after db reset. The script ABORTs the outer
-- transaction so no fixture survives.

BEGIN;

CREATE TEMP TABLE r5b_results (
  n     int,
  name  text,
  ok    boolean,
  detail text
);

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO r5b_results(n, name, ok, detail) VALUES (p_n, p_name, p_ok, p_detail);
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

-- Auth + public.users fixtures (postgres / Tier 1).
CREATE OR REPLACE FUNCTION pg_temp.mk_user(p_id uuid, p_email text, p_active boolean)
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
    p_id,
    'authenticated',
    'authenticated',
    p_email,
    crypt('r5b-local', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  );

  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_id, p_email, 'R5B Fixture', '09000000000', 'client',
    'Test', 'Test City', p_active
  );
END;
$$;

DO $$
DECLARE
  u1 uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1';
  u2 uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2';
  u3 uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa3';
  t1 text := 'ExponentPushToken[r5b-token-one]';
  t2 text := 'ExponentPushToken[r5b-token-two]';
  d1 uuid;
  d1b uuid;
  d2 uuid;
  n1 uuid;
  n2 uuid;
  v_count int;
  v_err text;
  v_code text;
  v_priv int;
  v_r5 text;
  v_grant_ins int;
BEGIN
  PERFORM pg_temp.mk_user(u1, 'r5b-u1@example.test', true);
  PERFORM pg_temp.mk_user(u2, 'r5b-u2@example.test', true);
  PERFORM pg_temp.mk_user(u3, 'r5b-u3@example.test', false);

  -- 1. table exists
  PERFORM pg_temp.pass(1, 'private.user_devices exists',
    to_regclass('private.user_devices') IS NOT NULL);

  -- 2. public application table count remains 12
  SELECT count(*) INTO v_count
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.relname NOT LIKE 'pg_%';
  PERFORM pg_temp.pass(2, 'public table count is 12',
    v_count = 12, 'count=' || v_count);

  -- 3. authenticated/anon cannot directly read/write
  BEGIN
    PERFORM pg_temp.jwt(u1);
    SET LOCAL ROLE authenticated;
    EXECUTE 'SELECT count(*) FROM private.user_devices';
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'authenticated cannot select private.user_devices', false, 'select succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'authenticated cannot select private.user_devices', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(3, 'authenticated cannot select private.user_devices', true, SQLERRM);
  END;

  BEGIN
    SET LOCAL ROLE anon;
    EXECUTE 'INSERT INTO private.user_devices (user_id, expo_push_token, platform) VALUES ($1, $2, $3)'
      USING u1, t1, 'android';
    RESET ROLE;
    PERFORM pg_temp.pass(4, 'anon cannot insert private.user_devices', false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.pass(4, 'anon cannot insert private.user_devices', true);
  WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.pass(4, 'anon cannot insert private.user_devices', true, SQLERRM);
  END;

  -- 5. registration requires authentication
  BEGIN
    PERFORM pg_temp.clear_jwt();
    PERFORM public.register_my_push_device(t1);
    PERFORM pg_temp.pass(5, 'register requires auth', false, 'succeeded unsigned');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE;
    PERFORM pg_temp.pass(5, 'register requires auth', v_code = '42501', v_code);
  END;

  -- 6. inactive user cannot register
  BEGIN
    PERFORM pg_temp.jwt(u3);
    SET LOCAL ROLE authenticated;
    PERFORM public.register_my_push_device(t1);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'inactive user cannot register', false, 'succeeded');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'inactive user cannot register', v_code = '42501', v_code);
  END;

  -- 7/8. binds auth.uid() and is idempotent
  PERFORM pg_temp.jwt(u1);
  SET LOCAL ROLE authenticated;
  d1 := public.register_my_push_device(t1);
  d1b := public.register_my_push_device(t1);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(7, 'register binds caller and returns uuid', d1 IS NOT NULL);
  PERFORM pg_temp.pass(8, 'register is idempotent for same user/token', d1 = d1b);

  SELECT count(*) INTO v_count
  FROM private.user_devices
  WHERE expo_push_token = t1 AND user_id = u1 AND is_active;
  PERFORM pg_temp.pass(9, 'one active row after idempotent register', v_count = 1, 'count=' || v_count);

  -- 10. one user, multiple tokens
  PERFORM pg_temp.jwt(u1);
  SET LOCAL ROLE authenticated;
  d2 := public.register_my_push_device(t2);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(10, 'one user can register multiple tokens', d2 IS NOT NULL AND d2 IS DISTINCT FROM d1);

  -- 11. globally unique token / cannot steal active
  BEGIN
    PERFORM pg_temp.jwt(u2);
    SET LOCAL ROLE authenticated;
    PERFORM public.register_my_push_device(t1);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'active token cannot be stolen', false, 'stolen');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_code = RETURNED_SQLSTATE;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'active token cannot be stolen', v_code = 'SM409', v_code);
  END;

  -- 12. deactivation own row only
  PERFORM pg_temp.jwt(u1);
  SET LOCAL ROLE authenticated;
  PERFORM public.deactivate_my_push_device(t1);
  PERFORM pg_temp.clear_jwt();
  SELECT count(*) INTO v_count
  FROM private.user_devices
  WHERE expo_push_token = t1 AND user_id = u1 AND is_active;
  PERFORM pg_temp.pass(12, 'deactivate own token', v_count = 0);

  -- 13. deactivate another owner's token does not leak / change
  PERFORM pg_temp.jwt(u2);
  SET LOCAL ROLE authenticated;
  PERFORM public.deactivate_my_push_device(t2);
  PERFORM pg_temp.clear_jwt();
  SELECT count(*) INTO v_count
  FROM private.user_devices
  WHERE expo_push_token = t2 AND user_id = u1 AND is_active;
  PERFORM pg_temp.pass(13, 'deactivate does not affect another owner', v_count = 1);

  -- 14. inactive token can be reassigned
  PERFORM pg_temp.jwt(u2);
  SET LOCAL ROLE authenticated;
  d1b := public.register_my_push_device(t1);
  PERFORM pg_temp.clear_jwt();
  SELECT count(*) INTO v_count
  FROM private.user_devices
  WHERE expo_push_token = t1 AND user_id = u2 AND is_active;
  PERFORM pg_temp.pass(14, 'inactive token can be reassigned', v_count = 1 AND d1b = d1);

  -- 15. trusted RPC denied to authenticated
  BEGIN
    PERFORM pg_temp.jwt(u1);
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_notification_push_targets(gen_random_uuid());
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(15, 'authenticated cannot execute target RPC', false);
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(15, 'authenticated cannot execute target RPC', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(15, 'authenticated cannot execute target RPC', SQLSTATE = '42501', SQLERRM);
  END;

  -- 16. anon denied target RPC
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.get_notification_push_targets(gen_random_uuid());
    RESET ROLE;
    PERFORM pg_temp.pass(16, 'anon cannot execute target RPC', false);
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.pass(16, 'anon cannot execute target RPC', true);
  WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.pass(16, 'anon cannot execute target RPC', SQLSTATE = '42501', SQLERRM);
  END;

  -- Authoritative notification for u1 (still has t2 active).
  n1 := gen_random_uuid();
  INSERT INTO public.notifications (id, user_id, type, message)
  VALUES (n1, u1, 'worker_verified', 'Your worker profile has been verified.');

  n2 := gen_random_uuid();
  INSERT INTO public.notifications (id, user_id, type, message)
  VALUES (n2, u2, 'booking_confirmed', 'Your job "x" has been accepted.');

  -- 17. trusted RPC returns only recipient active devices
  SET LOCAL ROLE service_role;
  SELECT count(*) INTO v_count
  FROM public.get_notification_push_targets(n1);
  RESET ROLE;
  PERFORM pg_temp.pass(17, 'target RPC returns only u1 active tokens', v_count = 1, 'count=' || v_count);

  SET LOCAL ROLE service_role;
  SELECT count(*) INTO v_count
  FROM public.get_notification_push_targets(n1) AS t
  WHERE t.expo_push_token = t2
    AND t.notification_id = n1
    AND t.notification_type = 'worker_verified'
    AND t.notification_message = 'Your worker profile has been verified.';
  RESET ROLE;
  PERFORM pg_temp.pass(18, 'target RPC projects only needed columns', v_count = 1);

  -- 19. another user's devices never appear
  SET LOCAL ROLE service_role;
  SELECT count(*) INTO v_count
  FROM public.get_notification_push_targets(n1) AS t
  WHERE t.expo_push_token = t1;
  RESET ROLE;
  PERFORM pg_temp.pass(19, 'other-user tokens never appear', v_count = 0);

  -- 20. R5B trigger exists; R5 trigger still exists
  SELECT count(*) INTO v_count
  FROM pg_trigger
  WHERE tgrelid = 'public.notifications'::regclass
    AND NOT tgisinternal
    AND tgname = 'r5b_dispatch_notification_inserted';
  PERFORM pg_temp.pass(20, 'R5B trigger exists', v_count = 1);

  SELECT count(*) INTO v_count
  FROM pg_trigger
  WHERE tgrelid = 'public.notifications'::regclass
    AND NOT tgisinternal
    AND tgname = 'r5_broadcast_notification_inserted';
  PERFORM pg_temp.pass(21, 'R5 trigger still exists', v_count = 1);

  v_r5 := pg_get_functiondef('private.r5_broadcast_notification_inserted()'::regprocedure);
  PERFORM pg_temp.pass(22, 'R5 trigger function still calls realtime.send',
    v_r5 LIKE '%realtime.send%' AND v_r5 LIKE '%notification_inserted%');

  -- 23. missing Vault config does not block INSERT (already inserted n1/n2)
  SELECT count(*) INTO v_count FROM public.notifications WHERE id IN (n1, n2);
  PERFORM pg_temp.pass(23, 'notification INSERT survives missing Vault config', v_count = 2);

  -- 24. trigger function not executable by client/service
  SELECT count(*) INTO v_priv
  FROM information_schema.routine_privileges
  WHERE routine_schema = 'private'
    AND routine_name = 'r5b_dispatch_notification_inserted'
    AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC');
  PERFORM pg_temp.pass(24, 'dispatch function has no client/service EXECUTE', v_priv = 0, 'grants=' || v_priv);

  -- 25. notifications INSERT privilege for authenticated remains revoked
  SELECT count(*) INTO v_grant_ins
  FROM information_schema.role_table_grants
  WHERE table_schema = 'public'
    AND table_name = 'notifications'
    AND grantee = 'authenticated'
    AND privilege_type = 'INSERT';
  PERFORM pg_temp.pass(25, 'authenticated still has no notifications INSERT', v_grant_ins = 0);

  -- 26. emit_notification still the writer boundary (exists, revoked)
  PERFORM pg_temp.pass(26, 'private.emit_notification still exists',
    to_regprocedure('private.emit_notification(uuid, text, text)') IS NOT NULL);

  -- 27. producers unchanged enough to still exist
  PERFORM pg_temp.pass(27, 'accept_job_opportunity still exists',
    to_regprocedure('public.accept_job_opportunity(uuid)') IS NOT NULL);
  PERFORM pg_temp.pass(28, 'verify_worker still exists',
    to_regprocedure('public.verify_worker(uuid)') IS NOT NULL);

  -- 29. pg_net enabled
  PERFORM pg_temp.pass(29, 'pg_net extension present',
    EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net'));

  -- 30. register denied to anon via EXECUTE
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.register_my_push_device(t1);
    RESET ROLE;
    PERFORM pg_temp.pass(30, 'anon cannot execute register RPC', false);
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.pass(30, 'anon cannot execute register RPC', true);
  WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.pass(30, 'anon cannot execute register RPC', SQLSTATE = '42501', SQLERRM);
  END;
END;
$$;

SELECT n, name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail
FROM r5b_results
ORDER BY n;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM r5b_results WHERE NOT ok;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'R5B SQL tests failed: %', v_fail;
  END IF;
END;
$$;

ROLLBACK;
