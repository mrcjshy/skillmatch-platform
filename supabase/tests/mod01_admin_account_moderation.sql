-- MOD-01 local SQL verification: Administrator ban / reinstate. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE mod01_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON mod01_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO mod01_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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

-- Runs p_sql as p_uid (or as anon when p_anon) and returns its SQLSTATE.
CREATE OR REPLACE FUNCTION pg_temp.state(p_sql text, p_uid uuid DEFAULT NULL, p_anon boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  IF p_uid IS NOT NULL THEN PERFORM pg_temp.jwt(p_uid);
  ELSIF p_anon THEN PERFORM set_config('role', 'anon', true);
  END IF;
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE; END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

-- Runs admin_set_account_banned as p_uid and returns its row as jsonb.
CREATE OR REPLACE FUNCTION pg_temp.moderate(p_uid uuid, p_target uuid, p_banned boolean, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SELECT to_jsonb(r) INTO v FROM public.admin_set_account_banned(p_target, p_banned, p_reason) AS r;
  PERFORM pg_temp.clear_jwt();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.read_mod(p_uid uuid, p_target uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SELECT to_jsonb(r) INTO v FROM public.get_admin_account_moderation(p_target) AS r;
  PERFORM pg_temp.clear_jwt();
  RETURN v;
END;
$$;

DO $$
DECLARE
  admin_one uuid := '01010101-0000-4000-8000-000000000001';
  admin_off uuid := '01010101-0000-4000-8000-000000000002';
  client_one uuid := '01010101-0000-4000-8000-000000000003';
  worker_one uuid := '01010101-0000-4000-8000-000000000004';
  worker_two uuid := '01010101-0000-4000-8000-000000000005';
  u uuid;
  e text;
BEGIN
  FOREACH u IN ARRAY ARRAY[admin_one, admin_off, client_one, worker_one, worker_two] LOOP
    e := 'mod01-' || right(u::text, 2) || '@example.test';
    INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    VALUES ('00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated',e,crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  END LOOP;
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (admin_one,'mod01-01@example.test','MOD01 Admin','09190000001','administrator','Santa Ana','Pateros',true),
    (admin_off,'mod01-02@example.test','MOD01 Inactive Admin','09190000002','administrator','Santa Ana','Pateros',false),
    (client_one,'mod01-03@example.test','MOD01 Client','09190000003','client','Santa Ana','Pateros',true),
    (worker_one,'mod01-04@example.test','MOD01 Worker One','09190000004','worker','Santa Ana','Pateros',true),
    (worker_two,'mod01-05@example.test','MOD01 Worker Two','09190000005','worker','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified) VALUES
    ('01010101-1000-4000-8000-000000000004',worker_one,'fixture','none','available',true),
    ('01010101-1000-4000-8000-000000000005',worker_two,'fixture','none','available',true);
  -- Worker One reached three strikes through FT-05 (simulated as postgres).
  UPDATE public.worker_profiles SET strike_count = 3 WHERE user_id = worker_one;
  UPDATE public.users SET is_active = false WHERE id = worker_one;
  -- Worker Two is active with one strike.
  UPDATE public.worker_profiles SET strike_count = 1 WHERE user_id = worker_two;
END;
$$;

-- ---------- Authorization and input ----------
DO $$
DECLARE
  admin_one uuid := '01010101-0000-4000-8000-000000000001';
  admin_off uuid := '01010101-0000-4000-8000-000000000002';
  client_one uuid := '01010101-0000-4000-8000-000000000003';
  worker_two uuid := '01010101-0000-4000-8000-000000000005';
  s text;
BEGIN
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', client_one, 'x'), worker_two);
  PERFORM pg_temp.pass(1, 'Worker cannot ban: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', worker_two, 'x'), client_one);
  PERFORM pg_temp.pass(2, 'Client cannot ban: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', client_one, 'x'), admin_off);
  PERFORM pg_temp.pass(3, 'inactive Administrator cannot ban: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', client_one, 'x'), NULL, true);
  PERFORM pg_temp.pass(4, 'anon cannot execute: 42501', s = '42501', s);
  PERFORM pg_temp.pass(5, 'EXECUTE granted to authenticated only',
    has_function_privilege('authenticated', 'public.admin_set_account_banned(uuid,boolean,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_set_account_banned(uuid,boolean,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.admin_set_account_banned(uuid,boolean,text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.get_admin_account_moderation(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_admin_account_moderation(uuid)', 'EXECUTE'));

  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', client_one, '   '), admin_one);
  PERFORM pg_temp.pass(6, 'blank reason: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,NULL)', client_one), admin_one);
  PERFORM pg_temp.pass(7, 'NULL reason: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', client_one, repeat('a', 501)), admin_one);
  PERFORM pg_temp.pass(8, '501-character reason: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,NULL,%L)', client_one, 'x'), admin_one);
  PERFORM pg_temp.pass(9, 'NULL banned flag: 22023', s = '22023', s);

  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', admin_off, 'x'), admin_one);
  PERFORM pg_temp.pass(10, 'Administrator target: SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', admin_one, 'x'), admin_one);
  PERFORM pg_temp.pass(11, 'self target: SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.admin_set_account_banned(%L,true,%L)', gen_random_uuid(), 'x'), admin_one);
  PERFORM pg_temp.pass(12, 'missing target: SM409', s = 'SM409', s);

  PERFORM pg_temp.pass(13, 'denials wrote no event and no notification',
    NOT EXISTS (SELECT 1 FROM private.account_moderation_events)
    AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE type IN ('account_suspended', 'account_reinstated')));

  s := pg_temp.state('SELECT count(*) FROM private.account_moderation_events', admin_one);
  PERFORM pg_temp.pass(14, 'audit table is closed to direct reads, even for an Administrator', s = '42501', s);
  s := pg_temp.state(format('INSERT INTO private.account_moderation_events(user_id,action,reason) VALUES (%L,%L,%L)', client_one, 'ban', 'x'), admin_one);
  PERFORM pg_temp.pass(15, 'audit table is closed to direct writes', s = '42501', s);
