-- LIVE-01 local SQL verification: Booking progress Broadcast. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE live01_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON live01_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO live01_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.clear_jwt()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('realtime.topic', '', true);
  PERFORM set_config('role', 'postgres', true);
  RESET ROLE;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_user(p_id uuid, p_role text, p_active boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000',p_id,'authenticated','authenticated','live01-' || right(p_id::text, 2) || '@example.test',
          crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (p_id,'live01-' || right(p_id::text, 2) || '@example.test','LIVE01 ' || p_role,'0919000' || lpad(right(p_id::text, 4), 4, '0'),p_role,'Santa Ana','Pateros',p_active);
END;
$$;

-- A confirmed booking on a matched Job scheduled at p_when.
CREATE OR REPLACE FUNCTION pg_temp.mk_booking(p_booking uuid, p_job uuid, p_client uuid, p_worker uuid, p_when timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.job_postings(id,client_id,title,description,address,barangay,city,status,scheduled_at)
  VALUES (p_job,p_client,'LIVE01 job','Local test only','Selected pin street','Santa Ana','Pateros','matched',p_when);
  INSERT INTO public.bookings(id,job_id,worker_id,client_id,status) VALUES (p_booking,p_job,p_worker,p_client,'confirmed');
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.progress_events(p_booking uuid)
RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM realtime.messages
  WHERE topic = 'booking:' || p_booking::text || ':messages' AND event = 'booking_progress_changed';
$$;

DO $$
DECLARE
  client_one uuid := '0e0b0303-0000-4000-8000-000000000002';
  outsider uuid := '0e0b0303-0000-4000-8000-000000000003';
  worker_one uuid := '0e0b0303-0000-4000-8000-000000000004';
  b uuid := '0e0b0303-2000-4000-8000-000000000001';
  b_done uuid := '0e0b0303-2000-4000-8000-000000000002';
  n bigint;
  v_visible bigint;
  v_case record;
BEGIN
  PERFORM pg_temp.mk_user(client_one, 'client');
  PERFORM pg_temp.mk_user(outsider, 'client');
  PERFORM pg_temp.mk_user(worker_one, 'worker');
  PERFORM pg_temp.mk_booking(b, '0e0b0303-3000-4000-8000-000000000001', client_one, worker_one, now() + interval '1 hour');
  PERFORM pg_temp.mk_booking(b_done, '0e0b0303-3000-4000-8000-000000000002', client_one, worker_one, now() + interval '5 hours');

  -- ---------- Each live step announces itself ----------
  n := pg_temp.progress_events(b);
  UPDATE public.bookings SET worker_arrived_at = now() WHERE id = b;
  PERFORM pg_temp.pass(1, 'Worker arrival broadcasts', pg_temp.progress_events(b) = n + 1);
  UPDATE public.bookings SET worker_service_completed_at = now() WHERE id = b;
  PERFORM pg_temp.pass(2, 'Worker Mark as Completed broadcasts', pg_temp.progress_events(b) = n + 2);
  UPDATE public.bookings SET payment_method = 'cod' WHERE id = b;
  PERFORM pg_temp.pass(3, 'Client Cash choice broadcasts', pg_temp.progress_events(b) = n + 3);
  UPDATE public.bookings SET payment_status = 'paid' WHERE id = b;
  PERFORM pg_temp.pass(4, 'a settled payment broadcasts', pg_temp.progress_events(b) = n + 4);
  UPDATE public.bookings SET paymongo_ref = 'live01-ref' WHERE id = b;
  PERFORM pg_temp.pass(5, 'a QR Ph reference broadcasts', pg_temp.progress_events(b) = n + 5);

  -- ---------- Quiet when nothing a participant sees changed ----------
  UPDATE public.bookings SET payment_status = 'paid', payment_method = 'cod' WHERE id = b;
  PERFORM pg_temp.pass(6, 'an update to the same values is silent', pg_temp.progress_events(b) = n + 5);

  -- ---------- Leaving confirmed is R5's event, not this trigger's ----------
  UPDATE public.bookings SET status = 'cancelled', worker_arrived_at = now() WHERE id = b_done;
  PERFORM pg_temp.pass(7, 'a Booking leaving confirmed sends no progress event', pg_temp.progress_events(b_done) = 0);
  PERFORM pg_temp.pass(8, 'and R5 still announces that status change', EXISTS (
    SELECT 1 FROM realtime.messages WHERE topic = 'booking:' || b_done::text || ':messages' AND event = 'booking_status_changed'));
  UPDATE public.bookings SET payment_status = 'pending' WHERE id = b_done;
  PERFORM pg_temp.pass(9, 'a Booking that is no longer confirmed stays silent', pg_temp.progress_events(b_done) = 0);

  -- ---------- Payload and transport ----------
  PERFORM pg_temp.pass(10, 'private Broadcast carrying the booking id only', NOT EXISTS (
    SELECT 1 FROM realtime.messages
    WHERE event = 'booking_progress_changed' AND topic = 'booking:' || b::text || ':messages'
      AND (private IS DISTINCT FROM true OR extension <> 'broadcast'
        OR payload IS NULL OR (payload - 'id') <> jsonb_build_object('booking_id', b))));

  -- ---------- Receipt: the unchanged R5 booking-topic policy ----------
  FOR v_case IN SELECT * FROM (VALUES
    ('the Booking Client', client_one, true),
    ('the Booking Worker', worker_one, true),
    ('an unrelated Client', outsider, false)
  ) AS f(label, id, allowed) LOOP
    PERFORM set_config('request.jwt.claim.sub', v_case.id::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_case.id, 'role', 'authenticated')::text, true);
    PERFORM set_config('realtime.topic', 'booking:' || b::text || ':messages', true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_visible FROM realtime.messages
      WHERE topic = 'booking:' || b::text || ':messages' AND event = 'booking_progress_changed';
    RESET ROLE;
    PERFORM pg_temp.pass(11, v_case.label || ' receive authorization', (v_visible > 0) = v_case.allowed, v_visible::text);
  END LOOP;
  PERFORM pg_temp.clear_jwt();

  -- ---------- Properties ----------
  PERFORM pg_temp.pass(12, 'trigger-only function: SECURITY DEFINER, empty search_path, owner postgres, no EXECUTE for any role',
    EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'private.live01_broadcast_booking_progress_changed()'::regprocedure
            AND prosecdef AND proconfig = ARRAY['search_path=""'] AND proowner = 'postgres'::regrole)
    AND NOT has_function_privilege('anon', 'private.live01_broadcast_booking_progress_changed()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.live01_broadcast_booking_progress_changed()', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'private.live01_broadcast_booking_progress_changed()', 'EXECUTE'));
  PERFORM pg_temp.pass(13, 'no authenticated or public Broadcast INSERT policy', NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'realtime' AND tablename = 'messages'
      AND cmd IN ('INSERT', 'ALL') AND roles && ARRAY['authenticated', 'public']::name[]));
  PERFORM pg_temp.pass(14, 'one LIVE-01 trigger next to the unchanged R5 status trigger', (
    SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.bookings'::regclass AND NOT tgisinternal
      AND tgname IN ('live01_broadcast_booking_progress_changed', 'r5_broadcast_booking_status_changed')) = 2);
  PERFORM pg_temp.pass(15, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM live01_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'LIVE-01 failed % assertions', failed; END IF;
  RAISE NOTICE 'LIVE-01: % assertions passed', (SELECT count(*) FROM live01_results);
END;
$$;

ROLLBACK;
