-- RF-01 location pins — local SQL verification. Disposable fixtures only.
-- Run ONLY against an identified disposable local stack after
-- `npx supabase db reset --local`. The outer transaction ROLLBACKs.
-- Expected: every NOTICE line is PASS; the final row shows failed = 0.

BEGIN;

CREATE TEMP TABLE rf01_results (n int, name text, ok boolean, detail text);
GRANT INSERT ON rf01_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO rf01_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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
END;
$$;

-- Runs p_sql as p_uid; returns 'ERR:<sqlstate>' or the single text result.
CREATE OR REPLACE FUNCTION pg_temp.q(p_sql text, p_uid uuid)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  BEGIN
    EXECUTE p_sql INTO v;
  EXCEPTION WHEN OTHERS THEN v := 'ERR:' || SQLSTATE;
  END;
  PERFORM pg_temp.clear_jwt();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.pair(
  p_job uuid, p_booking uuid, p_client uuid, p_worker uuid, p_status text DEFAULT 'confirmed'
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.job_postings(id, client_id, title, description, address, barangay, city, scheduled_at, status, budget)
  VALUES (p_job, p_client, 'RF01 fixture', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros',
          now() + interval '1 day', 'matched', 500);
  INSERT INTO public.bookings(id, job_id, worker_id, client_id, status)
  VALUES (p_booking, p_job, p_worker, p_client, p_status);
END;
$$;

DO $$
DECLARE
  c1 uuid := '01010101-0000-4000-8000-000000000001';
  w1 uuid := '01010101-0000-4000-8000-000000000002';
  c2 uuid := '01010101-0000-4000-8000-000000000003';
  w2 uuid := '01010101-0000-4000-8000-000000000004';
  ad uuid := '01010101-0000-4000-8000-000000000005';
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  SELECT '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
         crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
  FROM (VALUES (c1,'rf01-client1@example.test'),(w1,'rf01-worker1@example.test'),
               (c2,'rf01-client2@example.test'),(w2,'rf01-worker2@example.test'),
               (ad,'rf01-admin@example.test')) AS u(id,email);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (c1,'rf01-client1@example.test','RF01 Client One','09170000101','client','Santa Ana','Pateros',true),
    (w1,'rf01-worker1@example.test','RF01 Worker One','09170000102','worker','Santa Ana','Pateros',true),
    (c2,'rf01-client2@example.test','RF01 Client Two','09170000103','client','Santa Ana','Pateros',true),
    (w2,'rf01-worker2@example.test','RF01 Worker Two','09170000104','worker','Santa Ana','Pateros',true),
    (ad,'rf01-admin@example.test','RF01 Admin','09170000105','administrator','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified) VALUES
    ('01010101-0000-4000-8000-000000000012',w1,'fixture','none','available',true),
    ('01010101-0000-4000-8000-000000000014',w2,'fixture','none','available',true);
  -- A: confirmed c1/w1.  B: confirmed c2/w2 (unrelated).  P: pending c1/w1.
  -- D: confirmed c1/w2 (deactivation target).
  PERFORM pg_temp.pair('01010101-1000-4000-8000-00000000000a','01010101-2000-4000-8000-00000000000a',c1,w1,'confirmed');
  PERFORM pg_temp.pair('01010101-1000-4000-8000-00000000000b','01010101-2000-4000-8000-00000000000b',c2,w2,'confirmed');
  PERFORM pg_temp.pair('01010101-1000-4000-8000-00000000000c','01010101-2000-4000-8000-00000000000c',c1,w1,'pending');
  PERFORM pg_temp.pair('01010101-1000-4000-8000-00000000000d','01010101-2000-4000-8000-00000000000d',c1,w2,'confirmed');
END;
$$;

DO $$
DECLARE
  c1 uuid := '01010101-0000-4000-8000-000000000001';
  w1 uuid := '01010101-0000-4000-8000-000000000002';
  c2 uuid := '01010101-0000-4000-8000-000000000003';
  w2 uuid := '01010101-0000-4000-8000-000000000004';
  ad uuid := '01010101-0000-4000-8000-000000000005';
  a  uuid := '01010101-2000-4000-8000-00000000000a';
  p  uuid := '01010101-2000-4000-8000-00000000000c';
  d  uuid := '01010101-2000-4000-8000-00000000000d';
  s_w1 text; s_w1b text; s_c1 text; r text; v_json jsonb; v_count int;
  pub text := 'SELECT public.publish_my_booking_location(%L,%L,%s,14.5995,121.0365,12,now())';
BEGIN
  -- 1 participant start returns a uuid
  s_w1 := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), w1);
  PERFORM pg_temp.pass(1, 'participant start returns share uuid', s_w1 ~ '^[0-9a-f-]{36}$', s_w1);

  -- 2-5 denied starts
  PERFORM pg_temp.pass(2, 'unrelated user start 42501',
    pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), c2) = 'ERR:42501');
  PERFORM pg_temp.pass(3, 'Administrator start 42501',
    pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), ad) = 'ERR:42501');
  -- RF-04: only the Worker may start, so the pending-status rule is exercised with the Worker.
  PERFORM pg_temp.pass(4, 'pending booking start 42501',
    pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', p), w1) = 'ERR:42501');
  -- authenticated role with no subject claim
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'authenticated', true);
  BEGIN
    PERFORM public.start_my_booking_location_share(a);
    r := 'ok';
  EXCEPTION WHEN OTHERS THEN r := SQLSTATE;
  END;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(5, 'no-subject start 42501', r = '42501', r);

  -- 6 valid publish, server-stamped received_at
  r := pg_temp.q(format(pub, a, s_w1, 1), w1);
  PERFORM pg_temp.pass(6, 'valid publish ok', r = 'ok', r);
  PERFORM pg_temp.pass(6, 'received_at stamped by server',
    (SELECT last_received_at = now() FROM private.booking_location_shares WHERE booking_id = a AND user_id = w1));

  -- 8 throttle (< 3 s after last accepted reading)
  r := pg_temp.q(format(pub, a, s_w1, 2), w1);
  PERFORM pg_temp.pass(8, 'second publish within 3 s throttled', r = 'throttled', r);

  -- 7 stale/equal seq (age the row past the throttle first)
  UPDATE private.booking_location_shares SET last_received_at = now() - interval '5 seconds'
  WHERE booking_id = a AND user_id = w1;
  r := pg_temp.q(format(pub, a, s_w1, 1), w1);
  PERFORM pg_temp.pass(7, 'equal seq stale_seq', r = 'stale_seq', r);

  -- 9-10 invalid readings raise 22023
  PERFORM pg_temp.pass(9, 'latitude out of range 22023',
    pg_temp.q(format('SELECT public.publish_my_booking_location(%L,%L,5,91,121,12,now())', a, s_w1), w1) = 'ERR:22023');
  PERFORM pg_temp.pass(9, 'negative accuracy 22023',
    pg_temp.q(format('SELECT public.publish_my_booking_location(%L,%L,5,14,121,-1,now())', a, s_w1), w1) = 'ERR:22023');
  PERFORM pg_temp.pass(10, 'captured_at 31 s in the future 22023',
    pg_temp.q(format('SELECT public.publish_my_booking_location(%L,%L,5,14,121,12,now() + interval ''31 seconds'')', a, s_w1), w1) = 'ERR:22023');
  PERFORM pg_temp.pass(10, 'captured_at older than 2 min 22023',
    pg_temp.q(format('SELECT public.publish_my_booking_location(%L,%L,5,14,121,12,now() - interval ''121 seconds'')', a, s_w1), w1) = 'ERR:22023');

  -- 11 restart on a second device: the old share is no longer current
  s_w1b := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), w1);
  r := pg_temp.q(format(pub, a, s_w1, 9), w1);
  PERFORM pg_temp.pass(11, 'old device publish not_current after restart', r = 'not_current', r);

  -- 12 a DELAYED stop from the old device must not delete the newer share
  r := pg_temp.q(format('SELECT public.stop_my_booking_location_share(%L,%L)', a, s_w1), w1);
  PERFORM pg_temp.pass(12, 'old-device stop returns not_current', r = 'not_current', r);
  PERFORM pg_temp.pass(12, 'newer share survives old-device stop',
    EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = a AND user_id = w1 AND share_id::text = s_w1b));

  -- 13 stop current deletes; a late publish cannot resurrect it
  r := pg_temp.q(format(pub, a, s_w1b, 1), w1);
  r := pg_temp.q(format('SELECT public.stop_my_booking_location_share(%L,%L)', a, s_w1b), w1);
  PERFORM pg_temp.pass(13, 'current stop returns stopped', r = 'stopped', r);
  r := pg_temp.q(format(pub, a, s_w1b, 2), w1);
  PERFORM pg_temp.pass(13, 'publish after stop not_current', r = 'not_current', r);
  PERFORM pg_temp.pass(13, 'no row after stop + late publish',
    NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = a AND user_id = w1));

  -- 14 stop all
  PERFORM pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), w1);
  r := pg_temp.q(format('SELECT public.stop_all_my_booking_location_shares(%L)::text', a), w1);
  PERFORM pg_temp.pass(14, 'stop_all deletes the caller row', r = '1', r);

  -- 15 read (RF-04 contract): the Client reads the Worker's position; the Client never
  -- shares; the Worker reads only its own share status; output never contains any share id
  s_w1 := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), w1);
  PERFORM pg_temp.q(format(pub, a, s_w1, 1), w1);
  s_c1 := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), c1);
  PERFORM pg_temp.pass(15, 'Client start 42501 (RF-04: Worker-only sharing)', s_c1 = 'ERR:42501', s_c1);
  r := pg_temp.q(format(pub, a, s_w1, 2), c1);
  PERFORM pg_temp.pass(15, 'Client publish 42501 (RF-04: old Client builds cannot publish)', r = 'ERR:42501', r);
  v_json := pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), c1)::jsonb;
  PERFORM pg_temp.pass(15, 'client sees worker counterpart',
    v_json->'counterpart'->>'role' = 'worker' AND (v_json->'counterpart'->>'latitude')::float8 = 14.5995, v_json::text);
  PERFORM pg_temp.pass(15, 'client my_share none', v_json->>'my_share' = 'none', v_json::text);
  PERFORM pg_temp.pass(15, 'lease is 60 s after server_now',
    (v_json->>'lease_expires_at')::timestamptz - (v_json->>'server_now')::timestamptz = interval '60 seconds');
  PERFORM pg_temp.pass(15, 'client read output contains no share uuid', position(s_w1 in v_json::text) = 0);
  v_json := pg_temp.q(format('SELECT public.get_booking_location_pins(%L,%L)::text', a, s_w1), w1)::jsonb;
  PERFORM pg_temp.pass(15, 'worker my_share yours_active with own id', v_json->>'my_share' = 'yours_active');
  PERFORM pg_temp.pass(15, 'worker counterpart always null (RF-04)', v_json->'counterpart' = 'null'::jsonb, v_json::text);
  PERFORM pg_temp.pass(15, 'worker read output contains no share uuid', position(s_w1 in v_json::text) = 0);
  v_json := pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), w1)::jsonb;
  PERFORM pg_temp.pass(15, 'worker my_share active_on_other_device without id', v_json->>'my_share' = 'active_on_other_device');

  -- 16 Worker pin idle > 10 min is not returned to the Client and is deleted on access
  UPDATE private.booking_location_shares SET last_received_at = now() - interval '11 minutes',
    captured_at = now() - interval '11 minutes'
  WHERE booking_id = a AND user_id = w1;
  v_json := pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), c1)::jsonb;
  PERFORM pg_temp.pass(16, 'expired counterpart not returned', v_json->'counterpart' = 'null'::jsonb, v_json::text);
  PERFORM pg_temp.pass(16, 'expired row deleted on access',
    NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = a AND user_id = w1));

  -- 17 session expiry on publish (Worker session that never published)
  s_w1 := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), w1);
  UPDATE private.booking_location_shares SET started_at = now() - interval '11 minutes'
  WHERE booking_id = a AND user_id = w1;
  r := pg_temp.q(format(pub, a, s_w1, 1), w1);
  PERFORM pg_temp.pass(17, 'publish after 10 min idle expired', r = 'expired', r);
  PERFORM pg_temp.pass(17, 'expired session row deleted',
    NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = a AND user_id = w1));

  -- 21 ids-only broadcast
  SELECT count(*) INTO v_count FROM realtime.messages m
  WHERE m.topic = 'booking:' || a::text || ':messages' AND m.event = 'location_pins_changed'
    AND m.private = true AND m.extension = 'broadcast';
  PERFORM pg_temp.pass(21, 'location_pins_changed broadcast emitted', v_count > 0, 'count=' || v_count);
  -- realtime.send adds its own message id to the application payload.
  PERFORM pg_temp.pass(21, 'broadcast contains only booking_id and the Realtime message id',
    NOT EXISTS (SELECT 1 FROM realtime.messages m
                WHERE m.event = 'location_pins_changed'
                  AND ((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(m.payload - 'id') AS k) IS DISTINCT FROM ARRAY['booking_id']
                    OR m.payload->>'id' IS DISTINCT FROM m.id::text)));

  -- 20 unrelated read 42501
  PERFORM pg_temp.pass(20, 'unrelated user read 42501',
    pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), c2) = 'ERR:42501');
  PERFORM pg_temp.pass(20, 'Administrator read 42501',
    pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), ad) = 'ERR:42501');

  -- 19 deactivation deletes the user rows (booking D: c1 + w2; only the Worker shares under RF-04)
  PERFORM pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', d), w2);
  PERFORM pg_temp.pass(19, 'fixture: Worker share exists before deactivation',
    EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = d AND user_id = w2));
  UPDATE public.users SET is_active = false WHERE id = w2;
  PERFORM pg_temp.pass(19, 'deactivation deletes that user''s rows',
    NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE user_id = w2));
  PERFORM pg_temp.pass(19, 'deactivated user cannot restart',
    pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', d), w2) = 'ERR:42501');
  UPDATE public.users SET is_active = true WHERE id = w2;

  -- 18 booking leaves confirmed: rows deleted, reads and writes denied
  s_w1 := pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', a), w1);
  PERFORM pg_temp.q(format(pub, a, s_w1, 1), w1);
  r := pg_temp.q(format('SELECT ''done'' FROM public.cancel_my_booking(%L,%L,NULL)', a, 'schedule_conflict'), c1);
  PERFORM pg_temp.pass(18, 'fixture cancellation succeeded', r = 'done', coalesce(r, 'null'));
  PERFORM pg_temp.pass(18, 'termination deleted booking rows',
    NOT EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = a));
  PERFORM pg_temp.pass(18, 'read after termination 42501',
    pg_temp.q(format('SELECT public.get_booking_location_pins(%L)::text', a), w1) = 'ERR:42501');
  PERFORM pg_temp.pass(18, 'publish after termination 42501 (no resurrection)',
    pg_temp.q(format(pub, a, s_w1, 2), w1) = 'ERR:42501');
  PERFORM pg_temp.pass(18, 'own stop still allowed after termination',
    pg_temp.q(format('SELECT public.stop_my_booking_location_share(%L,%L)', a, s_w1), w1) = 'not_current');

  -- 22 direct table access denied; effective EXECUTE privileges
  PERFORM pg_temp.pass(22, 'authenticated direct SELECT denied',
    pg_temp.q('SELECT count(*)::text FROM private.booking_location_shares', c1) = 'ERR:42501');
  PERFORM pg_temp.pass(22, 'no table privileges for client/service roles',
    NOT has_table_privilege('authenticated', 'private.booking_location_shares', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('anon', 'private.booking_location_shares', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('service_role', 'private.booking_location_shares', 'SELECT,INSERT,UPDATE,DELETE'));
  PERFORM pg_temp.pass(22, 'anon cannot execute any RF-01 RPC',
    NOT has_function_privilege('anon', 'public.start_my_booking_location_share(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_booking_location_pins(uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.publish_my_booking_location(uuid,uuid,integer,double precision,double precision,real,timestamptz)', 'EXECUTE'));
  PERFORM pg_temp.pass(22, 'authenticated can execute the read RPC',
    has_function_privilege('authenticated', 'public.get_booking_location_pins(uuid,uuid)', 'EXECUTE'));
  PERFORM pg_temp.pass(22, 'internal helpers not executable by any client role',
    NOT has_function_privilege('authenticated', 'private.rf01_authorize(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'private.rf01_purge_expired_shares()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.rf01_purge_expired_shares()', 'EXECUTE'));

  -- 23 cron job registered
  PERFORM pg_temp.pass(23, 'rf01 purge cron job scheduled every 5 minutes',
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'rf01-location-share-purge'
              AND schedule = '*/5 * * * *' AND command = 'SELECT private.rf01_purge_expired_shares()'));

  -- 24 purge deletes expired rows only (two Worker shares: D expired, B fresh)
  PERFORM pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', d), w2);
  PERFORM pg_temp.q(format('SELECT public.start_my_booking_location_share(%L)::text', '01010101-2000-4000-8000-00000000000b'), w2);
  UPDATE private.booking_location_shares SET started_at = now() - interval '11 minutes'
  WHERE booking_id = d AND user_id = w2;
  PERFORM pg_temp.pass(24, 'purge removes exactly the expired row', private.rf01_purge_expired_shares() = 1);
  PERFORM pg_temp.pass(24, 'fresh row survives purge',
    EXISTS (SELECT 1 FROM private.booking_location_shares WHERE booking_id = '01010101-2000-4000-8000-00000000000b' AND user_id = w2));
END;
$$;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM rf01_results;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM rf01_results WHERE NOT ok) THEN
    RAISE EXCEPTION 'RF01 SQL assertions failed';
  END IF;
END $$;

ROLLBACK;
