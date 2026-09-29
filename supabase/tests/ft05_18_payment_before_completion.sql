-- FT-05 #18 local SQL verification. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE ft05_18_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON ft05_18_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ft05_18_results VALUES (p_n, p_name, p_ok, p_detail);
  IF p_ok THEN RAISE NOTICE 'PASS % %', p_n, p_name;
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

CREATE OR REPLACE FUNCTION pg_temp.state(p_sql text, p_uid uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  IF p_uid IS NOT NULL THEN PERFORM pg_temp.jwt(p_uid); END IF;
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE; END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.pair(
  p_job uuid, p_booking uuid, p_client uuid, p_worker uuid,
  p_booking_status text DEFAULT 'confirmed', p_job_status text DEFAULT 'matched',
  p_method text DEFAULT NULL, p_payment text DEFAULT 'pending', p_ref text DEFAULT NULL,
  p_job_method text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.job_postings(id, client_id, title, description, address, barangay, city, scheduled_at, status, budget, payment_method)
  VALUES (p_job, p_client, 'FT05 payment fixture', 'fixture', 'Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day', p_job_status, 500, p_job_method);
  INSERT INTO public.bookings(id, job_id, worker_id, client_id, status, payment_method, payment_status, paymongo_ref)
  VALUES (p_booking, p_job, p_worker, p_client, p_booking_status, p_method, p_payment, p_ref);
END;
$$;

DO $$
DECLARE
  client_one uuid := '18181818-0000-4000-8000-000000000001';
  client_two uuid := '18181818-0000-4000-8000-000000000002';
  worker_one uuid := '18181818-0000-4000-8000-000000000003';
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) VALUES
    ('00000000-0000-0000-0000-000000000000',client_one,'authenticated','authenticated','ft0518-client1@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
    ('00000000-0000-0000-0000-000000000000',client_two,'authenticated','authenticated','ft0518-client2@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
    ('00000000-0000-0000-0000-000000000000',worker_one,'authenticated','authenticated','ft0518-worker@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (client_one,'ft0518-client1@example.test','FT05 Client One','09180000001','client','Santa Ana','Pateros',true),
    (client_two,'ft0518-client2@example.test','FT05 Client Two','09180000002','client','Santa Ana','Pateros',true),
    (worker_one,'ft0518-worker@example.test','FT05 Worker','09180000003','worker','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES ('18181818-0000-4000-8000-000000000004',worker_one,'fixture','none','available',true);
END;
$$;

DO $$
DECLARE
  c1 uuid := '18181818-0000-4000-8000-000000000001';
  c2 uuid := '18181818-0000-4000-8000-000000000002';
  w1 uuid := '18181818-0000-4000-8000-000000000003';
  s text; before_tuple jsonb; completed_at_value timestamptz;
BEGIN
  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000001','18181818-2000-4000-8000-000000000001',c1,w1);
  s := pg_temp.state(format('SELECT public.complete_my_client_booking(%L)', '18181818-2000-4000-8000-000000000001'), c1);
  PERFORM pg_temp.pass(1,'confirmed unpaid owner completion is SM403',s='SM403',s);
  PERFORM pg_temp.pass(2,'unpaid denial mutates and notifies nothing',
    EXISTS(SELECT 1 FROM public.bookings b JOIN public.job_postings j ON j.id=b.job_id WHERE b.id='18181818-2000-4000-8000-000000000001' AND b.status='confirmed' AND j.status='matched')
    AND NOT EXISTS(SELECT 1 FROM public.notifications WHERE type='booking_completed'));

  UPDATE public.bookings SET payment_method='cod', payment_status='paid' WHERE id='18181818-2000-4000-8000-000000000001';
  SELECT jsonb_build_array(payment_method,payment_status,paymongo_ref) INTO before_tuple FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000001';
  s := pg_temp.state(format('SELECT public.complete_my_client_booking(%L)', '18181818-2000-4000-8000-000000000001'), c1);
  SELECT completed_at INTO completed_at_value FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000001';
  PERFORM pg_temp.pass(3,'confirmed paid owner completes atomically',s='00000' AND completed_at_value IS NOT NULL
    AND EXISTS(SELECT 1 FROM public.bookings b JOIN public.job_postings j ON j.id=b.job_id WHERE b.id='18181818-2000-4000-8000-000000000001' AND b.status='completed' AND j.status='completed'),s);
  PERFORM pg_temp.pass(4,'completion preserves payment tuple',before_tuple=(SELECT jsonb_build_array(payment_method,payment_status,paymongo_ref) FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000001'));
  PERFORM pg_temp.pass(5,'completion emits exactly one trusted notification',(SELECT count(*) FROM public.notifications WHERE user_id=w1 AND type='booking_completed')=1);
  s := pg_temp.state(format('SELECT public.complete_my_client_booking(%L)', '18181818-2000-4000-8000-000000000001'), c1);
  PERFORM pg_temp.pass(6,'repeat completion is SM409 with no duplicate notification',s='SM409' AND (SELECT count(*) FROM public.notifications WHERE user_id=w1 AND type='booking_completed')=1,s);
  s := pg_temp.state(format('SELECT public.complete_my_client_booking(%L)', '18181818-2000-4000-8000-000000000001'), w1);
  PERFORM pg_temp.pass(7,'Worker completion is 42501',s='42501',s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000002','18181818-2000-4000-8000-000000000002',c1,w1,'confirmed','matched','cod','paid',NULL,'cod');
  s := pg_temp.state(format('SELECT public.complete_my_client_booking(%L)', '18181818-2000-4000-8000-000000000002'), c2);
  PERFORM pg_temp.pass(8,'other Client receives collapsed SM409',s='SM409',s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000003','18181818-2000-4000-8000-000000000003',c1,w1,'confirmed','matched',NULL,'pending',NULL,'cod');
  s := pg_temp.state(format('SELECT public.select_my_booking_cod(%L)', '18181818-2000-4000-8000-000000000003'), c1);
  PERFORM pg_temp.pass(9,'Client selects COD while confirmed',s='00000' AND EXISTS(SELECT 1 FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000003' AND status='confirmed' AND payment_method='cod' AND payment_status='pending'),s);
  s := pg_temp.state(format('SELECT public.select_my_booking_cod(%L)', '18181818-2000-4000-8000-000000000003'), w1);
  PERFORM pg_temp.pass(10,'Worker cannot select COD',s='42501',s);
  s := pg_temp.state(format('SELECT public.confirm_my_cod_payment_received(%L)', '18181818-2000-4000-8000-000000000003'), c1);
  PERFORM pg_temp.pass(11,'Client cannot confirm COD',s='42501',s);
  s := pg_temp.state(format('SELECT public.confirm_my_cod_payment_received(%L)', '18181818-2000-4000-8000-000000000003'), w1);
  PERFORM pg_temp.pass(12,'assigned Worker settles confirmed COD',s='00000' AND EXISTS(SELECT 1 FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000003' AND status='confirmed' AND payment_status='paid'),s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000004','18181818-2000-4000-8000-000000000004',c1,w1,'completed','completed','cod','pending',NULL,'cod');
  s := pg_temp.state(format('SELECT public.confirm_my_cod_payment_received(%L)', '18181818-2000-4000-8000-000000000004'), w1);
  PERFORM pg_temp.pass(13,'legacy completed pending COD may settle',s='00000' AND (SELECT payment_status FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000004')='paid',s);
END;
$$;

DO $$
DECLARE
  c1 uuid := '18181818-0000-4000-8000-000000000001';
  w1 uuid := '18181818-0000-4000-8000-000000000003';
  s text;
BEGIN
  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000005','18181818-2000-4000-8000-000000000005',c1,w1,'confirmed','matched',NULL,'pending',NULL,'qrph');
  PERFORM pg_temp.pass(14,'confirmed QR Ph prepare succeeds',EXISTS(SELECT 1 FROM public.prepare_booking_qrph('18181818-2000-4000-8000-000000000005',c1)));
  PERFORM public.claim_and_bind_booking_qrph('18181818-2000-4000-8000-000000000005',c1,'pi_ft05_confirmed',50000,'PHP');
  PERFORM pg_temp.pass(15,'confirmed QR Ph bind preserves confirmed pending state',EXISTS(SELECT 1 FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000005' AND status='confirmed' AND payment_method='qrph' AND payment_status='pending' AND paymongo_ref='pi_ft05_confirmed'));
  PERFORM public.settle_booking_qrph('18181818-2000-4000-8000-000000000005','pi_ft05_confirmed',50000,'PHP','succeeded');
  PERFORM pg_temp.pass(16,'provider settlement pays confirmed Booking',EXISTS(SELECT 1 FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000005' AND status='confirmed' AND payment_status='paid'));

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000006','18181818-2000-4000-8000-000000000006',c1,w1,'confirmed','matched',NULL,'pending',NULL,NULL);
  s := pg_temp.state(format('SELECT public.cancel_my_booking(%L,%L,NULL)', '18181818-2000-4000-8000-000000000006','schedule_conflict'),c1);
  PERFORM pg_temp.pass(17,'fresh pending cancellation remains allowed',s='00000',s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000007','18181818-2000-4000-8000-000000000007',c1,w1,'confirmed','matched','cod','pending',NULL,'cod');
  s := pg_temp.state(format('SELECT public.cancel_my_booking(%L,%L,NULL)', '18181818-2000-4000-8000-000000000007','schedule_conflict'),c1);
  PERFORM pg_temp.pass(18,'COD pending cancellation remains allowed',s='00000',s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000008','18181818-2000-4000-8000-000000000008',c1,w1,'confirmed','matched','qrph','pending','pi_ft05_bound','qrph');
  s := pg_temp.state(format('SELECT public.cancel_my_booking(%L,%L,NULL)', '18181818-2000-4000-8000-000000000008','payment_issue'),c1);
  PERFORM pg_temp.pass(19,'bound QR Ph cancellation is SM403 and leaves rows unchanged',s='SM403' AND EXISTS(SELECT 1 FROM public.bookings b JOIN public.job_postings j ON j.id=b.job_id WHERE b.id='18181818-2000-4000-8000-000000000008' AND b.status='confirmed' AND j.status='matched'),s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000009','18181818-2000-4000-8000-000000000009',c1,w1,'confirmed','matched','cod','paid',NULL,'cod');
  s := pg_temp.state(format('SELECT public.cancel_my_booking(%L,%L,NULL)', '18181818-2000-4000-8000-000000000009','payment_issue'),c1);
  PERFORM pg_temp.pass(20,'paid cancellation is SM403',s='SM403',s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000010','18181818-2000-4000-8000-000000000010',c1,w1,'completed','completed','qrph','pending','pi_ft05_legacy','qrph');
  PERFORM public.settle_booking_qrph('18181818-2000-4000-8000-000000000010','pi_ft05_legacy',50000,'PHP','succeeded');
  PERFORM pg_temp.pass(21,'legacy completed pending QR Ph may settle',(SELECT payment_status FROM public.bookings WHERE id='18181818-2000-4000-8000-000000000010')='paid');

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000011','18181818-2000-4000-8000-000000000011',c1,w1,'cancelled','cancelled','qrph','pending','pi_ft05_cancelled','qrph');
  s := pg_temp.state(format('SELECT public.settle_booking_qrph(%L,%L,50000,%L,%L)', '18181818-2000-4000-8000-000000000011','pi_ft05_cancelled','PHP','succeeded'));
  PERFORM pg_temp.pass(22,'cancelled QR Ph cannot settle',s='SM409',s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000012','18181818-2000-4000-8000-000000000012',c1,w1,'no_show','cancelled','qrph','pending','pi_ft05_noshow','qrph');
  s := pg_temp.state(format('SELECT public.settle_booking_qrph(%L,%L,50000,%L,%L)', '18181818-2000-4000-8000-000000000012','pi_ft05_noshow','PHP','succeeded'));
  PERFORM pg_temp.pass(23,'no_show QR Ph cannot settle',s='SM409',s);

  PERFORM pg_temp.pair('18181818-1000-4000-8000-000000000013','18181818-2000-4000-8000-000000000013',c1,w1,'confirmed','matched',NULL,'pending','pi_malformed',NULL);
  s := pg_temp.state(format('SELECT public.cancel_my_booking(%L,%L,NULL)', '18181818-2000-4000-8000-000000000013','payment_issue'),c1);
  PERFORM pg_temp.pass(24,'malformed pending tuple fails cancellation closed',s='SM403',s);

  PERFORM pg_temp.pass(25,'authenticated cannot invoke provider settlement',
    NOT has_function_privilege('authenticated','public.settle_booking_qrph(uuid,text,bigint,text,text)','EXECUTE'));
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM ft05_18_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'FT-05 #18 failed % assertions',failed; END IF;
  RAISE NOTICE 'FT-05 #18: % assertions passed',(SELECT count(*) FROM ft05_18_results);
END;
$$;

ROLLBACK;
