-- W7 chat push local SQL verification. Disposable fixtures only. Run
-- against local Supabase after db reset. The script ROLLBACKs the outer
-- transaction so no fixture survives.

BEGIN;

CREATE TEMP TABLE w7cp_results (n int, name text, ok boolean, detail text);
GRANT INSERT ON w7cp_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO w7cp_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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

-- Runs p_sql as p_uid (authenticated) or as p_role; returns SQLSTATE.
CREATE OR REPLACE FUNCTION pg_temp.state(p_sql text, p_uid uuid DEFAULT NULL, p_role text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  IF p_uid IS NOT NULL THEN PERFORM pg_temp.jwt(p_uid); END IF;
  BEGIN
    IF p_role IS NOT NULL THEN EXECUTE format('SET LOCAL ROLE %I', p_role); END IF;
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE;
  END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.targets(p_message uuid)
RETURNS TABLE (message_id uuid, booking_id uuid, expo_push_token text)
LANGUAGE plpgsql AS $$
BEGIN
  SET LOCAL ROLE service_role;
  RETURN QUERY SELECT t.message_id, t.booking_id, t.expo_push_token
    FROM public.get_message_push_targets(p_message) AS t;
  RESET ROLE;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.pair(
  p_job uuid, p_booking uuid, p_client uuid, p_worker uuid, p_status text DEFAULT 'confirmed'
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.job_postings(id, client_id, title, description, address, barangay, city, scheduled_at, status, budget)
  VALUES (p_job, p_client, 'W7 chat push fixture', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros',
          now() + interval '1 day', 'matched', 500);
  INSERT INTO public.bookings(id, job_id, worker_id, client_id, status)
  VALUES (p_booking, p_job, p_worker, p_client, p_status);
END;
$$;

DO $$
DECLARE
  c1 uuid := '77777777-0000-4000-8000-000000000001';
  w1 uuid := '77777777-0000-4000-8000-000000000002';
  c2 uuid := '77777777-0000-4000-8000-000000000003';
  w2 uuid := '77777777-0000-4000-8000-000000000004';
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  SELECT '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
         crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
  FROM (VALUES (c1,'w7cp-client1@example.test'),(w1,'w7cp-worker1@example.test'),
               (c2,'w7cp-client2@example.test'),(w2,'w7cp-worker2@example.test')) AS u(id,email);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (c1,'w7cp-client1@example.test','W7 Client One','09170000001','client','Santa Ana','Pateros',true),
    (w1,'w7cp-worker1@example.test','W7 Worker One','09170000002','worker','Santa Ana','Pateros',true),
    (c2,'w7cp-client2@example.test','W7 Client Two','09170000003','client','Santa Ana','Pateros',true),
    (w2,'w7cp-worker2@example.test','W7 Worker Two','09170000004','worker','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified) VALUES
    ('77777777-0000-4000-8000-000000000012',w1,'fixture','none','available',true),
    ('77777777-0000-4000-8000-000000000014',w2,'fixture','none','available',true);

  -- Devices: both participants of booking A, an unrelated pair, and one inactive token.
  INSERT INTO private.user_devices(user_id, expo_push_token, platform, is_active) VALUES
    (c1, 'ExponentPushToken[w7-client1-a]', 'android', true),
    (c1, 'ExponentPushToken[w7-client1-old]', 'android', false),
    (w1, 'ExponentPushToken[w7-worker1-a]', 'android', true),
    (w1, 'ExponentPushToken[w7-worker1-b]', 'android', true),
    (c2, 'ExponentPushToken[w7-client2-a]', 'android', true),
    (w2, 'ExponentPushToken[w7-worker2-a]', 'android', true);

  PERFORM pg_temp.pair('77777777-1000-4000-8000-00000000000a','77777777-2000-4000-8000-00000000000a',c1,w1,'confirmed');
  PERFORM pg_temp.pair('77777777-1000-4000-8000-00000000000b','77777777-2000-4000-8000-00000000000b',c2,w2,'confirmed');
  PERFORM pg_temp.pair('77777777-1000-4000-8000-00000000000c','77777777-2000-4000-8000-00000000000c',c1,w1,'confirmed');
END;
$$;

DO $$
DECLARE
  c1 uuid := '77777777-0000-4000-8000-000000000001';
  w1 uuid := '77777777-0000-4000-8000-000000000002';
  c2 uuid := '77777777-0000-4000-8000-000000000003';
  booking_a uuid := '77777777-2000-4000-8000-00000000000a';
  booking_c uuid := '77777777-2000-4000-8000-00000000000c';
  m_wc uuid := '77777777-3000-4000-8000-000000000001';
  m_cw uuid := '77777777-3000-4000-8000-000000000002';
  m_terminal uuid := '77777777-3000-4000-8000-000000000003';
  m_inactive uuid := '77777777-3000-4000-8000-000000000004';
  s text;
  v_count int;
  v_notifications_before int;
  v_tokens text;
  v_def text;
BEGIN
  SELECT count(*) INTO v_notifications_before FROM public.notifications;

  -- Catalog shape.
  PERFORM pg_temp.pass(1, 'message dispatch trigger exists on public.messages',
    EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.messages'::regclass
            AND NOT tgisinternal AND tgname = 'w7_dispatch_message_inserted'
            AND tgtype & 1 = 1 AND tgtype & 4 = 4));  -- ROW, INSERT
  PERFORM pg_temp.pass(2, 'R5 message Broadcast trigger still exists',
    EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.messages'::regclass
            AND NOT tgisinternal AND tgname = 'r5_broadcast_message_inserted'));
  PERFORM pg_temp.pass(3, 'R5B notification dispatch trigger still exists',
    EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.notifications'::regclass
            AND NOT tgisinternal AND tgname = 'r5b_dispatch_notification_inserted'));
  SELECT count(*) INTO v_count FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';
  PERFORM pg_temp.pass(4, 'public table count unchanged at 13', v_count = 13, 'count=' || v_count);
  PERFORM pg_temp.pass(5, 'no new private table (user_devices reused)',
    (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'private' AND c.relkind = 'r' AND c.relname ILIKE '%message%') = 0);

  -- EXECUTE boundary.
  PERFORM pg_temp.pass(6, 'authenticated cannot execute target RPC',
    pg_temp.state(format('SELECT * FROM public.get_message_push_targets(%L)', m_wc), c1) = '42501');
  PERFORM pg_temp.pass(7, 'anon cannot execute target RPC',
    pg_temp.state(format('SELECT * FROM public.get_message_push_targets(%L)', m_wc), NULL, 'anon') = '42501');
  PERFORM pg_temp.pass(8, 'dispatch trigger function has no client/service EXECUTE',
    (SELECT count(*) FROM information_schema.routine_privileges
     WHERE routine_schema = 'private' AND routine_name = 'w7_dispatch_message_inserted'
       AND grantee IN ('anon','authenticated','service_role','PUBLIC')) = 0);
  PERFORM pg_temp.pass(9, 'target RPC EXECUTE is service_role only',
    (SELECT array_agg(grantee::text ORDER BY grantee) FROM information_schema.routine_privileges
     WHERE routine_schema = 'public' AND routine_name = 'get_message_push_targets'
       AND grantee IN ('anon','authenticated','service_role','PUBLIC')) = ARRAY['service_role']);

  -- Worker -> Client through the real RLS send path.
  s := pg_temp.state(format(
    'INSERT INTO public.messages(id, booking_id, sender_id, content) VALUES (%L, %L, %L, %L)',
    m_wc, booking_a, w1, 'W7 private body worker'), w1);
  PERFORM pg_temp.pass(10, 'Worker send under RLS succeeds with missing Vault config (fail-open)', s = '00000', s);
  SELECT string_agg(expo_push_token, ',' ORDER BY expo_push_token) INTO v_tokens FROM pg_temp.targets(m_wc);
  PERFORM pg_temp.pass(11, 'Worker->Client targets only the Client active token',
    v_tokens = 'ExponentPushToken[w7-client1-a]', coalesce(v_tokens, 'none'));
  PERFORM pg_temp.pass(12, 'Worker->Client never targets the sender',
    NOT EXISTS (SELECT 1 FROM pg_temp.targets(m_wc) t
                JOIN private.user_devices d ON d.expo_push_token = t.expo_push_token WHERE d.user_id = w1));
  PERFORM pg_temp.pass(13, 'target rows carry the message and booking ids only',
    (SELECT bool_and(t.message_id = m_wc AND t.booking_id = booking_a) FROM pg_temp.targets(m_wc) AS t));

  -- Client -> Worker.
  s := pg_temp.state(format(
    'INSERT INTO public.messages(id, booking_id, sender_id, content) VALUES (%L, %L, %L, %L)',
    m_cw, booking_a, c1, 'W7 private body client'), c1);
  PERFORM pg_temp.pass(14, 'Client send under RLS succeeds', s = '00000', s);
  SELECT string_agg(expo_push_token, ',' ORDER BY expo_push_token) INTO v_tokens FROM pg_temp.targets(m_cw);
  PERFORM pg_temp.pass(15, 'Client->Worker targets every active Worker token, no Client token',
    v_tokens = 'ExponentPushToken[w7-worker1-a],ExponentPushToken[w7-worker1-b]', coalesce(v_tokens, 'none'));

  -- Messaging boundary unchanged.
  s := pg_temp.state(format(
    'INSERT INTO public.messages(booking_id, sender_id, content) VALUES (%L, %L, %L)', booking_a, c2, 'intruder'), c2);
  PERFORM pg_temp.pass(16, 'non-participant still cannot send', s = '42501', s);
  s := pg_temp.state(format(
    'INSERT INTO public.messages(booking_id, sender_id, content) VALUES (%L, %L, %L)', booking_a, c1, 'spoof'), w1);
  PERFORM pg_temp.pass(17, 'sender spoofing still denied', s = '42501', s);

  -- Unrelated users never appear.
  PERFORM pg_temp.pass(18, 'unrelated booking participants never targeted',
    NOT EXISTS (SELECT 1 FROM pg_temp.targets(m_wc) t
                WHERE t.expo_push_token LIKE '%client2%' OR t.expo_push_token LIKE '%worker2%')
    AND NOT EXISTS (SELECT 1 FROM pg_temp.targets(m_cw) t
                WHERE t.expo_push_token LIKE '%client2%' OR t.expo_push_token LIKE '%worker2%'));

  -- Terminal booking: a stored message (postgres fixture) yields no target.
  INSERT INTO public.messages(id, booking_id, sender_id, content) VALUES (m_terminal, booking_c, w1, 'before cancel');
  UPDATE public.bookings SET status = 'cancelled' WHERE id = booking_c;
  PERFORM pg_temp.pass(19, 'message on a no-longer-confirmed booking has no target',
    (SELECT count(*) FROM pg_temp.targets(m_terminal)) = 0);
  s := pg_temp.state(format(
    'INSERT INTO public.messages(booking_id, sender_id, content) VALUES (%L, %L, %L)', booking_c, w1, 'after cancel'), w1);
  PERFORM pg_temp.pass(20, 'terminal booking send still denied', s = '42501', s);

  -- Inactive recipient account gets nothing.
  UPDATE public.bookings SET status = 'confirmed' WHERE id = booking_c;
  INSERT INTO public.messages(id, booking_id, sender_id, content) VALUES (m_inactive, booking_c, w1, 'to inactive');
  UPDATE public.users SET is_active = false WHERE id = c1;
  PERFORM pg_temp.pass(21, 'inactive recipient account has no target',
    (SELECT count(*) FROM pg_temp.targets(m_inactive)) = 0);
  UPDATE public.users SET is_active = true WHERE id = c1;

  -- Unknown and sender-not-participant message ids.
  PERFORM pg_temp.pass(22, 'unknown message id has no target',
    (SELECT count(*) FROM pg_temp.targets(gen_random_uuid())) = 0);

  -- No inbox record per chat message; message stored once.
  PERFORM pg_temp.pass(23, 'chat messages create no notifications rows',
    (SELECT count(*) FROM public.notifications) = v_notifications_before);
  PERFORM pg_temp.pass(24, 'each sent message is stored exactly once',
    (SELECT count(*) FROM public.messages WHERE id IN (m_wc, m_cw)) = 2);

  -- Trigger body: identifier-only payload, Vault-read endpoint, fail-open.
  v_def := pg_get_functiondef('private.w7_dispatch_message_inserted()'::regprocedure);
  PERFORM pg_temp.pass(25, 'dispatch payload is message_id only, no content',
    v_def LIKE '%jsonb_build_object(''message_id'', NEW.id)%' AND v_def NOT LIKE '%NEW.content%');
  PERFORM pg_temp.pass(26, 'dispatch reuses the R5B Vault endpoint and secret',
    v_def LIKE '%r5b_push_endpoint%' AND v_def LIKE '%r5b_push_webhook_secret%');
  PERFORM pg_temp.pass(27, 'dispatch is fail-open SECURITY DEFINER with empty search_path',
    v_def LIKE '%SECURITY DEFINER%' AND v_def LIKE '%search_path TO ''''%' AND v_def LIKE '%EXCEPTION WHEN OTHERS%');

  -- Target projection exposes no content/contact columns.
  PERFORM pg_temp.pass(28, 'target RPC returns exactly message_id, booking_id, expo_push_token',
    (SELECT string_agg(p.parameter_name, ',' ORDER BY p.ordinal_position)
     FROM information_schema.parameters p
     JOIN information_schema.routines r ON r.specific_name = p.specific_name
     WHERE r.routine_schema = 'public' AND r.routine_name = 'get_message_push_targets'
       AND p.parameter_mode = 'OUT') = 'message_id,booking_id,expo_push_token');
END;
$$;

SELECT n, name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail
FROM w7cp_results ORDER BY n;

DO $$
DECLARE v_fail int; v_total int;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_fail, v_total FROM w7cp_results;
  IF v_fail > 0 OR v_total <> 28 THEN
    RAISE EXCEPTION 'W7 chat push SQL tests failed: % of % (expected 28)', v_fail, v_total;
  END IF;
END;
$$;

ROLLBACK;
