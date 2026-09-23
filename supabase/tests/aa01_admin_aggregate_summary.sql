-- AA-01B local aggregate contract verification. Run against the local schema
-- with the AA-01B function available in the same transaction. All fixtures
-- and any temporary function installation are rolled back by ABORT.
BEGIN;

CREATE TEMP TABLE aa01_results (name text, ok boolean, detail text);

CREATE FUNCTION pg_temp.pass(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO aa01_results VALUES (p_name, p_ok, p_detail);
  RAISE NOTICE '%: % %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END,
    p_name, p_detail;
END;
$$;

CREATE FUNCTION pg_temp.jwt(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('role', 'authenticated', true);
END;
$$;

CREATE FUNCTION pg_temp.clear_jwt()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'postgres', true);
  RESET ROLE;
END;
$$;

CREATE FUNCTION pg_temp.mk_user(
  p_id uuid, p_email text, p_role text, p_active boolean, p_public boolean DEFAULT true
)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', p_id,
    'authenticated', 'authenticated', p_email,
    crypt('aa01-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );
  IF p_public THEN
    INSERT INTO public.users (
      id, email, full_name, phone, role, barangay, city, is_active
    ) VALUES (
      p_id, p_email, 'AA-01 Fixture', '09000000000', p_role,
      'Santa Ana', 'Pateros', p_active
    );
  END IF;
END;
$$;

DO $$
DECLARE
  v_admin         uuid := gen_random_uuid();
  v_inactive_admin uuid := gen_random_uuid();
  v_pending       uuid := gen_random_uuid();
  v_verified      uuid := gen_random_uuid();
  v_no_id         uuid := gen_random_uuid();
  v_no_profile    uuid := gen_random_uuid();
  v_client        uuid := gen_random_uuid();
  v_inactive_client uuid := gen_random_uuid();
  v_auth_only     uuid := gen_random_uuid();
  v_pending_profile uuid := gen_random_uuid();
  v_verified_profile uuid := gen_random_uuid();
  v_no_id_profile uuid := gen_random_uuid();
  v_skill_one     uuid := gen_random_uuid();
  v_skill_two     uuid := gen_random_uuid();
  v_job           uuid;
  v_booking       uuid;
  v_confirmed_booking uuid;
  v_first_job     uuid;
  v_before        jsonb;
  v_after         jsonb;
  v_summary       record;
  v_shape         text[];
  v_case          record;
  v_denied        boolean;
  v_row_count     bigint;
  v_i             integer;
BEGIN
  PERFORM pg_temp.mk_user(v_admin, 'aa01-admin@example.test', 'administrator', true);

  -- Empty application populations still yield one row and every fixed key.
  PERFORM pg_temp.jwt(v_admin);
  SET LOCAL ROLE authenticated;
  SELECT * INTO v_summary FROM public.get_admin_analytics_summary();
  SELECT count(*) INTO v_row_count FROM public.get_admin_analytics_summary();
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass('empty aggregate returns exactly one row', v_row_count = 1);
  PERFORM pg_temp.pass('empty data returns one zero-valued row',
    v_summary.as_of IS NOT NULL
    AND v_summary.total_workers = 0 AND v_summary.verified_workers = 0
    AND v_summary.pending_worker_verifications = 0
    AND v_summary.total_clients = 0 AND v_summary.completed_bookings = 0
    AND v_summary.reports_needing_attention = 0);
  PERFORM pg_temp.pass('empty fixed job and report buckets',
    v_summary.jobs_by_status = '{"open":0,"matched":0,"completed":0,"cancelled":0,"unset":0}'::jsonb
    AND v_summary.reports_by_status = '{"submitted":0,"under_review":0,"resolved":0,"dismissed":0}'::jsonb);
  PERFORM pg_temp.pass('empty fixed Booking and payment buckets',
    v_summary.bookings_by_status = '{"pending":0,"confirmed":0,"completed":0,"cancelled":0,"no_show":0}'::jsonb
    AND (SELECT count(*) FROM jsonb_each(v_summary.payments_by_method_status)) = 5
    AND (SELECT count(*) FROM jsonb_each(v_summary.payments_by_method_status) AS m
         CROSS JOIN LATERAL jsonb_each(m.value)) = 20
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_each(v_summary.payments_by_method_status) AS m
      CROSS JOIN LATERAL jsonb_each(m.value) AS s
      WHERE s.value <> '0'::jsonb));

  PERFORM pg_temp.mk_user(v_inactive_admin, 'aa01-inactive-admin@example.test',
    'administrator', false);
  PERFORM pg_temp.mk_user(v_pending, 'aa01-pending@example.test', 'worker', false);
  PERFORM pg_temp.mk_user(v_verified, 'aa01-verified@example.test', 'worker', false);
  PERFORM pg_temp.mk_user(v_no_id, 'aa01-no-id@example.test', 'worker', true);
  PERFORM pg_temp.mk_user(v_no_profile, 'aa01-no-profile@example.test', 'worker', true);
  PERFORM pg_temp.mk_user(v_client, 'aa01-client@example.test', 'client', true);
  PERFORM pg_temp.mk_user(v_inactive_client, 'aa01-inactive-client@example.test',
    'client', false);
  PERFORM pg_temp.mk_user(v_auth_only, 'aa01-auth-only@example.test',
    'worker', true, false);

  INSERT INTO public.worker_profiles (id, user_id, bio, badge_level,
    availability_status, is_verified)
  VALUES
    (v_pending_profile, v_pending, 'AA-01 pending', 'none', 'available', false),
    (v_verified_profile, v_verified, 'AA-01 verified', 'none', 'available', true),
    (v_no_id_profile, v_no_id, 'AA-01 no ID', 'none', 'available', false);

  INSERT INTO private.worker_id_documents (
    worker_profile_id, user_id, id_type, storage_path, status
  ) VALUES
    (v_pending_profile, v_pending, 'drivers_license',
     v_pending_profile::text || '/' || gen_random_uuid()::text || '.jpg', 'pending'),
    (v_pending_profile, v_pending, 'passport',
     v_pending_profile::text || '/' || gen_random_uuid()::text || '.jpg', 'rejected');

  -- Five real Booking rows exercise all lifecycle statuses, all current and
  -- legacy payment methods, and nullable payment fields. Posting-time intent
  -- is deliberately QR Ph on every Job so it cannot explain the cross-tab.
  FOR v_i IN 1..5 LOOP
    v_job := gen_random_uuid();
    v_booking := gen_random_uuid();
    INSERT INTO public.job_postings (
      id, client_id, title, description, barangay, city,
      status, budget, payment_method
    ) VALUES (
      v_job, v_client, 'AA-01 Job ' || v_i, 'Aggregate fixture',
      'Santa Ana', 'Pateros',
      CASE v_i WHEN 1 THEN 'open' WHEN 2 THEN 'matched'
        WHEN 3 THEN 'completed' ELSE 'cancelled' END,
      100, 'qrph'
    );
    INSERT INTO public.bookings (
      id, job_id, worker_id, client_id, status,
      payment_method, payment_status
    ) VALUES (
      v_booking, v_job, v_pending, v_client,
      CASE v_i WHEN 1 THEN 'pending' WHEN 2 THEN 'confirmed'
        WHEN 3 THEN 'completed' WHEN 4 THEN 'cancelled' ELSE 'no_show' END,
      CASE v_i WHEN 1 THEN NULL WHEN 2 THEN 'qrph'
        WHEN 3 THEN 'cod' WHEN 4 THEN 'gcash' ELSE 'maya' END,
      CASE v_i WHEN 3 THEN 'paid' WHEN 4 THEN 'refunded'
        WHEN 5 THEN NULL ELSE 'pending' END
    );
    IF v_i = 1 THEN v_first_job := v_job; END IF;
    IF v_i = 2 THEN v_confirmed_booking := v_booking; END IF;
  END LOOP;
  INSERT INTO public.job_postings (
    client_id, title, description, barangay, city, status, budget, payment_method
  ) VALUES (v_client, 'AA-01 legacy Job', 'Null status fixture',
    'Santa Ana', 'Pateros', NULL, 100, NULL);

  INSERT INTO public.reports (
    reporter_id, category, description, status, reviewed_by, reviewed_at,
    admin_response
  ) VALUES
    (v_client, 'app_issue', 'Submitted fixture', 'submitted', NULL, NULL, NULL),
    (v_client, 'app_issue', 'Review fixture', 'under_review', v_admin, now(), NULL),
    (v_client, 'app_issue', 'Resolved fixture', 'resolved', v_admin, now(), 'Resolved'),
    (v_client, 'app_issue', 'Dismissed fixture', 'dismissed', v_admin, now(), 'Dismissed');

  PERFORM pg_temp.jwt(v_admin);
  SET LOCAL ROLE authenticated;
  SELECT * INTO v_summary FROM public.get_admin_analytics_summary();
  SELECT array_agg(k ORDER BY k) INTO v_shape
  FROM jsonb_object_keys(to_jsonb(v_summary)) AS k;
  PERFORM pg_temp.clear_jwt();

  PERFORM pg_temp.pass('active Admin sees actual account totals',
    v_summary.total_workers = 4 AND v_summary.total_clients = 2
    AND v_summary.verified_workers = 1);
  PERFORM pg_temp.pass('pending ID review differs from unverified profiles',
    v_summary.pending_worker_verifications = 1
    AND (SELECT count(*) FROM public.users AS u
         JOIN public.worker_profiles AS wp ON wp.user_id = u.id
         WHERE u.role = 'worker' AND wp.is_verified IS DISTINCT FROM true) = 2);
  PERFORM pg_temp.pass('Job status includes nullable legacy bucket',
    v_summary.jobs_by_status = '{"open":1,"matched":1,"completed":1,"cancelled":2,"unset":1}'::jsonb);
  PERFORM pg_temp.pass('Booking lifecycle is separate from paid state',
    v_summary.bookings_by_status = '{"pending":1,"confirmed":1,"completed":1,"cancelled":1,"no_show":1}'::jsonb
    AND v_summary.completed_bookings = 1);
  PERFORM pg_temp.pass('payment matrix uses Booking state and legacy nulls',
    v_summary.payments_by_method_status #>> '{unset,pending}' = '1'
    AND v_summary.payments_by_method_status #>> '{qrph,pending}' = '1'
    AND v_summary.payments_by_method_status #>> '{cod,paid}' = '1'
    AND v_summary.payments_by_method_status #>> '{gcash,refunded}' = '1'
    AND v_summary.payments_by_method_status #>> '{maya,unset}' = '1'
    AND (SELECT sum(s.value::text::bigint)
         FROM jsonb_each(v_summary.payments_by_method_status) AS m
         CROSS JOIN LATERAL jsonb_each(m.value) AS s) = 5);
  PERFORM pg_temp.pass('report statuses and attention exclude strikes',
    v_summary.reports_by_status = '{"submitted":1,"under_review":1,"resolved":1,"dismissed":1}'::jsonb
    AND v_summary.reports_needing_attention = 2);
  PERFORM pg_temp.pass('response contains exactly ten aggregate fields plus as_of',
    v_shape = ARRAY[
      'as_of','bookings_by_status','completed_bookings','jobs_by_status',
      'payments_by_method_status','pending_worker_verifications',
      'reports_by_status','reports_needing_attention','total_clients',
      'total_workers','verified_workers']::text[]);
  PERFORM pg_temp.pass('no name, contact, ID, message, or report content leaks',
    to_jsonb(v_summary)::text NOT ILIKE '%aa01-%'
    AND to_jsonb(v_summary)::text NOT ILIKE '%09000000000%'
    AND to_jsonb(v_summary)::text NOT ILIKE '%Submitted fixture%');

  -- Multiple valid child rows must leave every aggregate unchanged.
  INSERT INTO public.skills (id, skill_name, category)
  VALUES (v_skill_one, 'AA-01 skill ' || v_skill_one, 'Test'),
         (v_skill_two, 'AA-01 skill ' || v_skill_two, 'Test');
  INSERT INTO public.worker_skills (worker_id, skill_id, proficiency_level)
  VALUES (v_pending_profile, v_skill_one, 'beginner'),
         (v_pending_profile, v_skill_two, 'expert');
  INSERT INTO public.job_skills (job_id, skill_id)
  VALUES (v_first_job, v_skill_one), (v_first_job, v_skill_two);
  INSERT INTO public.messages (booking_id, sender_id, content)
  VALUES (v_confirmed_booking, v_pending, 'AA-01 message one'),
         (v_confirmed_booking, v_client, 'AA-01 message two');

  PERFORM pg_temp.jwt(v_admin);
  SET LOCAL ROLE authenticated;
  SELECT to_jsonb(a) INTO v_after
  FROM public.get_admin_analytics_summary() AS a;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass('skills and messages do not multiply counts',
    to_jsonb(v_summary) - 'as_of' = v_after - 'as_of');

  -- Snapshot exact business rows before and after a further RPC read.
  SELECT jsonb_build_object(
    'users', (SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM public.users AS u),
    'profiles', (SELECT jsonb_agg(to_jsonb(wp) ORDER BY wp.id) FROM public.worker_profiles AS wp),
    'jobs', (SELECT jsonb_agg(to_jsonb(j) ORDER BY j.id) FROM public.job_postings AS j),
    'bookings', (SELECT jsonb_agg(to_jsonb(b) ORDER BY b.id) FROM public.bookings AS b),
    'reports', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM public.reports AS r),
    'documents', (SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id) FROM private.worker_id_documents AS d)
  ) INTO v_before;
  PERFORM pg_temp.jwt(v_admin);
  SET LOCAL ROLE authenticated;
  PERFORM public.get_admin_analytics_summary();
  PERFORM pg_temp.clear_jwt();
  SELECT jsonb_build_object(
    'users', (SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM public.users AS u),
    'profiles', (SELECT jsonb_agg(to_jsonb(wp) ORDER BY wp.id) FROM public.worker_profiles AS wp),
    'jobs', (SELECT jsonb_agg(to_jsonb(j) ORDER BY j.id) FROM public.job_postings AS j),
    'bookings', (SELECT jsonb_agg(to_jsonb(b) ORDER BY b.id) FROM public.bookings AS b),
    'reports', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM public.reports AS r),
    'documents', (SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id) FROM private.worker_id_documents AS d)
  ) INTO v_after;
  PERFORM pg_temp.pass('RPC changes no business rows', v_before = v_after);

  FOR v_case IN SELECT * FROM (VALUES
    ('signed out', NULL::uuid),
    ('Worker', v_pending),
    ('Client', v_client),
    ('Auth-only missing account', v_auth_only),
    ('inactive Admin', v_inactive_admin)
  ) AS c(name, uid) LOOP
    v_denied := false;
    BEGIN
      IF v_case.uid IS NULL THEN
        PERFORM pg_temp.clear_jwt();
        SET LOCAL ROLE anon;
      ELSE
        PERFORM pg_temp.jwt(v_case.uid);
        SET LOCAL ROLE authenticated;
      END IF;
      PERFORM public.get_admin_analytics_summary();
    EXCEPTION WHEN SQLSTATE '42501' THEN
      v_denied := true;
    END;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(v_case.name || ' denied with 42501', v_denied);
  END LOOP;

  v_denied := false;
  BEGIN
    PERFORM pg_temp.clear_jwt();
    SET LOCAL ROLE service_role;
    PERFORM public.get_admin_analytics_summary();
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_denied := true;
  END;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass('direct service_role EXECUTE denied with 42501', v_denied);
  PERFORM pg_temp.pass('only authenticated has EXECUTE',
    NOT has_function_privilege('anon', 'public.get_admin_analytics_summary()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.get_admin_analytics_summary()', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.get_admin_analytics_summary()', 'EXECUTE'));
  PERFORM pg_temp.pass('function metadata retains trusted read boundary',
    EXISTS (
      SELECT 1 FROM pg_proc AS p
      JOIN pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'get_admin_analytics_summary'
        AND p.pronargs = 0 AND p.proowner = 'postgres'::regrole
        AND p.provolatile = 's' AND p.prosecdef = true
        AND p.proconfig @> ARRAY['search_path=""']::text[]));
END;
$$;

DO $$
DECLARE v_fail bigint;
BEGIN
  SELECT count(*) INTO v_fail FROM aa01_results WHERE NOT ok OR ok IS NULL;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'AA-01B FAILED % case(s)', v_fail;
  END IF;
  RAISE NOTICE 'AA-01B % / % PASS',
    (SELECT count(*) FROM aa01_results WHERE ok),
    (SELECT count(*) FROM aa01_results);
END;
$$;

ABORT;