END;
$$;

-- ---------- Ban and reinstate a Client ----------
DO $$
DECLARE
  admin_one uuid := '01010101-0000-4000-8000-000000000001';
  client_one uuid := '01010101-0000-4000-8000-000000000003';
  r jsonb;
BEGIN
  r := pg_temp.moderate(admin_one, client_one, true, '  Repeated abusive messages  ');
  PERFORM pg_temp.pass(16, 'ban returns changed inactive Client with no strikes',
    r->>'changed' = 'true' AND r->>'is_active' = 'false' AND r->'strike_count' = 'null'::jsonb AND (r->>'user_id')::uuid = client_one, r::text);
  PERFORM pg_temp.pass(17, 'ban sets users.is_active = false',
    (SELECT is_active FROM public.users WHERE id = client_one) = false);
  PERFORM pg_temp.pass(18, 'ban records one trimmed audit event by the Administrator',
    (SELECT count(*) FROM private.account_moderation_events WHERE user_id = client_one AND action = 'ban'
       AND reason = 'Repeated abusive messages' AND actor_id = admin_one AND strike_count_before IS NULL) = 1);
  PERFORM pg_temp.pass(19, 'ban emits one account_suspended notification carrying the reason',
    (SELECT count(*) FROM public.notifications WHERE user_id = client_one AND type = 'account_suspended'
       AND message LIKE '%Reason: Repeated abusive messages') = 1);

  r := pg_temp.moderate(admin_one, client_one, true, 'again');
  PERFORM pg_temp.pass(20, 'repeat ban is idempotent: changed = false, no new event or notification',
    r->>'changed' = 'false' AND r->>'is_active' = 'false'
    AND (SELECT count(*) FROM private.account_moderation_events WHERE user_id = client_one) = 1
    AND (SELECT count(*) FROM public.notifications WHERE user_id = client_one AND type = 'account_suspended') = 1, r::text);

  r := pg_temp.read_mod(admin_one, client_one);
  PERFORM pg_temp.pass(21, 'Administrator read shows the ban and its reason',
    r->>'is_active' = 'false' AND r->>'last_action' = 'ban' AND r->>'last_reason' = 'Repeated abusive messages'
    AND r->'strike_count' = 'null'::jsonb AND r->>'last_action_at' IS NOT NULL, r::text);

  r := pg_temp.moderate(admin_one, client_one, false, 'Appeal accepted');
  PERFORM pg_temp.pass(22, 'reinstate returns changed active Client',
    r->>'changed' = 'true' AND r->>'is_active' = 'true', r::text);
  PERFORM pg_temp.pass(23, 'reinstate records an event and one account_reinstated notification',
    (SELECT count(*) FROM private.account_moderation_events WHERE user_id = client_one AND action = 'reinstate' AND reason = 'Appeal accepted') = 1
    AND (SELECT count(*) FROM public.notifications WHERE user_id = client_one AND type = 'account_reinstated'
           AND message = 'An Administrator reinstated your account.') = 1);

  r := pg_temp.moderate(admin_one, client_one, false, 'again');
  PERFORM pg_temp.pass(24, 'reinstating an active account is idempotent',
    r->>'changed' = 'false'
    AND (SELECT count(*) FROM private.account_moderation_events WHERE user_id = client_one) = 2
    AND (SELECT count(*) FROM public.notifications WHERE user_id = client_one AND type = 'account_reinstated') = 1, r::text);

  r := pg_temp.read_mod(admin_one, client_one);
  PERFORM pg_temp.pass(25, 'Administrator read shows the latest action',
    r->>'is_active' = 'true' AND r->>'last_action' = 'reinstate' AND r->>'last_reason' = 'Appeal accepted', r::text);
