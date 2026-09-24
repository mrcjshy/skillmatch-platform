-- AA-05 source-only rehearsal. Run only after separately authorized migration installation.
-- Synthetic rows and temporary helpers are rolled back; DDL event-trigger sequences may advance.
BEGIN;
CREATE TEMP TABLE aa05_results (name text, ok boolean);
CREATE FUNCTION pg_temp.check(p_name text, p_ok boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO aa05_results VALUES (p_name, p_ok);
  IF p_ok IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'AA-05 failed: %', p_name; END IF;
END;
$$;
CREATE FUNCTION pg_temp.claim(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  PERFORM set_config('role', 'authenticated', true);
END;
$$;
CREATE FUNCTION pg_temp.clear_claim()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END;
$$;
CREATE FUNCTION pg_temp.fixture(p_id uuid, p_role text, p_active boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (instance_id, id, aud, role, email, created_at, updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000', p_id, 'authenticated', 'authenticated',
          p_id::text || '@aa05.test', now(), now());
  INSERT INTO public.users (id, email, full_name, phone, role, barangay, city, is_active, created_at)
  VALUES (p_id, p_id::text || '@aa05.test', 'AA-05 Fixture', '09000000000', p_role,
          'Santa Ana', 'Pateros', p_active, '2026-01-01 00:00:00+00');
END;
$$;

DO $$
DECLARE
  v_admin uuid := gen_random_uuid();
  v_inactive_admin uuid := gen_random_uuid();
  v_worker uuid := gen_random_uuid();
  v_no_profile uuid := gen_random_uuid();
  v_inactive_worker uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_inactive_client uuid := gen_random_uuid();
  v_missing uuid := gen_random_uuid();
  v_job_one uuid := gen_random_uuid();
  v_job_two uuid := gen_random_uuid();
  v_job_three uuid := gen_random_uuid();
  v_detail jsonb;
  v_state text;
  v_case record;
BEGIN
  PERFORM pg_temp.fixture(v_admin, 'administrator');
  PERFORM pg_temp.fixture(v_inactive_admin, 'administrator', false);
  PERFORM pg_temp.fixture(v_worker, 'worker');
  PERFORM pg_temp.fixture(v_no_profile, 'worker');
  PERFORM pg_temp.fixture(v_inactive_worker, 'worker', false);
  PERFORM pg_temp.fixture(v_client, 'client');
  PERFORM pg_temp.fixture(v_inactive_client, 'client', false);
  UPDATE public.users SET created_at = NULL WHERE id = v_inactive_client;
  INSERT INTO public.worker_profiles (user_id, is_verified, availability_status)
  VALUES (v_worker, NULL, NULL);

  INSERT INTO public.job_postings (id, client_id, title, status, payment_method)
  VALUES (v_job_one, v_client, 'AA-05 open', 'open', 'cod'),
         (v_job_two, v_client, 'AA-05 cancelled', 'cancelled', 'cod'),
         (v_job_three, v_client, 'AA-05 legacy unset', NULL, NULL);
  INSERT INTO public.bookings (job_id, worker_id, client_id, status)
  VALUES (v_job_one, v_worker, v_client, 'completed'),
         (v_job_two, v_worker, v_client, 'pending'),
         (v_job_three, v_no_profile, v_client, 'completed');

  PERFORM pg_temp.claim(v_admin);
  SELECT public.get_admin_user_detail(v_worker::text, 'worker') INTO v_detail;
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('active Admin Worker exact keys',
    jsonb_typeof(v_detail) = 'object' AND
    (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_detail) AS k) =
    ARRAY['availability_status','completed_bookings_count','created_at','full_name',
          'has_profile','is_active','is_verified','user_id']::text[]);
  PERFORM pg_temp.check('Worker profile nullable and completed-only count',
    v_detail->>'user_id' = v_worker::text
    AND v_detail->>'full_name' = 'AA-05 Fixture'
    AND v_detail->'is_active' = 'true'::jsonb
    AND jsonb_typeof(v_detail->'created_at') = 'string'
    AND v_detail->'has_profile' = 'true'::jsonb
    AND v_detail->'is_verified' = 'null'::jsonb
    AND v_detail->'availability_status' = 'null'::jsonb
    AND v_detail->'completed_bookings_count' = '1'::jsonb
    AND jsonb_typeof(v_detail->'completed_bookings_count') = 'number'
    AND (SELECT count(*) FROM public.users WHERE id = v_worker) = 1
    AND (SELECT count(*) FROM public.worker_profiles WHERE user_id = v_worker) = 1);
  PERFORM pg_temp.claim(v_admin);
  SELECT public.get_admin_user_detail(upper(v_worker::text), 'worker') INTO v_detail;
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('canonical uppercase hex accepted', v_detail->>'user_id' = v_worker::text);

  PERFORM pg_temp.claim(v_admin);
  SELECT public.get_admin_user_detail(v_no_profile::text, 'worker') INTO v_detail;
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('missing profile retained and count independent',
    v_detail->>'user_id' = v_no_profile::text
    AND v_detail->'has_profile' = 'false'::jsonb
    AND v_detail->'is_verified' = 'null'::jsonb
    AND v_detail->'availability_status' = 'null'::jsonb
    AND v_detail->'completed_bookings_count' = '1'::jsonb
    AND (SELECT count(*) FROM public.worker_profiles WHERE user_id = v_no_profile) = 0);

  PERFORM pg_temp.claim(v_admin);
  SELECT public.get_admin_user_detail(v_client::text, 'client') INTO v_detail;
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('active Admin Client exact keys',
    jsonb_typeof(v_detail) = 'object' AND
    (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_detail) AS k) =
    ARRAY['created_at','full_name','is_active','posted_jobs_count','user_id']::text[]);
  PERFORM pg_temp.check('Client all-status count includes NULL status',
    v_detail->>'user_id' = v_client::text
    AND v_detail->'posted_jobs_count' = '3'::jsonb
    AND jsonb_typeof(v_detail->'posted_jobs_count') = 'number'
    AND (SELECT count(*) FROM public.job_postings WHERE client_id = v_client AND status IS NULL) = 1);

  FOR v_case IN SELECT * FROM (VALUES
    ('inactive Worker', v_inactive_worker, 'worker'),
    ('inactive Client', v_inactive_client, 'client')
  ) AS x(name, uid, role) LOOP
    PERFORM pg_temp.claim(v_admin);
    SELECT public.get_admin_user_detail(v_case.uid::text, v_case.role) INTO v_detail;
    PERFORM pg_temp.clear_claim();
    PERFORM pg_temp.check(v_case.name || ' remains readable and false',
      v_detail->>'user_id' = v_case.uid::text AND v_detail->'is_active' = 'false'::jsonb);
    IF v_case.role = 'client' THEN
      PERFORM pg_temp.check('nullable joined date and zero count',
        v_detail->'created_at' = 'null'::jsonb AND v_detail->'posted_jobs_count' = '0'::jsonb);
    END IF;
  END LOOP;

  FOR v_case IN SELECT * FROM (VALUES
    ('nonexistent', v_missing::text, 'worker'),
    ('Worker as Client', v_worker::text, 'client'),
    ('Client as Worker', v_client::text, 'worker')
  ) AS x(name, uid, role) LOOP
    PERFORM pg_temp.claim(v_admin);
    SELECT public.get_admin_user_detail(v_case.uid, v_case.role) INTO v_detail;
    PERFORM pg_temp.clear_claim();
    PERFORM pg_temp.check(v_case.name || ' returns SQL NULL', v_detail IS NULL);
  END LOOP;

  FOR v_case IN SELECT * FROM (VALUES
    ('NULL user ID', NULL::text, 'worker'),
    ('NULL role', v_worker::text, NULL::text),
    ('malformed UUID', 'not-a-uuid', 'worker'),
    ('Postgres-acceptable noncanonical UUID', replace(v_worker::text, '-', ''), 'worker'),
    ('UUID with braces', '{' || v_worker::text || '}', 'worker'),
    ('UUID with whitespace', ' ' || v_worker::text, 'worker'),
    ('invalid role', v_worker::text, 'administrator')
  ) AS x(name, uid, role) LOOP
    v_state := NULL;
    PERFORM pg_temp.claim(v_admin);
    BEGIN
      PERFORM public.get_admin_user_detail(v_case.uid, v_case.role);
    EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE;
    END;
    PERFORM pg_temp.clear_claim();
    PERFORM pg_temp.check(v_case.name || ' returns 22023', v_state = '22023');
  END LOOP;

  FOR v_case IN SELECT * FROM (VALUES
    ('Worker', v_worker, v_client::text, 'client'),
    ('Client', v_client, v_worker::text, 'worker'),
    ('inactive Admin', v_inactive_admin, v_worker::text, 'worker'),
    ('signed out/no subject', NULL::uuid, v_worker::text, 'worker'),
    ('unauthorized malformed UUID', v_worker, 'bad', 'worker'),
    ('unauthorized invalid role', v_client, v_worker::text, 'administrator'),
    ('unauthorized NULL user ID', v_worker, NULL::text, 'worker'),
    ('unauthorized NULL role', v_client, v_worker::text, NULL::text),
    ('unauthorized NULL args', NULL::uuid, NULL::text, NULL::text)
  ) AS x(name, caller, uid, role) LOOP
    v_state := NULL;
    PERFORM pg_temp.claim(v_case.caller);
    BEGIN
      PERFORM public.get_admin_user_detail(v_case.uid, v_case.role);
    EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE;
    END;
    PERFORM pg_temp.clear_claim();
    PERFORM pg_temp.check(v_case.name || ' denied before validation', v_state = '42501');
  END LOOP;

  PERFORM pg_temp.check('narrow effective EXECUTE ACL',
    has_function_privilege('authenticated', 'public.get_admin_user_detail(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_admin_user_detail(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.get_admin_user_detail(text,text)', 'EXECUTE'));
  PERFORM pg_temp.check('owner, STABLE, definer, empty path, non-STRICT, single signature',
    (SELECT count(*) = 1 FROM pg_proc AS p
       JOIN pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'get_admin_user_detail'
        AND p.oid = 'public.get_admin_user_detail(text,text)'::regprocedure
        AND p.proowner = 'postgres'::regrole AND p.provolatile = 's'
        AND p.prosecdef AND NOT p.proisstrict
        AND p.proconfig @> ARRAY['search_path=""']::text[]));
  RAISE NOTICE 'AA-05 % source checks passed', (SELECT count(*) FROM aa05_results);
END;
$$;
ABORT;
