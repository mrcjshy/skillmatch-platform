-- NTF-01 local SQL verification: Administrator alerts for ID submissions and new accounts. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE ntf01_results (n integer, name text, ok boolean, detail text);

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ntf01_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_auth(p_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000',p_id,'authenticated','authenticated','ntf01-' || right(p_id::text, 2) || '@example.test',
          crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.count_for(p_user uuid, p_type text)
RETURNS integer LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.notifications WHERE user_id = p_user AND type = p_type;
$$;

DO $$
DECLARE
  admin_one uuid := '0f010101-0000-4000-8000-000000000001';
  admin_two uuid := '0f010101-0000-4000-8000-000000000002';
  admin_off uuid := '0f010101-0000-4000-8000-000000000003';
  worker_one uuid := '0f010101-0000-4000-8000-000000000004';
  client_one uuid := '0f010101-0000-4000-8000-000000000005';
  worker_two uuid := '0f010101-0000-4000-8000-000000000006';
  u uuid;
  msg text;
BEGIN
  -- Administrators exist before any registration in this fixture.
  FOREACH u IN ARRAY ARRAY[admin_one, admin_two, admin_off] LOOP PERFORM pg_temp.mk_auth(u); END LOOP;
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (admin_one,'ntf01-01@example.test','NTF01 Admin One','09190000201','administrator','Santa Ana','Pateros',true),
    (admin_two,'ntf01-02@example.test','NTF01 Admin Two','09190000202','administrator','Santa Ana','Pateros',true),
    (admin_off,'ntf01-03@example.test','NTF01 Inactive Admin','09190000203','administrator','Santa Ana','Pateros',false);

  PERFORM pg_temp.pass(1, 'three new types are allowed by the notifications CHECK',
    pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'notifications_type_check')) LIKE '%identity_submitted%'
    AND pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'notifications_type_check')) LIKE '%worker_registered%'
    AND pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'notifications_type_check')) LIKE '%client_registered%'
    AND pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'notifications_type_check')) LIKE '%account_reinstated%');
  PERFORM pg_temp.pass(2, 'registering an Administrator alerts nobody',
    (SELECT count(*) FROM public.notifications WHERE user_id IN (admin_one, admin_two, admin_off)) = 0);

  -- ---------- New accounts ----------
  PERFORM pg_temp.mk_auth(worker_one);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (worker_one,'ntf01-04@example.test','NTF01 Worker One','09190000204','worker','Santa Ana','Pateros',true);
  PERFORM pg_temp.pass(3, 'a new Worker alerts each active Administrator once',
    pg_temp.count_for(admin_one, 'worker_registered') = 1 AND pg_temp.count_for(admin_two, 'worker_registered') = 1);
  PERFORM pg_temp.pass(4, 'an inactive Administrator is not alerted', pg_temp.count_for(admin_off, 'worker_registered') = 0);
  SELECT message INTO msg FROM public.notifications WHERE user_id = admin_one AND type = 'worker_registered';
  PERFORM pg_temp.pass(5, 'the Worker alert names no one', msg = 'A new Worker account was created.', msg);
  PERFORM pg_temp.pass(6, 'the new Worker gets no alert', (SELECT count(*) FROM public.notifications WHERE user_id = worker_one) = 0);

  PERFORM pg_temp.mk_auth(client_one);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (client_one,'ntf01-05@example.test','NTF01 Client One','09190000205','client','Santa Ana','Pateros',true);
  SELECT message INTO msg FROM public.notifications WHERE user_id = admin_two AND type = 'client_registered';
  PERFORM pg_temp.pass(7, 'a new Client alerts each active Administrator with a fixed message',
    pg_temp.count_for(admin_one, 'client_registered') = 1 AND pg_temp.count_for(admin_two, 'client_registered') = 1
    AND msg = 'A new Client account was created.', msg);

  -- ---------- ID submissions ----------
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified)
  VALUES ('0f010101-1000-4000-8000-000000000004', worker_one, 'fixture', 'none', 'available', false);
  INSERT INTO private.worker_id_documents(worker_profile_id,user_id,id_type,storage_path,status)
  VALUES ('0f010101-1000-4000-8000-000000000004', worker_one, 'national_id', 'ntf01/first.jpg', 'pending');
  SELECT message INTO msg FROM public.notifications WHERE user_id = admin_one AND type = 'identity_submitted';
  PERFORM pg_temp.pass(8, 'a pending ID alerts each active Administrator with a fixed message',
    pg_temp.count_for(admin_one, 'identity_submitted') = 1 AND pg_temp.count_for(admin_two, 'identity_submitted') = 1
    AND pg_temp.count_for(admin_off, 'identity_submitted') = 0 AND msg = 'A Worker submitted an ID for review.', msg);

  UPDATE private.worker_id_documents SET status = 'superseded' WHERE user_id = worker_one;
  INSERT INTO private.worker_id_documents(worker_profile_id,user_id,id_type,storage_path,status)
  VALUES ('0f010101-1000-4000-8000-000000000004', worker_one, 'passport', 'ntf01/second.jpg', 'pending');
  PERFORM pg_temp.pass(9, 'a resubmitted ID alerts again; superseding the old one does not',
    pg_temp.count_for(admin_one, 'identity_submitted') = 2);

  INSERT INTO private.worker_id_documents(worker_profile_id,user_id,id_type,storage_path,status)
  VALUES ('0f010101-1000-4000-8000-000000000004', worker_one, 'umid', 'ntf01/approved.jpg', 'approved');
  PERFORM pg_temp.pass(10, 'a non-pending document row alerts nobody', pg_temp.count_for(admin_one, 'identity_submitted') = 2);

  -- ---------- A failed alert never blocks the user ----------
  ALTER TABLE public.notifications DROP CONSTRAINT notifications_type_check;
  ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type IN ('report_submitted')) NOT VALID;
  PERFORM pg_temp.mk_auth(worker_two);
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (worker_two,'ntf01-06@example.test','NTF01 Worker Two','09190000206','worker','Santa Ana','Pateros',true);
  PERFORM pg_temp.pass(11, 'registration still succeeds when the alert cannot be written',
    EXISTS (SELECT 1 FROM public.users WHERE id = worker_two) AND pg_temp.count_for(admin_one, 'worker_registered') = 1);
END;
$$;

DO $$
BEGIN
  PERFORM pg_temp.pass(12, 'trigger functions are SECURITY DEFINER with an empty search_path',
    (SELECT bool_and(prosecdef AND proconfig = ARRAY['search_path=""']) FROM pg_proc
      WHERE oid IN ('private.ntf01_notify_account_registered()'::regprocedure,
                    'private.ntf01_notify_identity_submitted()'::regprocedure)));
  PERFORM pg_temp.pass(13, 'trigger functions are not callable by API roles',
    NOT has_function_privilege('authenticated', 'private.ntf01_notify_account_registered()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'private.ntf01_notify_identity_submitted()', 'EXECUTE'));
  PERFORM pg_temp.pass(14, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM ntf01_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'NTF-01 failed % assertions', failed; END IF;
  RAISE NOTICE 'NTF-01: % assertions passed', (SELECT count(*) FROM ntf01_results);
END;
$$;

ROLLBACK;
