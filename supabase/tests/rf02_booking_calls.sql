-- RF-02 booking calls — local SQL verification. Disposable fixtures only.
-- Run ONLY against an identified disposable local stack after
-- `npx supabase db reset --local` with NO rf02 Vault secrets configured
-- (so the dispatch path reaches no external service). ROLLBACKs.
-- Expected: every NOTICE line is PASS; the final row shows failed = 0.

BEGIN;

CREATE TEMP TABLE rf02_results (n int, name text, ok boolean, detail text);
GRANT INSERT ON rf02_results TO service_role, authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO rf02_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

-- Runs p_sql as p_role; returns 'ERR:<sqlstate>' or the single text result.
CREATE OR REPLACE FUNCTION pg_temp.as_role(p_sql text, p_role text DEFAULT 'service_role')
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM set_config('role', p_role, true);
  BEGIN
    EXECUTE p_sql INTO v;
  EXCEPTION WHEN OTHERS THEN v := 'ERR:' || SQLSTATE;
  END;
  PERFORM set_config('role', 'postgres', true);
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.pair(
  p_job uuid, p_booking uuid, p_client uuid, p_worker uuid, p_status text DEFAULT 'confirmed'
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.job_postings(id, client_id, title, description, address, barangay, city, scheduled_at, status, budget)
  VALUES (p_job, p_client, 'RF02 fixture', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros',
          now() + interval '1 day', 'matched', 500);
  INSERT INTO public.bookings(id, job_id, worker_id, client_id, status)
  VALUES (p_booking, p_job, p_worker, p_client, p_status);
END;
$$;

DO $$
DECLARE
  c1 uuid := '02020202-0000-4000-8000-000000000001';
  w1 uuid := '02020202-0000-4000-8000-000000000002';
  c2 uuid := '02020202-0000-4000-8000-000000000003';
  w2 uuid := '02020202-0000-4000-8000-000000000004';
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  SELECT '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
         crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
  FROM (VALUES (c1,'rf02-client1@example.test'),(w1,'rf02-worker1@example.test'),
               (c2,'rf02-client2@example.test'),(w2,'rf02-worker2@example.test')) AS u(id,email);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (c1,'rf02-client1@example.test','RF02 Client One','09170000201','client','Santa Ana','Pateros',true),
    (w1,'rf02-worker1@example.test','RF02 Worker One','09170000202','worker','Santa Ana','Pateros',true),
    (c2,'rf02-client2@example.test','RF02 Client Two','09170000203','client','Santa Ana','Pateros',true),
    (w2,'rf02-worker2@example.test','RF02 Worker Two','09170000204','worker','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified) VALUES
    ('02020202-0000-4000-8000-000000000012',w1,'fixture','none','available',true),
    ('02020202-0000-4000-8000-000000000014',w2,'fixture','none','available',true);
  INSERT INTO private.user_devices(user_id, expo_push_token, platform, is_active) VALUES
    (w1, 'ExponentPushToken[rf02-worker1]', 'android', true),
    (w1, 'ExponentPushToken[rf02-worker1-old]', 'android', false),
    (c1, 'ExponentPushToken[rf02-client1]', 'android', true);
  -- A: confirmed c1/w1. B: confirmed c2/w2. P: pending c1/w1. D: confirmed c1/w2.
  PERFORM pg_temp.pair('02020202-1000-4000-8000-00000000000a','02020202-2000-4000-8000-00000000000a',c1,w1,'confirmed');
  PERFORM pg_temp.pair('02020202-1000-4000-8000-00000000000b','02020202-2000-4000-8000-00000000000b',c2,w2,'confirmed');
  PERFORM pg_temp.pair('02020202-1000-4000-8000-00000000000c','02020202-2000-4000-8000-00000000000c',c1,w1,'pending');
  PERFORM pg_temp.pair('02020202-1000-4000-8000-00000000000d','02020202-2000-4000-8000-00000000000d',c1,w2,'confirmed');
END;
$$;

DO $$
DECLARE
  c1 uuid := '02020202-0000-4000-8000-000000000001';
  w1 uuid := '02020202-0000-4000-8000-000000000002';
  c2 uuid := '02020202-0000-4000-8000-000000000003';
  w2 uuid := '02020202-0000-4000-8000-000000000004';
  a  uuid := '02020202-2000-4000-8000-00000000000a';
  p  uuid := '02020202-2000-4000-8000-00000000000c';
  d  uuid := '02020202-2000-4000-8000-00000000000d';
  j jsonb; j2 jsonb; call1 uuid; call2 uuid; r text; v_count int;
  start_sql text := 'SELECT public.rf02_call_start(%L,%L)::text';
  act_sql   text := 'SELECT public.rf02_call_act(%L,%L,%L)::text';
BEGIN
  -- 1 start creates ringing with a 45 s ring window, provision pending
  j := pg_temp.as_role(format(start_sql, c1, a))::jsonb;
  call1 := (j->'call'->>'call_id')::uuid;
  PERFORM pg_temp.pass(1, 'start creates ringing call', (j->>'created')::boolean AND j->'call'->>'state' = 'ringing', j::text);
  PERFORM pg_temp.pass(1, 'ring window 45 s', (SELECT ring_expires_at - created_at FROM private.booking_calls WHERE call_id = call1) = interval '45 seconds');
  PERFORM pg_temp.pass(1, 'room name derived from call id', j->'call'->>'room_name' = 'call_' || call1::text);
  PERFORM pg_temp.pass(1, 'provision pending', j->'call'->>'provision_state' = 'pending');

  -- 2 denied starts
  PERFORM pg_temp.pass(2, 'unrelated actor start 42501', pg_temp.as_role(format(start_sql, c2, a)) = 'ERR:42501');
  PERFORM pg_temp.pass(2, 'pending booking start 42501', pg_temp.as_role(format(start_sql, c1, p)) = 'ERR:42501');
  PERFORM pg_temp.pass(2, 'null actor start 42501', pg_temp.as_role(format(start_sql, NULL, a)) = 'ERR:42501');

  -- 3 the other participant's concurrent start converges on the same call
  j2 := pg_temp.as_role(format(start_sql, w1, a))::jsonb;
  PERFORM pg_temp.pass(3, 'second participant start returns existing call',
    NOT (j2->>'created')::boolean AND (j2->'call'->>'call_id')::uuid = call1 AND j2->'call'->>'role' = 'callee', j2::text);

  -- 4 a retried start by the caller does not create or re-invite
  j2 := pg_temp.as_role(format(start_sql, c1, a))::jsonb;
  PERFORM pg_temp.pass(4, 'caller retry returns same call created=false',
    NOT (j2->>'created')::boolean AND (j2->'call'->>'call_id')::uuid = call1);
  PERFORM pg_temp.pass(4, 'exactly one active call row', (SELECT count(*) FROM private.booking_calls WHERE booking_id = a) = 1);

  -- 4b invite claimed once only
  PERFORM pg_temp.pass(4, 'first invite claim true', pg_temp.as_role(format('SELECT public.rf02_call_claim_invite(%L)::text', call1)) = 'true');
  PERFORM pg_temp.pass(4, 'second invite claim false', pg_temp.as_role(format('SELECT public.rf02_call_claim_invite(%L)::text', call1)) = 'false');
  PERFORM pg_temp.pass(4, 'push targets = callee active tokens only',
    pg_temp.as_role(format('SELECT string_agg(expo_push_token, '','') FROM public.rf02_call_push_targets(%L)', call1)) = 'ExponentPushToken[rf02-worker1]');

  -- 5 accept before provisioning is refused (not an error)
  j := pg_temp.as_role(format(act_sql, w1, call1, 'accept'))::jsonb;
  PERFORM pg_temp.pass(5, 'accept before ready -> provisioning', NOT (j->>'ok')::boolean AND j->>'reason' = 'provisioning', j::text);

  -- 6 unknown provisioning keeps the call alive; ready never downgrades
  j := pg_temp.as_role(format('SELECT public.rf02_call_record_provisioning(%L,%L)::text', call1, 'unknown'))::jsonb;
  PERFORM pg_temp.pass(6, 'unknown result keeps ringing', j->>'state' = 'ringing' AND j->>'provision_state' = 'unknown', j::text);
  PERFORM pg_temp.as_role(format('SELECT public.rf02_call_record_provisioning(%L,%L)::text', call1, 'ready'));
  j := pg_temp.as_role(format('SELECT public.rf02_call_record_provisioning(%L,%L)::text', call1, 'unknown'))::jsonb;
  PERFORM pg_temp.pass(6, 'ready is never downgraded', j->>'provision_state' = 'ready');

  -- 7 caller cannot accept; callee accepts
  PERFORM pg_temp.pass(7, 'caller accept 42501', pg_temp.as_role(format(act_sql, c1, call1, 'accept')) = 'ERR:42501');
  j := pg_temp.as_role(format(act_sql, w1, call1, 'accept'))::jsonb;
  PERFORM pg_temp.pass(7, 'callee accept ok', (j->>'ok')::boolean AND j->'call'->>'state' = 'accepted', j::text);

  -- 8 accept vs cancel race outcome: cancel after accept is a conflict
  j := pg_temp.as_role(format(act_sql, c1, call1, 'cancel'))::jsonb;
  PERFORM pg_temp.pass(8, 'cancel after accept -> not_ringing', NOT (j->>'ok')::boolean AND j->>'reason' = 'not_ringing');

  -- 9 away / back / rejoin
  j := pg_temp.as_role(format(act_sql, c1, call1, 'away'))::jsonb;
  PERFORM pg_temp.pass(9, 'away recorded for caller', (SELECT caller_away_since IS NOT NULL FROM private.booking_calls WHERE call_id = call1));
  j := pg_temp.as_role(format(act_sql, c1, call1, 'rejoin'))::jsonb;
  PERFORM pg_temp.pass(9, 'rejoin within 90 s ok', (j->>'ok')::boolean, j::text);
  UPDATE private.booking_calls SET caller_away_since = now() - interval '91 seconds' WHERE call_id = call1;
  j := pg_temp.as_role(format(act_sql, c1, call1, 'rejoin'))::jsonb;
  PERFORM pg_temp.pass(9, 'rejoin after 90 s away -> abandoned, never auto-rejoined',
    NOT (j->>'ok')::boolean AND j->>'reason' = 'abandoned' AND j->'call'->>'state' = 'ended', j::text);
  PERFORM pg_temp.pass(9, 'abandoned call cleanup pending', (SELECT cleanup_state FROM private.booking_calls WHERE call_id = call1) = 'pending');

  -- 10 terminal states are immutable
  j := pg_temp.as_role(format(act_sql, w1, call1, 'end'))::jsonb;
  PERFORM pg_temp.pass(10, 'end on ended -> not_active', NOT (j->>'ok')::boolean AND j->'call'->>'state' = 'ended');

  -- 11 decline is callee-only; cancel caller-only
  j := pg_temp.as_role(format(start_sql, c1, a))::jsonb;
  call2 := (j->'call'->>'call_id')::uuid;
  PERFORM pg_temp.pass(11, 'caller decline 42501', pg_temp.as_role(format(act_sql, c1, call2, 'decline')) = 'ERR:42501');
  PERFORM pg_temp.pass(11, 'callee cancel 42501', pg_temp.as_role(format(act_sql, w1, call2, 'cancel')) = 'ERR:42501');
  PERFORM pg_temp.pass(11, 'unknown action 22023', pg_temp.as_role(format(act_sql, w1, call2, 'record')) = 'ERR:22023');
  PERFORM pg_temp.pass(11, 'non-participant action 42501', pg_temp.as_role(format(act_sql, c2, call2, 'decline')) = 'ERR:42501');

  -- 12 cancellation during provisioning, then late provider success
  j := pg_temp.as_role(format(act_sql, c1, call2, 'cancel'))::jsonb;
  PERFORM pg_temp.pass(12, 'caller cancel while provisioning ok', (j->>'ok')::boolean AND j->'call'->>'state' = 'cancelled');
  j := pg_temp.as_role(format('SELECT public.rf02_call_record_provisioning(%L,%L)::text', call2, 'ready'))::jsonb;
  PERFORM pg_temp.pass(12, 'late ready keeps call cancelled', j->>'state' = 'cancelled' AND j->>'provision_state' = 'ready');
  PERFORM pg_temp.pass(12, 'late ready keeps cleanup pending (room will be deleted)', j->>'cleanup_state' = 'pending');
  PERFORM pg_temp.pass(12, 'no invite for a cancelled call', pg_temp.as_role(format('SELECT public.rf02_call_claim_invite(%L)::text', call2)) = 'false');
  PERFORM pg_temp.as_role(format('SELECT public.rf02_call_mark_cleanup(%L,true,%s)', call2, j->>'provision_attempts'));
  j := pg_temp.as_role(format('SELECT public.rf02_call_record_provisioning(%L,%L)::text', call2, 'ready'))::jsonb;
  PERFORM pg_temp.pass(12, 'late room creation invalidates earlier confirmed absence',
    j->>'state' = 'cancelled' AND j->>'cleanup_state' = 'pending' AND j->>'cleanup_confirmed_at' IS NULL, j::text);
  PERFORM pg_temp.pass(12, 'cleanup without a provisioning snapshot cannot confirm absence',
    pg_temp.as_role(format('SELECT public.rf02_call_mark_cleanup(%L,true)', call2)) = 'stale_provisioning');
  PERFORM pg_temp.pass(12, 'older provisioning snapshot cannot confirm newer room creation',
    pg_temp.as_role(format('SELECT public.rf02_call_mark_cleanup(%L,true,%s)', call2,
      (j->>'provision_attempts')::integer - 1)) = 'stale_provisioning');

  -- 13 definitive rejection fails a live call
  j := pg_temp.as_role(format(start_sql, w1, a))::jsonb;
  call2 := (j->'call'->>'call_id')::uuid;
  j := pg_temp.as_role(format('SELECT public.rf02_call_record_provisioning(%L,%L)::text', call2, 'rejected'))::jsonb;
  PERFORM pg_temp.pass(13, 'rejected -> failed provider_rejected', j->>'state' = 'failed' AND j->>'end_reason' = 'provider_rejected', j::text);

  -- 14 ring expiry: lazy on read and in the batch
  j := pg_temp.as_role(format(start_sql, c1, a))::jsonb;
  call2 := (j->'call'->>'call_id')::uuid;
  -- All calls in this test share transaction-stable now(). Give this newest
  -- fixture a distinct creation time so terminal-call ordering is exercised.
  UPDATE private.booking_calls
  SET created_at = clock_timestamp(), ring_expires_at = now() - interval '1 second'
  WHERE call_id = call2;
  j := pg_temp.as_role(format('SELECT public.rf02_call_current(%L,%L)::text', w1, a))::jsonb;
  PERFORM pg_temp.pass(14, 'read after ring expiry shows missed', j->'call'->>'state' = 'missed', j::text);
  j := pg_temp.as_role(format(act_sql, w1, call2, 'accept'))::jsonb;
  PERFORM pg_temp.pass(14, 'accept after expiry -> not_ringing', NOT (j->>'ok')::boolean);
  j := pg_temp.as_role(format(start_sql, c1, a))::jsonb;
  call2 := (j->'call'->>'call_id')::uuid;
  UPDATE private.booking_calls SET ring_expires_at = now() - interval '1 second' WHERE call_id = call2;
  j := pg_temp.as_role('SELECT public.rf02_call_reconcile_batch(50)::text')::jsonb;
  PERFORM pg_temp.pass(14, 'batch expires ringing to missed', (SELECT state FROM private.booking_calls WHERE call_id = call2) = 'missed');
  PERFORM pg_temp.pass(14, 'batch lists due cleanups with room names',
    EXISTS (SELECT 1 FROM jsonb_array_elements(j->'cleanup') e WHERE e->>'room_name' = 'call_' || call2::text), j::text);
  PERFORM pg_temp.pass(14, 'cleanup batch carries the provisioning snapshot fence',
    EXISTS (SELECT 1 FROM jsonb_array_elements(j->'cleanup') e
            WHERE e->>'call_id' = call2::text AND e->>'provision_attempts' = '0'));

  -- 15 booking termination ends the call (maintenance still works afterwards)
  j := pg_temp.as_role(format(start_sql, c1, a))::jsonb;
  call2 := (j->'call'->>'call_id')::uuid;
  PERFORM pg_temp.as_role(format('SELECT public.rf02_call_record_provisioning(%L,%L)::text', call2, 'ready'));
  PERFORM pg_temp.as_role(format(act_sql, w1, call2, 'accept'));
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c1::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', c1::text, true);
  PERFORM set_config('role', 'authenticated', true);
  PERFORM public.cancel_my_booking(a, 'schedule_conflict', NULL);
  PERFORM set_config('role', 'postgres', true);
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM pg_temp.pass(15, 'booking termination ends active call',
    (SELECT state = 'ended' AND end_reason = 'booking_ended' AND cleanup_state = 'pending'
     FROM private.booking_calls WHERE call_id = call2));
  PERFORM pg_temp.pass(15, 'local stack has no rf02 Vault endpoint (isolation precondition)',
    NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name LIKE 'rf02_%'));
  PERFORM pg_temp.pass(15, 'no outbound reconcile request queued for the call',
    NOT EXISTS (SELECT 1 FROM net.http_request_queue q
                WHERE convert_from(q.body, 'UTF8') LIKE '%' || call2::text || '%'));
  PERFORM pg_temp.pass(15, 'rejoin after termination 42501', pg_temp.as_role(format(act_sql, w1, call2, 'rejoin')) = 'ERR:42501');
  PERFORM pg_temp.pass(15, 'cleanup mark still works after termination',
    pg_temp.as_role(format('SELECT public.rf02_call_mark_cleanup(%L,false)', call2)) = 'pending');

  -- 16 deactivation ends calls (booking D: c1/w2)
  j := pg_temp.as_role(format(start_sql, w2, d))::jsonb;
  call2 := (j->'call'->>'call_id')::uuid;
  UPDATE public.users SET is_active = false WHERE id = w2;
  PERFORM pg_temp.pass(16, 'deactivation ends call account_inactive',
    (SELECT state = 'ended' AND end_reason = 'account_inactive' FROM private.booking_calls WHERE call_id = call2));
  UPDATE public.users SET is_active = true WHERE id = w2;

  -- 17 cleanup backoff, exhaustion retained, recovery, confirm, purge
  UPDATE private.booking_calls SET cleanup_attempts = 7, next_cleanup_at = now() WHERE call_id = call2;
  PERFORM pg_temp.pass(17, '8th failure -> failed', pg_temp.as_role(format('SELECT public.rf02_call_mark_cleanup(%L,false)', call2)) = 'failed');
  PERFORM pg_temp.as_role('SELECT public.rf02_call_reconcile_batch(50)::text');
  PERFORM pg_temp.pass(17, 'failed cleanup is retained with its room name',
    EXISTS (SELECT 1 FROM private.booking_calls WHERE call_id = call2 AND cleanup_state = 'failed' AND room_name = 'call_' || call2::text));
  PERFORM pg_temp.pass(17, 'recovery requeues failed cleanup',
    pg_temp.as_role(format('SELECT public.rf02_call_retry_failed_cleanup(%L)::text', call2)) = 'true');
  PERFORM pg_temp.pass(17, 'ok mark confirms', pg_temp.as_role(format('SELECT public.rf02_call_mark_cleanup(%L,true,0)', call2)) = 'confirmed');
  PERFORM pg_temp.pass(17, 'confirm on non-pending is a no-op', pg_temp.as_role(format('SELECT public.rf02_call_mark_cleanup(%L,true,0)', call2)) = 'not_pending');
  UPDATE private.booking_calls SET cleanup_confirmed_at = now() - interval '8 days' WHERE call_id = call2;
  PERFORM pg_temp.as_role('SELECT public.rf02_call_reconcile_batch(50)::text');
  PERFORM pg_temp.pass(17, 'confirmed rows purged after 7 days', NOT EXISTS (SELECT 1 FROM private.booking_calls WHERE call_id = call2));

  -- 18 ids-only broadcast to both user topics
  SELECT count(*) INTO v_count FROM realtime.messages m
  WHERE m.event = 'call_state_changed' AND m.topic IN ('user:' || c1::text || ':notifications', 'user:' || w1::text || ':notifications');
  PERFORM pg_temp.pass(18, 'call_state_changed emitted on user topics', v_count > 0, 'count=' || v_count);
  -- realtime.send adds its own message id to the application payload.
  PERFORM pg_temp.pass(18, 'payload contains only booking_id, call_id and the Realtime message id',
    NOT EXISTS (SELECT 1 FROM realtime.messages m WHERE m.event = 'call_state_changed'
                AND ((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(m.payload - 'id') AS k) IS DISTINCT FROM ARRAY['booking_id', 'call_id']
                  OR m.payload->>'id' IS DISTINCT FROM m.id::text)));

  -- 19 effective privileges and direct-table protection
  PERFORM pg_temp.pass(19, 'authenticated cannot execute call wrappers',
    NOT has_function_privilege('authenticated', 'public.rf02_call_start(uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.rf02_call_act(uuid,uuid,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.rf02_call_reconcile_batch(integer)', 'EXECUTE'));
  PERFORM pg_temp.pass(19, 'anon cannot execute call wrappers',
    NOT has_function_privilege('anon', 'public.rf02_call_current(uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.rf02_call_mark_cleanup(uuid,boolean,integer)', 'EXECUTE'));
  PERFORM pg_temp.pass(19, 'authenticated call through PostgREST role denied',
    pg_temp.as_role(format(start_sql, c1, d), 'authenticated') = 'ERR:42501');
  PERFORM pg_temp.pass(19, 'service_role can execute wrappers',
    has_function_privilege('service_role', 'public.rf02_call_start(uuid,uuid)', 'EXECUTE'));
  PERFORM pg_temp.pass(19, 'private call functions not executable by any client/service role',
    NOT has_function_privilege('service_role', 'private.rf02_act(uuid,uuid,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.rf02_finish(uuid,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'private.rf02_dispatch_reconcile(uuid)', 'EXECUTE'));
  PERFORM pg_temp.pass(19, 'no table privileges on booking_calls',
    NOT has_table_privilege('authenticated', 'private.booking_calls', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('anon', 'private.booking_calls', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('service_role', 'private.booking_calls', 'SELECT,INSERT,UPDATE,DELETE'));
  PERFORM pg_temp.pass(19, 'service_role direct SELECT denied',
    pg_temp.as_role('SELECT count(*)::text FROM private.booking_calls') = 'ERR:42501');

  -- 20 presence: absent sets away, present clears; abandonment via batch
  j := pg_temp.as_role(format(start_sql, c1, d))::jsonb;
  call2 := (j->'call'->>'call_id')::uuid;
  PERFORM pg_temp.as_role(format('SELECT public.rf02_call_record_provisioning(%L,%L)::text', call2, 'ready'));
  PERFORM pg_temp.as_role(format(act_sql, w2, call2, 'accept'));
  j := pg_temp.as_role(format('SELECT public.rf02_call_record_presence(%L,%L::uuid[])::text', call2, ARRAY[c1]))::jsonb;
  PERFORM pg_temp.pass(20, 'absent callee marked away, present caller clear',
    j->>'callee_away_since' IS NOT NULL AND j->>'caller_away_since' IS NULL, j::text);
  UPDATE private.booking_calls SET callee_away_since = now() - interval '91 seconds' WHERE call_id = call2;
  PERFORM pg_temp.as_role('SELECT public.rf02_call_reconcile_batch(50)::text');
  PERFORM pg_temp.pass(20, 'batch abandons call after 90 s away',
    (SELECT state = 'ended' AND end_reason = 'abandoned' FROM private.booking_calls WHERE call_id = call2));

  -- 21 cron job registered
  PERFORM pg_temp.pass(21, 'rf02 reconcile cron job every minute',
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'rf02-call-reconcile'
              AND schedule = '* * * * *' AND command = 'SELECT private.rf02_dispatch_reconcile(NULL)'));

  -- 22 room lookup for webhook hints
  PERFORM pg_temp.pass(22, 'room lookup returns call id',
    pg_temp.as_role(format('SELECT public.rf02_call_by_room(%L)::text', 'call_' || call2::text)) = call2::text);
END;
$$;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM rf02_results;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM rf02_results WHERE NOT ok) THEN
    RAISE EXCEPTION 'RF02 SQL assertions failed';
  END IF;
END $$;

ROLLBACK;
