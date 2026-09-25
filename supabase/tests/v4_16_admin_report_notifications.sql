-- V4 #16-N2-BE1 local SQL verification.
-- Disposable fixtures and the failure seam are enclosed by one transaction.
-- ROLLBACK restores the original database state and function body.

BEGIN;

CREATE TEMP TABLE v4_16_results (
  n integer,
  name text,
  ok boolean,
  detail text
);

GRANT INSERT ON v4_16_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(
  p_n integer,
  p_name text,
  p_ok boolean,
  p_detail text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO v4_16_results(n, name, ok, detail)
  VALUES (p_n, p_name, p_ok, p_detail);

  IF p_ok THEN
    RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE
    RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.jwt(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
    true
  );
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('role', 'authenticated', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.clear_jwt()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'postgres', true);
  RESET ROLE;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.booking_state(
  p_caller uuid,
  p_booking_id uuid,
  p_category text,
  p_description text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_state text := '00000';
BEGIN
  PERFORM pg_temp.jwt(p_caller);

  BEGIN
    PERFORM public.submit_my_booking_report(
      p_booking_id,
      p_category,
      p_description
    );
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

DO $$
DECLARE
  v_constraint text;
  v_booking regprocedure := 'public.submit_my_booking_report(uuid,text,text)'::regprocedure;
  v_app regprocedure := 'public.submit_my_app_issue(text)'::regprocedure;
BEGIN
  SELECT pg_get_constraintdef(c.oid, true)
    INTO v_constraint
  FROM pg_constraint AS c
  WHERE c.conrelid = 'public.notifications'::regclass
    AND c.conname = 'notifications_type_check'
    AND c.contype = 'c'
    AND c.convalidated;

  PERFORM pg_temp.pass(1, 'notification type CHECK contains exactly the approved nine values',
    v_constraint IS NOT NULL
    AND v_constraint LIKE '%booking_request%'
    AND v_constraint LIKE '%booking_confirmed%'
    AND v_constraint LIKE '%booking_cancelled%'
    AND v_constraint LIKE '%booking_completed%'
    AND v_constraint LIKE '%no_show_strike%'
    AND v_constraint LIKE '%account_suspended%'
    AND v_constraint LIKE '%payment_received%'
    AND v_constraint LIKE '%worker_verified%'
    AND v_constraint LIKE '%report_submitted%'
    AND (
      length(v_constraint) - length(replace(v_constraint, '::character varying', ''))
    ) / length('::character varying') = 9,
    coalesce(v_constraint, 'missing'));

  PERFORM pg_temp.pass(2, 'booking submission exposes only Booking/category/description input',
    pg_get_function_arguments(v_booking) =
      'p_booking_id uuid, p_category text, p_description text',
    pg_get_function_arguments(v_booking));

  PERFORM pg_temp.pass(3, 'app issue exposes only description input',
    pg_get_function_arguments(v_app) = 'p_description text',
    pg_get_function_arguments(v_app));

  PERFORM pg_temp.pass(4, 'booking submission return shape remains one report_id uuid',
    pg_get_function_result(v_booking) = 'TABLE(report_id uuid)',
    pg_get_function_result(v_booking));

  PERFORM pg_temp.pass(5, 'app issue return shape remains one report_id uuid',
    pg_get_function_result(v_app) = 'TABLE(report_id uuid)',
    pg_get_function_result(v_app));

  PERFORM pg_temp.pass(6, 'booking producer remains hardened and postgres-owned',
    EXISTS (
      SELECT 1
      FROM pg_proc AS p
      JOIN pg_roles AS r ON r.oid = p.proowner
      WHERE p.oid = v_booking
        AND p.prosecdef
        AND p.provolatile = 'v'
        AND p.proconfig = ARRAY['search_path=""']
        AND r.rolname = 'postgres'
    ));

  PERFORM pg_temp.pass(7, 'app producer remains hardened and postgres-owned',
    EXISTS (
      SELECT 1
      FROM pg_proc AS p
      JOIN pg_roles AS r ON r.oid = p.proowner
      WHERE p.oid = v_app
        AND p.prosecdef
        AND p.provolatile = 'v'
        AND p.proconfig = ARRAY['search_path=""']
        AND r.rolname = 'postgres'
    ));

  PERFORM pg_temp.pass(8, 'booking producer effective EXECUTE ACL is authenticated-only',
    has_function_privilege('authenticated', v_booking, 'EXECUTE')
    AND NOT has_function_privilege('anon', v_booking, 'EXECUTE')
    AND NOT has_function_privilege('service_role', v_booking, 'EXECUTE')
    AND NOT EXISTS (
      SELECT 1
      FROM pg_proc AS p,
           LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS acl
      WHERE p.oid = v_booking
        AND acl.grantee = 0
        AND acl.privilege_type = 'EXECUTE'
    ));

  PERFORM pg_temp.pass(9, 'app producer effective EXECUTE ACL is authenticated-only',
    has_function_privilege('authenticated', v_app, 'EXECUTE')
    AND NOT has_function_privilege('anon', v_app, 'EXECUTE')
    AND NOT has_function_privilege('service_role', v_app, 'EXECUTE')
    AND NOT EXISTS (
      SELECT 1
      FROM pg_proc AS p,
           LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS acl
      WHERE p.oid = v_app
        AND acl.grantee = 0
        AND acl.privilege_type = 'EXECUTE'
    ));

  PERFORM pg_temp.pass(10, 'no reports INSERT trigger exists',
    NOT EXISTS (
      SELECT 1
      FROM pg_trigger AS t
      WHERE t.tgrelid = 'public.reports'::regclass
        AND NOT t.tgisinternal
        AND (t.tgtype & 4) = 4
    ));

  PERFORM pg_temp.pass(11, 'notification table remains SELECT-only for authenticated',
    has_table_privilege('authenticated', 'public.notifications', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.notifications', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.notifications', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.notifications', 'DELETE'));

  PERFORM pg_temp.pass(12, 'recipient-owned mark-read RPC remains authenticated-only',
    has_function_privilege(
      'authenticated',
      'public.mark_my_notification_read(uuid)'::regprocedure,
      'EXECUTE'
    )
    AND NOT has_function_privilege(
      'anon',
      'public.mark_my_notification_read(uuid)'::regprocedure,
      'EXECUTE'
    ));
END;
$$;

DO $$
DECLARE
  worker_one uuid := '10000000-0000-4000-8000-000000000001';
  worker_two uuid := '10000000-0000-4000-8000-000000000002';
  client_one uuid := '20000000-0000-4000-8000-000000000001';
  admin_one uuid := '30000000-0000-4000-8000-000000000001';
  admin_two uuid := '30000000-0000-4000-8000-000000000002';
  admin_inactive uuid := '30000000-0000-4000-8000-000000000003';
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) VALUES
    ('00000000-0000-0000-0000-000000000000', worker_one, 'authenticated', 'authenticated', 'v416-worker1@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', worker_two, 'authenticated', 'authenticated', 'v416-worker2@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', client_one, 'authenticated', 'authenticated', 'v416-client@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', admin_one, 'authenticated', 'authenticated', 'v416-admin1@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', admin_two, 'authenticated', 'authenticated', 'v416-admin2@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', admin_inactive, 'authenticated', 'authenticated', 'v416-admin3@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES
    (worker_one, 'v416-worker1@example.test', 'V416 Worker One', '09160000001', 'worker', 'Santa Ana', 'Pateros', true),
    (worker_two, 'v416-worker2@example.test', 'V416 Worker Two', '09160000002', 'worker', 'Santa Ana', 'Pateros', true),
    (client_one, 'v416-client@example.test', 'V416 Client', '09160000003', 'client', 'Santa Ana', 'Pateros', true),
    (admin_one, 'v416-admin1@example.test', 'V416 Admin One', '09160000004', 'administrator', 'Santa Ana', 'Pateros', true),
    (admin_two, 'v416-admin2@example.test', 'V416 Admin Two', '09160000005', 'administrator', 'Santa Ana', 'Pateros', true),
    (admin_inactive, 'v416-admin3@example.test', 'V416 Admin Inactive', '09160000006', 'administrator', 'Santa Ana', 'Pateros', false);

  INSERT INTO public.worker_profiles (
    id, user_id, bio, badge_level, availability_status,
    is_verified, verified_by, rating_avg, strike_count
  ) VALUES
    ('40000000-0000-4000-8000-000000000001', worker_one, 'fixture', 'none', 'available', true, admin_one, 4, 1),
    ('40000000-0000-4000-8000-000000000002', worker_two, 'fixture', 'none', 'available', true, admin_one, 3, 0);

  INSERT INTO public.job_postings (
    id, client_id, title, description, address, barangay, city,
    scheduled_at, status, budget, payment_method
  ) VALUES (
    '50000000-0000-4000-8000-000000000001',
    client_one,
    'V416 Report Fixture',
    'Local-only fixture',
    'Fixture Street',
    'Santa Ana',
    'Pateros',
    now() + interval '1 day',
    'matched',
    500,
    'cod'
  );

  INSERT INTO public.bookings (
    id, job_id, worker_id, client_id, status, payment_method, payment_status
  ) VALUES (
    '60000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000001',
    worker_one,
    client_one,
    'confirmed',
    'cod',
    'pending'
  );
END;
$$;

CREATE TEMP TABLE v4_16_state_baseline AS
SELECT
  (SELECT to_jsonb(u) FROM public.users AS u WHERE u.id = '10000000-0000-4000-8000-000000000001') AS worker_user,
  (SELECT to_jsonb(wp) FROM public.worker_profiles AS wp WHERE wp.user_id = '10000000-0000-4000-8000-000000000001') AS worker_profile,
  (SELECT to_jsonb(b) FROM public.bookings AS b WHERE b.id = '60000000-0000-4000-8000-000000000001') AS booking_row,
  (SELECT to_jsonb(jp) FROM public.job_postings AS jp WHERE jp.id = '50000000-0000-4000-8000-000000000001') AS job_row,
  (SELECT count(*) FROM public.ratings) AS rating_count,
  (SELECT count(*) FROM public.worker_skills) AS worker_skill_count,
  (SELECT count(*) FROM public.job_skills) AS job_skill_count;

DO $$
DECLARE
  worker_one uuid := '10000000-0000-4000-8000-000000000001';
  worker_two uuid := '10000000-0000-4000-8000-000000000002';
  client_one uuid := '20000000-0000-4000-8000-000000000001';
  admin_one uuid := '30000000-0000-4000-8000-000000000001';
  admin_two uuid := '30000000-0000-4000-8000-000000000002';
  admin_inactive uuid := '30000000-0000-4000-8000-000000000003';
  v_booking_id uuid := '60000000-0000-4000-8000-000000000001';
  booking_report uuid;
  app_report uuid;
  zero_admin_report uuid;
  mark_notification uuid := '70000000-0000-4000-8000-000000000001';
  worker_notification uuid := '70000000-0000-4000-8000-000000000002';
  v_count integer;
  v_before integer;
  v_state text;
  v_mark_rows integer;
BEGIN
  PERFORM pg_temp.jwt(worker_one);
  SELECT report_id INTO booking_report
  FROM public.submit_my_booking_report(
    v_booking_id,
    '  safety  ',
    '  Booking report fixture  '
  );
  PERFORM pg_temp.clear_jwt();

  PERFORM pg_temp.pass(13, 'booking report returns its persisted report_id',
    booking_report IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.reports AS r
      WHERE r.id = booking_report
        AND r.reporter_id = worker_one
        AND r.booking_id = v_booking_id
        AND r.category = 'safety'
        AND r.description = 'Booking report fixture'
        AND r.status = 'submitted'
        AND r.admin_response IS NULL
        AND r.reviewed_by IS NULL
        AND r.reviewed_at IS NULL
    ));

  PERFORM pg_temp.pass(14, 'booking report derives the opposite participant',
    EXISTS (
      SELECT 1 FROM public.reports AS r
      WHERE r.id = booking_report
        AND r.reported_user_id = client_one
    ));

  SELECT count(*) INTO v_count
  FROM public.notifications AS n
  WHERE n.type = 'report_submitted'
    AND n.message = 'A new report needs Admin review.'
    AND n.user_id IN (admin_one, admin_two);
  PERFORM pg_temp.pass(15, 'booking report fans out to both active Admins',
    v_count = 2, 'count=' || v_count);

  PERFORM pg_temp.pass(16, 'booking fan-out is exactly once per active Admin',
    (SELECT count(*) FROM public.notifications WHERE user_id = admin_one AND type = 'report_submitted') = 1
    AND (SELECT count(*) FROM public.notifications WHERE user_id = admin_two AND type = 'report_submitted') = 1);

  PERFORM pg_temp.pass(17, 'booking fan-out content is fixed and privacy-safe',
    NOT EXISTS (
      SELECT 1 FROM public.notifications AS n
      WHERE n.user_id IN (admin_one, admin_two)
        AND (n.type IS DISTINCT FROM 'report_submitted'
          OR n.message IS DISTINCT FROM 'A new report needs Admin review.')
    ));

  PERFORM pg_temp.pass(18, 'inactive Admin is excluded',
    NOT EXISTS (
      SELECT 1 FROM public.notifications
      WHERE user_id = admin_inactive AND type = 'report_submitted'
    ));

  PERFORM pg_temp.pass(19, 'Worker and Client are excluded from Admin fan-out',
    NOT EXISTS (
      SELECT 1 FROM public.notifications
      WHERE user_id IN (worker_one, worker_two, client_one)
        AND type = 'report_submitted'
    ));

  PERFORM pg_temp.jwt(client_one);
  SELECT report_id INTO app_report
  FROM public.submit_my_app_issue('  App issue fixture  ');
  PERFORM pg_temp.clear_jwt();

  PERFORM pg_temp.pass(20, 'app issue preserves forced class and submitted lifecycle',
    app_report IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.reports AS r
      WHERE r.id = app_report
        AND r.reporter_id = client_one
        AND r.reported_user_id IS NULL
        AND r.booking_id IS NULL
        AND r.category = 'app_issue'
        AND r.description = 'App issue fixture'
        AND r.status = 'submitted'
        AND r.admin_response IS NULL
        AND r.reviewed_by IS NULL
        AND r.reviewed_at IS NULL
    ));

  SELECT count(*) INTO v_count
  FROM public.notifications AS n
  WHERE n.type = 'report_submitted'
    AND n.message = 'A new report needs Admin review.'
    AND n.user_id IN (admin_one, admin_two);
  PERFORM pg_temp.pass(21, 'app issue adds one fan-out row per active Admin',
    v_count = 4, 'combined_count=' || v_count);

  PERFORM pg_temp.pass(22, 'app issue fan-out remains exact trusted content',
    (SELECT count(*) FROM public.notifications WHERE user_id = admin_one AND type = 'report_submitted' AND message = 'A new report needs Admin review.') = 2
    AND (SELECT count(*) FROM public.notifications WHERE user_id = admin_two AND type = 'report_submitted' AND message = 'A new report needs Admin review.') = 2);

  UPDATE public.users
  SET is_active = false
  WHERE id IN (admin_one, admin_two);

  SELECT count(*) INTO v_before FROM public.notifications;
  PERFORM pg_temp.jwt(worker_one);
  SELECT report_id INTO zero_admin_report
  FROM public.submit_my_app_issue('Zero active Admin fixture');
  PERFORM pg_temp.clear_jwt();

  PERFORM pg_temp.pass(23, 'zero active Admins still allows report submission',
    zero_admin_report IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.reports WHERE id = zero_admin_report));

  SELECT count(*) INTO v_count FROM public.notifications;
  PERFORM pg_temp.pass(24, 'zero active Admins emits zero notifications',
    v_count = v_before, 'before=' || v_before || ',after=' || v_count);

  UPDATE public.users
  SET is_active = true
  WHERE id IN (admin_one, admin_two);

  SELECT count(*) INTO v_before FROM public.reports;
  v_state := pg_temp.booking_state(worker_two, v_booking_id, 'behavior', 'Not a participant');
  SELECT count(*) INTO v_count FROM public.reports;
  PERFORM pg_temp.pass(25, 'nonparticipant booking report remains collapsed SM409',
    v_state = 'SM409' AND v_count = v_before,
    'state=' || v_state || ',before=' || v_before || ',after=' || v_count);

  SELECT count(*) INTO v_before FROM public.notifications;
  v_state := pg_temp.booking_state(worker_one, v_booking_id, 'behavior', 'Duplicate');
  SELECT count(*) INTO v_count FROM public.notifications;
  PERFORM pg_temp.pass(26, 'duplicate active booking report remains SM409 with no notification',
    v_state = 'SM409' AND v_count = v_before,
    'state=' || v_state || ',before=' || v_before || ',after=' || v_count);

  SELECT count(*) INTO v_before FROM public.reports;
  v_state := pg_temp.booking_state(worker_one, v_booking_id, 'app_issue', 'Wrong RPC category');
  SELECT count(*) INTO v_count FROM public.reports;
  PERFORM pg_temp.pass(27, 'booking category validation remains 22023 with no report',
    v_state = '22023' AND v_count = v_before,
    'state=' || v_state || ',before=' || v_before || ',after=' || v_count);

  PERFORM pg_temp.pass(28, 'app issues remain repeatable',
    (SELECT count(*) FROM public.reports WHERE category = 'app_issue') = 2);

  INSERT INTO public.notifications (id, user_id, type, message)
  SELECT
    ('71000000-0000-4000-8000-' || lpad(gs::text, 12, '0'))::uuid,
    worker_one,
    t.notification_type,
    'Constraint fixture'
  FROM unnest(ARRAY[
    'booking_request',
    'booking_confirmed',
    'booking_cancelled',
    'booking_completed',
    'no_show_strike',
    'account_suspended',
    'payment_received',
    'worker_verified',
    'report_submitted'
  ]::text[]) WITH ORDINALITY AS t(notification_type, gs);

  PERFORM pg_temp.pass(29, 'new and all eight prior notification types are accepted',
    (SELECT count(*) FROM public.notifications WHERE message = 'Constraint fixture') = 9);

  v_state := '00000';
  BEGIN
    INSERT INTO public.notifications (user_id, type, message)
    VALUES (worker_one, 'unapproved_type', 'Must fail');
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  PERFORM pg_temp.pass(30, 'unapproved notification type is rejected',
    v_state = '23514', v_state);

  v_state := '00000';
  BEGIN
    PERFORM pg_temp.jwt(worker_one);
    INSERT INTO public.notifications (user_id, type, message)
    VALUES (worker_one, 'report_submitted', 'Caller controlled');
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(31, 'ordinary authenticated caller cannot INSERT notifications',
    v_state = '42501', v_state);

  INSERT INTO public.notifications (id, user_id, type, message)
  VALUES
    (mark_notification, admin_one, 'report_submitted', 'A new report needs Admin review.'),
    (worker_notification, worker_one, 'report_submitted', 'A new report needs Admin review.');

  v_state := '00000';
  BEGIN
    PERFORM pg_temp.jwt(worker_one);
    UPDATE public.notifications SET is_read = true WHERE id = worker_notification;
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(32, 'ordinary authenticated caller cannot directly UPDATE notifications',
    v_state = '42501', v_state);

  v_state := '00000';
  BEGIN
    PERFORM pg_temp.jwt(worker_one);
    DELETE FROM public.notifications WHERE id = worker_notification;
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(33, 'ordinary authenticated caller cannot DELETE notifications',
    v_state = '42501', v_state);

  PERFORM pg_temp.jwt(admin_two);
  SELECT count(*) INTO v_mark_rows
  FROM public.mark_my_notification_read(mark_notification);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(34, 'mark-read cannot affect another recipient row',
    v_mark_rows = 0
    AND EXISTS (
      SELECT 1 FROM public.notifications
      WHERE id = mark_notification AND NOT is_read
    ));

  PERFORM pg_temp.jwt(admin_one);
  SELECT count(*) INTO v_mark_rows
  FROM public.mark_my_notification_read(mark_notification)
  WHERE is_read;
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(35, 'mark-read still updates the owning recipient row only',
    v_mark_rows = 1
    AND EXISTS (
      SELECT 1 FROM public.notifications
      WHERE id = mark_notification AND is_read
    ));

  INSERT INTO private.user_devices (
    id, user_id, expo_push_token, platform, is_active
  ) VALUES (
    '72000000-0000-4000-8000-000000000001',
    admin_one,
    'ExponentPushToken[v416-admin-one]',
    'android',
    true
  );

  SET LOCAL ROLE service_role;
  SELECT count(*) INTO v_count
  FROM public.get_notification_push_targets(mark_notification) AS t
  WHERE t.notification_id = mark_notification
    AND t.notification_type = 'report_submitted'
    AND t.notification_message = 'A new report needs Admin review.'
    AND t.expo_push_token = 'ExponentPushToken[v416-admin-one]';
  RESET ROLE;
  PERFORM pg_temp.pass(36, 'existing push-target projection carries the new trusted content',
    v_count = 1, 'count=' || v_count);

  SET LOCAL ROLE service_role;
  SELECT count(*) INTO v_count
  FROM public.get_notification_push_targets(worker_notification);
  RESET ROLE;
  PERFORM pg_temp.pass(37, 'push targets remain recipient-device scoped',
    v_count = 0, 'count=' || v_count);

  PERFORM pg_temp.pass(38, 'worker strike_count is unchanged by submissions',
    (SELECT wp.strike_count FROM public.worker_profiles AS wp WHERE wp.user_id = worker_one) =
    (SELECT (worker_profile ->> 'strike_count')::integer FROM v4_16_state_baseline));

  PERFORM pg_temp.pass(39, 'users.is_active is unchanged after restored zero-Admin fixture',
    (SELECT to_jsonb(u) FROM public.users AS u WHERE u.id = worker_one) =
    (SELECT worker_user FROM v4_16_state_baseline));

  PERFORM pg_temp.pass(40, 'verification state is unchanged by submissions',
    (SELECT to_jsonb(wp) - ARRAY['strike_count'] FROM public.worker_profiles AS wp WHERE wp.user_id = worker_one) =
    (SELECT worker_profile - ARRAY['strike_count'] FROM v4_16_state_baseline));

  PERFORM pg_temp.pass(41, 'ratings state is unchanged by submissions',
    (SELECT count(*) FROM public.ratings) =
    (SELECT rating_count FROM v4_16_state_baseline));

  PERFORM pg_temp.pass(42, 'matching tables are unchanged by submissions',
    (SELECT count(*) FROM public.worker_skills) =
      (SELECT worker_skill_count FROM v4_16_state_baseline)
    AND (SELECT count(*) FROM public.job_skills) =
      (SELECT job_skill_count FROM v4_16_state_baseline));

  PERFORM pg_temp.pass(43, 'Booking status is unchanged by submissions',
    (SELECT b.status FROM public.bookings AS b WHERE b.id = v_booking_id) =
    (SELECT booking_row ->> 'status' FROM v4_16_state_baseline));

  PERFORM pg_temp.pass(44, 'Job status is unchanged by submissions',
    (SELECT jp.status FROM public.job_postings AS jp WHERE jp.id = '50000000-0000-4000-8000-000000000001') =
    (SELECT job_row ->> 'status' FROM v4_16_state_baseline));

  PERFORM pg_temp.pass(45, 'payment state is unchanged by submissions',
    EXISTS (
      SELECT 1
      FROM public.bookings AS b, v4_16_state_baseline AS s
      WHERE b.id = v_booking_id
        AND b.payment_method::text IS NOT DISTINCT FROM (s.booking_row ->> 'payment_method')
        AND b.payment_status::text IS NOT DISTINCT FROM (s.booking_row ->> 'payment_status')
        AND b.paymongo_ref IS NOT DISTINCT FROM (s.booking_row ->> 'paymongo_ref')
    ));

  PERFORM pg_temp.pass(46, 'full authoritative Booking and Job rows remain unchanged',
    (SELECT to_jsonb(b) FROM public.bookings AS b WHERE b.id = v_booking_id) =
      (SELECT booking_row FROM v4_16_state_baseline)
    AND (SELECT to_jsonb(jp) FROM public.job_postings AS jp WHERE jp.id = '50000000-0000-4000-8000-000000000001') =
      (SELECT job_row FROM v4_16_state_baseline));
END;
$$;

-- Local-only failure seam. CREATE OR REPLACE is transaction-scoped here;
-- final ROLLBACK restores the installed production definition.
CREATE OR REPLACE FUNCTION private.emit_notification(
  p_user_id uuid,
  p_type text,
  p_message text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF current_setting('v4_16.fail_recipient', true) = p_user_id::text THEN
    RAISE EXCEPTION 'V4 #16 local persistent notification failure seam'
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.notifications (user_id, type, message)
  VALUES (p_user_id, p_type, p_message);
END;
$$;

DO $$
DECLARE
  client_one uuid := '20000000-0000-4000-8000-000000000001';
  admin_one uuid := '30000000-0000-4000-8000-000000000001';
  admin_two uuid := '30000000-0000-4000-8000-000000000002';
  v_report_before integer;
  v_report_after integer;
  v_notification_before integer;
  v_notification_after integer;
  v_admin_one_before integer;
  v_admin_one_after integer;
  v_state text := '00000';
BEGIN
  SELECT count(*) INTO v_report_before FROM public.reports;
  SELECT count(*) INTO v_notification_before FROM public.notifications;
  SELECT count(*) INTO v_admin_one_before FROM public.notifications WHERE user_id = admin_one;

  PERFORM set_config('v4_16.fail_recipient', admin_two::text, true);
  PERFORM pg_temp.jwt(client_one);

  BEGIN
    PERFORM public.submit_my_app_issue('Atomic rollback failure fixture');
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;

  PERFORM pg_temp.clear_jwt();
  PERFORM set_config('v4_16.fail_recipient', '', true);

  SELECT count(*) INTO v_report_after FROM public.reports;
  SELECT count(*) INTO v_notification_after FROM public.notifications;
  SELECT count(*) INTO v_admin_one_after FROM public.notifications WHERE user_id = admin_one;

  PERFORM pg_temp.pass(47, 'required persistent notification failure propagates',
    v_state = '23514', v_state);

  PERFORM pg_temp.pass(48, 'notification failure rolls back the report INSERT',
    v_report_after = v_report_before,
    'before=' || v_report_before || ',after=' || v_report_after);

  PERFORM pg_temp.pass(49, 'notification failure rolls back every fan-out row',
    v_notification_after = v_notification_before
    AND v_admin_one_after = v_admin_one_before,
    'notifications=' || v_notification_before || '/' || v_notification_after
      || ',first_admin=' || v_admin_one_before || '/' || v_admin_one_after);
END;
$$;

SELECT n, name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail
FROM v4_16_results
ORDER BY n;

DO $$
DECLARE
  v_fail integer;
  v_total integer;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE NOT ok)
    INTO v_total, v_fail
  FROM v4_16_results;

  IF v_total <> 49 OR v_fail > 0 THEN
    RAISE EXCEPTION 'V4 #16 SQL tests failed: total %, failed %', v_total, v_fail;
  END IF;
END;
$$;

ROLLBACK;