END;
$$;

-- ---------- Workers and strikes ----------
DO $$
DECLARE
  admin_one uuid := '01010101-0000-4000-8000-000000000001';
  admin_off uuid := '01010101-0000-4000-8000-000000000002';
  worker_one uuid := '01010101-0000-4000-8000-000000000004';
  worker_two uuid := '01010101-0000-4000-8000-000000000005';
  r jsonb;
  s text;
BEGIN
  r := pg_temp.read_mod(admin_one, worker_one);
  PERFORM pg_temp.pass(26, 'Administrator read shows a 3-strike suspension with no moderation event',
    r->>'is_active' = 'false' AND r->>'strike_count' = '3' AND r->'last_action' = 'null'::jsonb, r::text);

  r := pg_temp.moderate(admin_one, worker_one, false, 'Worker completed retraining');
  PERFORM pg_temp.pass(27, 'reinstating a 3-strike Worker reactivates and resets strikes to 0',
    r->>'changed' = 'true' AND r->>'is_active' = 'true' AND r->>'strike_count' = '0'
    AND (SELECT strike_count FROM public.worker_profiles WHERE user_id = worker_one) = 0
    AND (SELECT is_active FROM public.users WHERE id = worker_one), r::text);
  PERFORM pg_temp.pass(28, 'Worker reinstatement event keeps strike_count_before = 3 and says strikes were reset',
    (SELECT count(*) FROM private.account_moderation_events WHERE user_id = worker_one AND action = 'reinstate' AND strike_count_before = 3) = 1
    AND (SELECT count(*) FROM public.notifications WHERE user_id = worker_one AND type = 'account_reinstated'
           AND message LIKE '%strikes were reset to 0.') = 1);

  r := pg_temp.moderate(admin_one, worker_two, false, 'not suspended');
  PERFORM pg_temp.pass(29, 'reinstating an active Worker changes nothing, strikes kept',
    r->>'changed' = 'false' AND r->>'strike_count' = '1'
    AND NOT EXISTS (SELECT 1 FROM private.account_moderation_events WHERE user_id = worker_two), r::text);

  r := pg_temp.moderate(admin_one, worker_two, true, 'Fraudulent listing');
  PERFORM pg_temp.pass(30, 'banning a Worker keeps their strikes and records strike_count_before',
    r->>'changed' = 'true' AND r->>'is_active' = 'false' AND r->>'strike_count' = '1'
    AND (SELECT strike_count_before FROM private.account_moderation_events WHERE user_id = worker_two AND action = 'ban') = 1, r::text);

  r := pg_temp.moderate(admin_one, worker_two, false, 'Cleared');
  PERFORM pg_temp.pass(31, 'reinstating a banned Worker also resets strikes to 0',
    r->>'changed' = 'true' AND r->>'is_active' = 'true' AND r->>'strike_count' = '0', r::text);

  s := pg_temp.state(format('SELECT * FROM public.get_admin_account_moderation(%L)', worker_one), worker_two);
  PERFORM pg_temp.pass(32, 'Worker cannot read moderation: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT * FROM public.get_admin_account_moderation(%L)', worker_one), admin_off);
  PERFORM pg_temp.pass(33, 'inactive Administrator cannot read moderation: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT * FROM public.get_admin_account_moderation(%L)', admin_off), admin_one);
  PERFORM pg_temp.pass(34, 'moderation read of an Administrator: SM409', s = 'SM409', s);
  s := pg_temp.state(format('SELECT * FROM public.get_admin_account_moderation(%L)', gen_random_uuid()), admin_one);
  PERFORM pg_temp.pass(35, 'moderation read of a missing account: SM409', s = 'SM409', s);

  UPDATE public.worker_profiles SET strike_count = 2 WHERE user_id = worker_two;
  s := pg_temp.state(format('UPDATE public.worker_profiles SET strike_count = 0 WHERE user_id = %L', worker_two), worker_two);
  PERFORM pg_temp.pass(36, 'Worker cannot clear their own strikes directly',
    s = '42501' AND (SELECT strike_count FROM public.worker_profiles WHERE user_id = worker_two) = 2, s);
  PERFORM pg_temp.pass(38, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
  PERFORM pg_temp.pass(37, 'account_reinstated is an allowed notification type',
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'notifications_type_check')) LIKE '%account_reinstated%');
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM mod01_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'MOD-01 failed % assertions', failed; END IF;
  RAISE NOTICE 'MOD-01: % assertions passed', (SELECT count(*) FROM mod01_results);
END;
$$;

ROLLBACK;
