-- Completion receipt dispatch — local SQL verification. Disposable fixtures only; ROLLBACKs.
-- Run ONLY against an identified disposable local stack with no network. Temporary Vault secrets
-- point at a closed loopback port; queued pg_net requests are uncommitted and never sent.
-- Expected: every NOTICE line is PASS; the final row shows failed = 0.

BEGIN;

CREATE TEMP TABLE rx_results (n int, name text, ok boolean, detail text);
CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO rx_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.queued() RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM net.http_request_queue $$;

DO $$
DECLARE
  c1 uuid := '05050505-0000-4000-8000-000000000001';
  w1 uuid := '05050505-0000-4000-8000-000000000002';
  c2 uuid := '05050505-0000-4000-8000-000000000003';
  job1 uuid := '05050505-1000-4000-8000-00000000000a';
  job2 uuid := '05050505-1000-4000-8000-00000000000b';
  bk1 uuid := '05050505-2000-4000-8000-00000000000a';
  bk2 uuid := '05050505-2000-4000-8000-00000000000b';
  before bigint; r record; q record;
BEGIN
  -- fixtures: c1 has a confirmed email, c2 does not; one Worker.
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  VALUES
    ('00000000-0000-0000-0000-000000000000', c1, 'authenticated', 'authenticated', 'rx-client1@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
    ('00000000-0000-0000-0000-000000000000', w1, 'authenticated', 'authenticated', 'rx-worker1@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
    ('00000000-0000-0000-0000-000000000000', c2, 'authenticated', 'authenticated', 'rx-client2@example.test', crypt('local-only', gen_salt('bf')), NULL, '{"provider":"email","providers":["email"]}', '{}', now(), now());
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (c1,'rx-client1@example.test','RX Client One','09170000501','client','Santa Ana','Pateros',true),
    (w1,'rx-worker1@example.test','RX Worker One','09170000502','worker','Santa Ana','Pateros',true),
    (c2,'rx-client2@example.test','RX Client Two','09170000503','client','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES ('05050505-0000-4000-8000-000000000012', w1, 'fixture', 'none', 'available', true);
  INSERT INTO public.job_postings(id, client_id, title, description, address, barangay, city, scheduled_at, status, budget) VALUES
    (job1, c1, 'Fix kitchen sink', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day', 'matched', 1500),
    (job2, c2, 'Paint gate', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day', 'matched', 800);
  INSERT INTO public.bookings(id, job_id, worker_id, client_id, status, payment_method, payment_status) VALUES
    (bk1, job1, w1, c1, 'confirmed', 'cod', 'paid'),
    (bk2, job2, w1, c2, 'confirmed', 'cod', 'paid');

  -- 1 no Vault config: completing works and queues nothing (fail open)
  PERFORM pg_temp.pass(1, 'no rf/receipt Vault secrets before the test',
    NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name IN ('completion_receipt_endpoint', 'skillmatch_dispatch_webhook_secret')));
  before := pg_temp.queued();
  UPDATE public.bookings SET status = 'completed', completed_at = now() WHERE id = bk2;
  PERFORM pg_temp.pass(1, 'completion without Vault config succeeds', (SELECT status = 'completed' FROM public.bookings WHERE id = bk2));
  PERFORM pg_temp.pass(1, 'completion without Vault config queues no request', pg_temp.queued() = before);

  PERFORM vault.create_secret('http://127.0.0.1:9/receipt-local-test', 'completion_receipt_endpoint');
  PERFORM vault.create_secret('rx-local-dispatch-secret', 'skillmatch_dispatch_webhook_secret');

  -- 2 a non-completing update queues nothing
  before := pg_temp.queued();
  UPDATE public.bookings SET payment_status = 'paid' WHERE id = bk1;
  UPDATE public.bookings SET status = 'confirmed' WHERE id = bk1;
  PERFORM pg_temp.pass(2, 'updates that do not complete queue nothing', pg_temp.queued() = before);

  -- 3 completing queues exactly one request with only the booking id and the secret header
  before := pg_temp.queued();
  UPDATE public.bookings SET status = 'completed', completed_at = now() WHERE id = bk1;
  PERFORM pg_temp.pass(3, 'completion queues one request', pg_temp.queued() = before + 1, (pg_temp.queued() - before)::text);
  SELECT * INTO q FROM net.http_request_queue ORDER BY id DESC LIMIT 1;
  PERFORM pg_temp.pass(3, 'request goes to the Vault endpoint', q.url = 'http://127.0.0.1:9/receipt-local-test', q.url);
  PERFORM pg_temp.pass(3, 'body is exactly {booking_id}', convert_from(q.body, 'UTF8')::jsonb = jsonb_build_object('booking_id', bk1), convert_from(q.body, 'UTF8'));
  PERFORM pg_temp.pass(3, 'dispatch secret header is sent', q.headers->>'x-skillmatch-dispatch-secret' = 'rx-local-dispatch-secret');

  -- 4 completed -> completed again (no status change) queues nothing
  before := pg_temp.queued();
  UPDATE public.bookings SET status = 'completed', payment_status = 'paid' WHERE id = bk1;
  PERFORM pg_temp.pass(4, 'an update that stays completed does not re-send', pg_temp.queued() = before);

  -- 5 receipt context: completed + confirmed email only, Client email, no Worker data
  SELECT * INTO r FROM public.get_completion_receipt_context(bk1);
  PERFORM pg_temp.pass(5, 'context row for a completed booking', r.booking_id = bk1 AND r.booking_status = 'completed');
  PERFORM pg_temp.pass(5, 'context carries the Client confirmed email', r.client_email = 'rx-client1@example.test', r.client_email);
  PERFORM pg_temp.pass(5, 'context carries job, amount, method and payment status',
    r.job_title = 'Fix kitchen sink' AND r.job_budget = 1500 AND r.payment_method = 'cod' AND r.payment_status = 'paid');
  PERFORM pg_temp.pass(5, 'no context when the Client email is unconfirmed', NOT EXISTS (SELECT 1 FROM public.get_completion_receipt_context(bk2)));
  UPDATE public.bookings SET status = 'confirmed', completed_at = NULL WHERE id = bk1;
  PERFORM pg_temp.pass(5, 'no context for a booking that is not completed', NOT EXISTS (SELECT 1 FROM public.get_completion_receipt_context(bk1)));
  UPDATE public.bookings SET status = 'completed', completed_at = now() WHERE id = bk1;

  -- 6 ledger: one send per key; failed retries capped; sent never re-sent
  PERFORM pg_temp.pass(6, 'first claim may send', public.claim_outbound_dispatch('completion-receipt:x', 'completion_receipt', bk1, 3));
  PERFORM pg_temp.pass(6, 'a concurrent claim may not', NOT public.claim_outbound_dispatch('completion-receipt:x', 'completion_receipt', bk1, 3));
  PERFORM public.finish_outbound_dispatch('completion-receipt:x', false, NULL, 'smtp_unreachable');
  PERFORM pg_temp.pass(6, 'a failed send may be retried', public.claim_outbound_dispatch('completion-receipt:x', 'completion_receipt', bk1, 3));
  PERFORM public.finish_outbound_dispatch('completion-receipt:x', false, NULL, 'smtp_unreachable');
  PERFORM pg_temp.pass(6, 'third attempt allowed', public.claim_outbound_dispatch('completion-receipt:x', 'completion_receipt', bk1, 3));
  PERFORM public.finish_outbound_dispatch('completion-receipt:x', false, NULL, 'smtp_unreachable');
  PERFORM pg_temp.pass(6, 'attempts are capped at 3', NOT public.claim_outbound_dispatch('completion-receipt:x', 'completion_receipt', bk1, 3));
  PERFORM public.claim_outbound_dispatch('completion-receipt:y', 'completion_receipt', bk1, 3);
  PERFORM public.finish_outbound_dispatch('completion-receipt:y', true, 'msg-1', NULL);
  PERFORM pg_temp.pass(6, 'a sent receipt is never re-sent', NOT public.claim_outbound_dispatch('completion-receipt:y', 'completion_receipt', bk1, 3));
  PERFORM pg_temp.pass(6, 'ledger keeps the message reference, no address',
    (SELECT provider_ref = 'msg-1' AND status = 'sent' FROM private.outbound_dispatches WHERE dedup_key = 'completion-receipt:y'));
END;
$$;

-- 7 privileges: only service_role may call the receipt RPCs; nobody reads the ledger directly
SELECT pg_temp.pass(7, 'context not executable by authenticated',
  NOT has_function_privilege('authenticated', 'public.get_completion_receipt_context(uuid)', 'EXECUTE'));
SELECT pg_temp.pass(7, 'context not executable by anon',
  NOT has_function_privilege('anon', 'public.get_completion_receipt_context(uuid)', 'EXECUTE'));
SELECT pg_temp.pass(7, 'context executable by service_role',
  has_function_privilege('service_role', 'public.get_completion_receipt_context(uuid)', 'EXECUTE'));
SELECT pg_temp.pass(7, 'claim not executable by authenticated',
  NOT has_function_privilege('authenticated', 'public.claim_outbound_dispatch(text,text,uuid,integer)', 'EXECUTE'));
SELECT pg_temp.pass(7, 'finish not executable by authenticated',
  NOT has_function_privilege('authenticated', 'public.finish_outbound_dispatch(text,boolean,text,text)', 'EXECUTE'));
SELECT pg_temp.pass(7, 'ledger table not readable by authenticated or service_role',
  NOT has_table_privilege('authenticated', 'private.outbound_dispatches', 'SELECT')
  AND NOT has_table_privilege('service_role', 'private.outbound_dispatches', 'SELECT'));
SELECT pg_temp.pass(7, 'trigger function not executable by authenticated',
  NOT has_function_privilege('authenticated', 'private.dispatch_booking_completed_receipt()', 'EXECUTE'));

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM rx_results;

ROLLBACK;
