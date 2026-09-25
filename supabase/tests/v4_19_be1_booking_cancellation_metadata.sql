-- V4 #19-BE1 local SQL verification.
--
-- Confirmed seams:
--   bookings cancellation-metadata schema coherence
--   reason-aware cancel_my_booking RPC and old-signature removal
--   Worker/Client participant booking-list metadata projection
--   lifecycle, payment, anti-oracle, ACL, notification, and privacy regression
--
-- Disposable fixtures only. ROLLBACK so nothing survives.

BEGIN;

CREATE TEMP TABLE v4_19_be1_results (
  n      integer,
  name   text,
  ok     boolean,
  detail text
);

GRANT INSERT ON v4_19_be1_results TO authenticated;

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
  INSERT INTO v4_19_be1_results(n, name, ok, detail)
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

CREATE OR REPLACE FUNCTION pg_temp.mk_pair(
  p_job_id uuid,
  p_booking_id uuid,
  p_client_id uuid,
  p_worker_id uuid,
  p_title text,
  p_booking_status text DEFAULT 'confirmed',
  p_job_status text DEFAULT 'matched',
  p_payment_status text DEFAULT 'pending'
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.job_postings (
    id, client_id, title, description, address, barangay, city,
    scheduled_at, status, budget, payment_method
  ) VALUES (
    p_job_id, p_client_id, p_title, 'V4 #19-BE1 fixture',
    '19 Fixture Street', 'Santa Ana', 'Pateros', now() + interval '1 day',
    p_job_status, 500, 'cod'
  );

  INSERT INTO public.bookings (
    id, job_id, worker_id, client_id, status, payment_status
  ) VALUES (
    p_booking_id, p_job_id, p_worker_id, p_client_id,
    p_booking_status, p_payment_status
  );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.cancel_sqlstate(
  p_caller uuid,
  p_booking_id uuid,
  p_reason_code text,
  p_reason_detail text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_state text := '00000';
BEGIN
  PERFORM pg_temp.jwt(p_caller);

  BEGIN
    PERFORM public.cancel_my_booking(
      p_booking_id,
      p_reason_code,
      p_reason_detail
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
  v_new_function oid;
BEGIN
  PERFORM pg_temp.pass(1, 'cancellation_reason_code column exists',
    EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'bookings'
        AND column_name = 'cancellation_reason_code'
        AND data_type = 'text'
        AND is_nullable = 'YES'
    ));

  PERFORM pg_temp.pass(2, 'cancellation_reason_detail column exists',
    EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'bookings'
        AND column_name = 'cancellation_reason_detail'
        AND data_type = 'text'
        AND is_nullable = 'YES'
    ));

  PERFORM pg_temp.pass(3, 'cancelled_by column exists',
    EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'bookings'
        AND column_name = 'cancelled_by'
        AND data_type = 'uuid'
        AND is_nullable = 'YES'
    ));

  PERFORM pg_temp.pass(4, 'cancelled_at column exists',
    EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'bookings'
        AND column_name = 'cancelled_at'
        AND data_type = 'timestamp with time zone'
        AND is_nullable = 'YES'
    ));

  SELECT pg_get_constraintdef(c.oid, true)
    INTO v_constraint
  FROM pg_constraint AS c
  WHERE c.conrelid = 'public.bookings'::regclass
    AND c.conname = 'bookings_cancellation_metadata_check'
    AND c.contype = 'c'
    AND c.convalidated;

  PERFORM pg_temp.pass(5, 'validated cancellation metadata coherence constraint exists',
    v_constraint IS NOT NULL,
    coalesce(v_constraint, 'missing'));

  PERFORM pg_temp.pass(6, 'no cancellation business table exists',
    to_regclass('public.cancellation_reasons') IS NULL
    AND to_regclass('public.booking_cancellations') IS NULL
    AND to_regclass('public.cancellation_events') IS NULL);

  v_new_function := to_regprocedure('public.cancel_my_booking(uuid,text,text)');

  PERFORM pg_temp.pass(7, 'reason-aware cancel function exists',
    v_new_function IS NOT NULL);

  PERFORM pg_temp.pass(8, 'old one-argument cancel function is absent',
    to_regprocedure('public.cancel_my_booking(uuid)') IS NULL);

  PERFORM pg_temp.pass(9, 'cancel function is hardened SECURITY DEFINER',
    EXISTS (
      SELECT 1
      FROM pg_proc AS p
      WHERE p.oid = v_new_function
        AND p.prosecdef
        AND p.provolatile = 'v'
        AND p.proconfig = ARRAY['search_path=""']
    ));

  PERFORM pg_temp.pass(10, 'authenticated can execute reason-aware cancel',
    v_new_function IS NOT NULL
    AND has_function_privilege(
      'authenticated',
      v_new_function,
      'EXECUTE'
    ));

  PERFORM pg_temp.pass(11, 'anon cannot execute reason-aware cancel',
    v_new_function IS NULL
    OR NOT has_function_privilege('anon', v_new_function, 'EXECUTE'));

  PERFORM pg_temp.pass(12, 'PUBLIC cannot execute reason-aware cancel',
    v_new_function IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM aclexplode(coalesce(
        (SELECT p.proacl FROM pg_proc AS p WHERE p.oid = v_new_function),
        acldefault('f', (SELECT p.proowner FROM pg_proc AS p WHERE p.oid = v_new_function))
      )) AS acl
      WHERE acl.grantee = 0
        AND acl.privilege_type = 'EXECUTE'
    ));

  PERFORM pg_temp.pass(13, 'authenticated still lacks direct Booking UPDATE',
    NOT has_table_privilege('authenticated', 'public.bookings', 'UPDATE'));

  PERFORM pg_temp.pass(14, 'Worker booking list appends cancellation metadata',
    pg_get_function_result('public.list_my_worker_bookings()'::regprocedure)
      LIKE '%client_phone text, cancellation_reason_code text, cancellation_reason_detail text, cancelled_by uuid, cancelled_at timestamp with time zone)');

  PERFORM pg_temp.pass(15, 'Client booking list appends cancellation metadata',
    pg_get_function_result('public.list_my_client_bookings()'::regprocedure)
      LIKE '%worker_rating_count integer, cancellation_reason_code text, cancellation_reason_detail text, cancelled_by uuid, cancelled_at timestamp with time zone)');

  PERFORM pg_temp.pass(16, 'Worker booking list remains hardened',
    EXISTS (
      SELECT 1 FROM pg_proc AS p
      WHERE p.oid = 'public.list_my_worker_bookings()'::regprocedure
        AND p.prosecdef
        AND p.provolatile = 's'
        AND p.proconfig = ARRAY['search_path=""']
    ));

  PERFORM pg_temp.pass(17, 'Client booking list remains hardened',
    EXISTS (
      SELECT 1 FROM pg_proc AS p
      WHERE p.oid = 'public.list_my_client_bookings()'::regprocedure
        AND p.prosecdef
        AND p.provolatile = 's'
        AND p.proconfig = ARRAY['search_path=""']
    ));

  PERFORM pg_temp.pass(18, 'authenticated retains Worker booking-list EXECUTE',
    has_function_privilege('authenticated', 'public.list_my_worker_bookings()', 'EXECUTE'));

  PERFORM pg_temp.pass(19, 'authenticated retains Client booking-list EXECUTE',
    has_function_privilege('authenticated', 'public.list_my_client_bookings()', 'EXECUTE'));
END;
$$;

DO $$
DECLARE
  client_one uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  client_two uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  worker_one uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  worker_two uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) VALUES
    ('00000000-0000-0000-0000-000000000000', client_one, 'authenticated', 'authenticated', 'v419-client1@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', client_two, 'authenticated', 'authenticated', 'v419-client2@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', worker_one, 'authenticated', 'authenticated', 'v419-worker1@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
    ('00000000-0000-0000-0000-000000000000', worker_two, 'authenticated', 'authenticated', 'v419-worker2@example.test', crypt('local-only', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES
    (client_one, 'v419-client1@example.test', 'V419 Client One', '09190000001', 'client', 'Santa Ana', 'Pateros', true),
    (client_two, 'v419-client2@example.test', 'V419 Client Two', '09190000002', 'client', 'Santa Ana', 'Pateros', true),
    (worker_one, 'v419-worker1@example.test', 'V419 Worker One', '09190000003', 'worker', 'Santa Ana', 'Pateros', true),
    (worker_two, 'v419-worker2@example.test', 'V419 Worker Two', '09190000004', 'worker', 'Santa Ana', 'Pateros', true);

  INSERT INTO public.worker_profiles (
    id, user_id, bio, badge_level, availability_status, is_verified
  ) VALUES
    ('cccccccc-cccc-4ccc-8ccc-cccccccccc01', worker_one, 'fixture', 'none', 'available', true),
    ('cccccccc-cccc-4ccc-8ccc-cccccccccc02', worker_two, 'fixture', 'none', 'available', true);
END;
$$;

DO $$
DECLARE
  client_one uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  worker_one uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  worker_two uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
  v_state text;
BEGIN
  -- Valid `other` with bounded trimmed detail.
  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd03',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03',
    client_one, worker_one, 'V419 Other Valid');
  v_state := pg_temp.cancel_sqlstate(
    client_one,
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03',
    'other',
    '  A reason outside the common codes  '
  );
  PERFORM pg_temp.pass(32, 'other with detail succeeds and normalizes',
    v_state = '00000'
    AND EXISTS (
      SELECT 1 FROM public.bookings AS b
      WHERE b.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03'
        AND b.cancellation_reason_code = 'other'
        AND b.cancellation_reason_detail = 'A reason outside the common codes'
    ), v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd04',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04',
    client_one, worker_one, 'V419 Other Null');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04', 'other', NULL);
  PERFORM pg_temp.pass(33, 'other without detail rejects', v_state = '22023', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd05',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05',
    client_one, worker_one, 'V419 Other Blank');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05', 'other', E' \t\n ');
  PERFORM pg_temp.pass(34, 'other with blank detail rejects', v_state = '22023', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd06',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee06',
    client_one, worker_one, 'V419 Null Reason');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee06', NULL, NULL);
  PERFORM pg_temp.pass(35, 'NULL reason rejects', v_state = '22023', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd07',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee07',
    client_one, worker_one, 'V419 Empty Reason');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee07', '', NULL);
  PERFORM pg_temp.pass(36, 'empty reason rejects', v_state = '22023', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd08',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08',
    client_one, worker_one, 'V419 Unknown Reason');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08', 'not_a_code', NULL);
  PERFORM pg_temp.pass(37, 'unknown reason rejects', v_state = '22023', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd09',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee09',
    client_one, worker_one, 'V419 Long Detail');
  v_state := pg_temp.cancel_sqlstate(
    client_one,
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee09',
    'unable_to_continue',
    repeat('x', 301)
  );
  PERFORM pg_temp.pass(38, 'detail over 300 characters rejects',
    v_state = '22023', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd10',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10',
    client_one, worker_one, 'V419 Anti Oracle');
  v_state := pg_temp.cancel_sqlstate(
    worker_two,
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10',
    'not_a_code',
    NULL
  );
  PERFORM pg_temp.pass(39, 'unrelated malformed request preserves SM409 anti-oracle',
    v_state = 'SM409', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd11',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee11',
    client_one, worker_one, 'V419 Pending', 'pending', 'matched');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee11', 'payment_issue');
  PERFORM pg_temp.pass(40, 'pending Booking cannot cancel', v_state = 'SM409', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd12',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee12',
    client_one, worker_one, 'V419 Completed', 'completed', 'completed');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee12', 'payment_issue');
  PERFORM pg_temp.pass(41, 'completed Booking cannot cancel', v_state = 'SM409', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd13',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee13',
    client_one, worker_one, 'V419 Legacy Cancelled', 'cancelled', 'cancelled');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee13', 'payment_issue');
  PERFORM pg_temp.pass(42, 'already-cancelled Booking cannot cancel',
    v_state = 'SM409', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd14',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee14',
    client_one, worker_one, 'V419 No Show', 'no_show', 'cancelled');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee14', 'payment_issue');
  PERFORM pg_temp.pass(43, 'no-show Booking cannot cancel', v_state = 'SM409', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd15',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee15',
    client_one, worker_one, 'V419 Job Inconsistent', 'confirmed', 'open');
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee15', 'payment_issue');
  PERFORM pg_temp.pass(44, 'inconsistent Job preserves SM409',
    v_state = 'SM409', v_state);

  PERFORM pg_temp.mk_pair(
    'dddddddd-dddd-4ddd-8ddd-dddddddddd16',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee16',
    client_one, worker_one, 'V419 Paid', 'confirmed', 'matched', 'paid');
  UPDATE public.bookings
  SET payment_method = 'cod'
  WHERE id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee16';
  v_state := pg_temp.cancel_sqlstate(
    client_one, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee16', 'payment_issue');
  PERFORM pg_temp.pass(45, 'settled payment preserves SM403',
    v_state = 'SM403', v_state);

  v_state := pg_temp.cancel_sqlstate(
    NULL, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10', 'payment_issue');
  PERFORM pg_temp.pass(46, 'signed-out caller receives 42501',
    v_state = '42501', v_state);

  BEGIN
    EXECUTE 'SELECT public.cancel_my_booking($1)'
      USING 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10'::uuid;
    PERFORM pg_temp.pass(47, 'old UUID-only call is unavailable', false, 'call succeeded');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.pass(47, 'old UUID-only call is unavailable',
      SQLSTATE = '42883', SQLSTATE);
  END;

  PERFORM pg_temp.pass(48, 'legacy cancelled row retains all-NULL metadata',
    EXISTS (
      SELECT 1 FROM public.bookings AS b
      WHERE b.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee13'
        AND b.status = 'cancelled'
        AND b.cancellation_reason_code IS NULL
        AND b.cancellation_reason_detail IS NULL
        AND b.cancelled_by IS NULL
        AND b.cancelled_at IS NULL
    ));

  BEGIN
    UPDATE public.bookings
    SET cancellation_reason_code = 'payment_issue'
    WHERE id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10';
    PERFORM pg_temp.pass(49, 'partial metadata bundle violates constraint', false, 'update succeeded');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.pass(49, 'partial metadata bundle violates constraint', true, SQLSTATE);
  END;

  BEGIN
    UPDATE public.bookings
    SET cancellation_reason_code = 'payment_issue',
        cancelled_by = client_one,
        cancelled_at = now()
    WHERE id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10';
    PERFORM pg_temp.pass(50, 'non-cancelled row rejects complete metadata', false, 'update succeeded');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.pass(50, 'non-cancelled row rejects complete metadata', true, SQLSTATE);
  END;

  BEGIN
    UPDATE public.bookings
    SET status = 'cancelled',
        cancellation_reason_code = 'payment_issue',
        cancelled_by = worker_two,
        cancelled_at = now()
    WHERE id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10';
    PERFORM pg_temp.pass(51, 'unrelated cancellation actor violates constraint', false, 'update succeeded');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.pass(51, 'unrelated cancellation actor violates constraint', true, SQLSTATE);
  END;

  PERFORM pg_temp.pass(52, 'rejected payloads leave Booking and Job unchanged',
    (SELECT count(*) FROM public.bookings AS b
     JOIN public.job_postings AS jp ON jp.id = b.job_id
     WHERE b.id IN (
       'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04',
       'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05',
       'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee06',
       'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee07',
       'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08',
       'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee09'
     )
       AND b.status = 'confirmed'
       AND jp.status = 'matched'
       AND b.cancellation_reason_code IS NULL
       AND b.cancelled_by IS NULL
       AND b.cancelled_at IS NULL) = 6);

  PERFORM pg_temp.pass(53, 'cancellation does not change rating or strike state',
    EXISTS (
      SELECT 1 FROM public.worker_profiles AS wp
      WHERE wp.user_id = worker_one
        AND wp.rating_avg = 0
        AND wp.strike_count = 0
    ));
END;
$$;

DO $$
DECLARE
  client_one uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  client_two uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  worker_one uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  worker_two uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
  job_client_cancel uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddd01';
  booking_client_cancel uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';
  job_worker_cancel uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddd02';
  booking_worker_cancel uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02';
  v_booking_status text;
  v_job_status text;
BEGIN
  PERFORM pg_temp.mk_pair(
    job_client_cancel, booking_client_cancel, client_one, worker_one,
    'V419 Client Cancel');

  PERFORM pg_temp.jwt(client_one);
  SELECT r.booking_status, r.job_status
    INTO v_booking_status, v_job_status
  FROM public.cancel_my_booking(
    booking_client_cancel,
    'schedule_conflict',
    '  Family schedule changed  '
  ) AS r;
  PERFORM pg_temp.clear_jwt();

  PERFORM pg_temp.pass(20, 'Client cancellation returns terminal states',
    v_booking_status = 'cancelled' AND v_job_status = 'cancelled');

  PERFORM pg_temp.pass(21, 'Client cancellation persists normalized reason',
    EXISTS (
      SELECT 1 FROM public.bookings AS b
      WHERE b.id = booking_client_cancel
        AND b.cancellation_reason_code = 'schedule_conflict'
        AND b.cancellation_reason_detail = 'Family schedule changed'
    ));

  PERFORM pg_temp.pass(22, 'Client cancellation actor is auth.uid()',
    (SELECT b.cancelled_by FROM public.bookings AS b WHERE b.id = booking_client_cancel) = client_one);

  PERFORM pg_temp.pass(23, 'Client cancellation uses database time',
    (SELECT b.cancelled_at IS NOT NULL FROM public.bookings AS b WHERE b.id = booking_client_cancel));

  PERFORM pg_temp.pass(24, 'Client cancellation preserves payment tuple',
    EXISTS (
      SELECT 1 FROM public.bookings AS b
      WHERE b.id = booking_client_cancel
        AND b.payment_method IS NULL
        AND b.payment_status = 'pending'
        AND b.paymongo_ref IS NULL
        AND b.completed_at IS NULL
    ));

  PERFORM pg_temp.pass(25, 'Client cancellation emits one fixed Worker notification',
    (SELECT count(*) FROM public.notifications AS n
     WHERE n.user_id = worker_one
       AND n.type = 'booking_cancelled'
       AND n.message = 'The booking for "V419 Client Cancel" has been cancelled.') = 1);

  PERFORM pg_temp.mk_pair(
    job_worker_cancel, booking_worker_cancel, client_one, worker_one,
    'V419 Worker Cancel');

  PERFORM pg_temp.jwt(worker_one);
  SELECT r.booking_status, r.job_status
    INTO v_booking_status, v_job_status
  FROM public.cancel_my_booking(
    booking_worker_cancel,
    'location_issue',
    '   '
  ) AS r;
  PERFORM pg_temp.clear_jwt();

  PERFORM pg_temp.pass(26, 'Worker cancellation returns terminal states',
    v_booking_status = 'cancelled' AND v_job_status = 'cancelled');

  PERFORM pg_temp.pass(27, 'Worker cancellation persists reason and null normalized detail',
    EXISTS (
      SELECT 1 FROM public.bookings AS b
      WHERE b.id = booking_worker_cancel
        AND b.cancellation_reason_code = 'location_issue'
        AND b.cancellation_reason_detail IS NULL
    ));

  PERFORM pg_temp.pass(28, 'Worker cancellation actor is auth.uid()',
    (SELECT b.cancelled_by FROM public.bookings AS b WHERE b.id = booking_worker_cancel) = worker_one);

  PERFORM pg_temp.pass(29, 'Worker cancellation populates database timestamp',
    (SELECT b.cancelled_at IS NOT NULL FROM public.bookings AS b WHERE b.id = booking_worker_cancel));

  PERFORM pg_temp.pass(30, 'Worker cancellation emits one fixed Client notification',
    (SELECT count(*) FROM public.notifications AS n
     WHERE n.user_id = client_one
       AND n.type = 'booking_cancelled'
       AND n.message = 'The booking for "V419 Worker Cancel" has been cancelled.') = 1);

  PERFORM pg_temp.pass(31, 'notifications contain no cancellation detail',
    NOT EXISTS (
      SELECT 1 FROM public.notifications AS n
      WHERE n.type = 'booking_cancelled'
        AND n.message ILIKE '%Family schedule changed%'
    ));
END;
$$;

DO $$
DECLARE
  client_one uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  client_two uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  worker_one uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  worker_two uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
  v_code text;
  v_detail text;
  v_actor uuid;
  v_cancelled_at timestamptz;
  v_name text;
  v_phone text;
  v_address text;
  v_barangay text;
  v_skills text[];
  v_verified boolean;
  v_rating numeric;
  v_rating_count integer;
  v_count integer;
BEGIN
  PERFORM pg_temp.jwt(worker_one);
  SELECT r.cancellation_reason_code, r.cancellation_reason_detail,
         r.cancelled_by, r.cancelled_at,
         r.client_full_name, r.client_phone, r.job_address
    INTO v_code, v_detail, v_actor, v_cancelled_at,
         v_name, v_phone, v_address
  FROM public.list_my_worker_bookings() AS r
  WHERE r.booking_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';

  PERFORM pg_temp.pass(54, 'Worker list returns exact new cancellation metadata',
    v_code = 'schedule_conflict'
    AND v_detail = 'Family schedule changed'
    AND v_actor = client_one
    AND v_cancelled_at = (
      SELECT b.cancelled_at FROM public.bookings AS b
      WHERE b.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'
    ));

  PERFORM pg_temp.pass(55, 'Worker cancelled history keeps contact and address suppressed',
    v_name IS NULL AND v_phone IS NULL AND v_address IS NULL);

  SELECT r.cancellation_reason_code, r.cancellation_reason_detail,
         r.cancelled_by, r.cancelled_at
    INTO v_code, v_detail, v_actor, v_cancelled_at
  FROM public.list_my_worker_bookings() AS r
  WHERE r.booking_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee13';
  PERFORM pg_temp.pass(56, 'Worker list returns legacy NULL metadata bundle',
    v_code IS NULL AND v_detail IS NULL AND v_actor IS NULL AND v_cancelled_at IS NULL);

  SELECT r.cancellation_reason_code, r.cancellation_reason_detail,
         r.cancelled_by, r.cancelled_at,
         r.client_full_name, r.client_phone, r.job_address
    INTO v_code, v_detail, v_actor, v_cancelled_at,
         v_name, v_phone, v_address
  FROM public.list_my_worker_bookings() AS r
  WHERE r.booking_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10';
  PERFORM pg_temp.pass(57, 'Worker confirmed projection remains visible with NULL metadata',
    v_code IS NULL AND v_detail IS NULL AND v_actor IS NULL AND v_cancelled_at IS NULL
    AND v_name = 'V419 Client One'
    AND v_phone = '09190000001'
    AND v_address = '19 Fixture Street');

  SELECT count(*) INTO v_count
  FROM public.list_my_worker_bookings() AS r
  WHERE r.booking_id IN (
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee11',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee12',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee14'
  )
    AND r.cancellation_reason_code IS NULL
    AND r.cancellation_reason_detail IS NULL
    AND r.cancelled_by IS NULL
    AND r.cancelled_at IS NULL;
  PERFORM pg_temp.pass(58, 'Worker list keeps non-cancelled metadata NULL',
    v_count = 4, v_count::text);
  PERFORM pg_temp.clear_jwt();

  PERFORM pg_temp.jwt(client_one);
  SELECT r.cancellation_reason_code, r.cancellation_reason_detail,
         r.cancelled_by, r.cancelled_at,
         r.worker_full_name, r.worker_phone, r.worker_barangay,
         r.worker_skills, r.worker_is_verified, r.worker_rating_avg,
         r.worker_rating_count, r.job_address
    INTO v_code, v_detail, v_actor, v_cancelled_at,
         v_name, v_phone, v_barangay, v_skills, v_verified, v_rating,
         v_rating_count, v_address
  FROM public.list_my_client_bookings() AS r
  WHERE r.booking_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02';

  PERFORM pg_temp.pass(59, 'Client list returns exact new cancellation metadata',
    v_code = 'location_issue'
    AND v_detail IS NULL
    AND v_actor = worker_one
    AND v_cancelled_at = (
      SELECT b.cancelled_at FROM public.bookings AS b
      WHERE b.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02'
    ));

  PERFORM pg_temp.pass(60, 'Client cancelled history keeps Worker profile and address suppressed',
    v_name IS NULL AND v_phone IS NULL AND v_barangay IS NULL
    AND v_skills IS NULL AND v_verified IS NULL AND v_rating IS NULL
    AND v_rating_count IS NULL AND v_address IS NULL);

  SELECT r.cancellation_reason_code, r.cancellation_reason_detail,
         r.cancelled_by, r.cancelled_at
    INTO v_code, v_detail, v_actor, v_cancelled_at
  FROM public.list_my_client_bookings() AS r
  WHERE r.booking_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee13';
  PERFORM pg_temp.pass(61, 'Client list returns legacy NULL metadata bundle',
    v_code IS NULL AND v_detail IS NULL AND v_actor IS NULL AND v_cancelled_at IS NULL);

  SELECT r.cancellation_reason_code, r.cancellation_reason_detail,
         r.cancelled_by, r.cancelled_at,
         r.worker_full_name, r.worker_phone, r.worker_barangay,
         r.worker_skills, r.worker_is_verified, r.worker_rating_avg,
         r.worker_rating_count, r.job_address
    INTO v_code, v_detail, v_actor, v_cancelled_at,
         v_name, v_phone, v_barangay, v_skills, v_verified, v_rating,
         v_rating_count, v_address
  FROM public.list_my_client_bookings() AS r
  WHERE r.booking_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10';
  PERFORM pg_temp.pass(62, 'Client confirmed projection remains visible with NULL metadata',
    v_code IS NULL AND v_detail IS NULL AND v_actor IS NULL AND v_cancelled_at IS NULL
    AND v_name = 'V419 Worker One'
    AND v_phone = '09190000003'
    AND v_barangay = 'Santa Ana'
    AND v_skills = '{}'::text[]
    AND v_verified
    AND v_rating IS NULL
    AND v_rating_count = 0
    AND v_address = '19 Fixture Street');
  PERFORM pg_temp.clear_jwt();

  PERFORM pg_temp.jwt(worker_two);
  SELECT count(*) INTO v_count
  FROM public.list_my_worker_bookings() AS r
  WHERE r.booking_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(63, 'unrelated Worker cannot read cancellation metadata',
    v_count = 0, v_count::text);

  PERFORM pg_temp.jwt(client_two);
  SELECT count(*) INTO v_count
  FROM public.list_my_client_bookings() AS r
  WHERE r.booking_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(64, 'unrelated Client cannot read cancellation metadata',
    v_count = 0, v_count::text);

  PERFORM pg_temp.pass(65, 'locked original 11-table ERD set remains present',
    (SELECT count(*)
     FROM pg_class AS c
     JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND c.relname = ANY (ARRAY[
         'bookings', 'job_postings', 'job_skills', 'messages',
         'notifications', 'portfolio_items', 'ratings', 'skills',
         'users', 'worker_profiles', 'worker_skills'
       ])) = 11);

  PERFORM pg_temp.pass(66, 'current public application table count remains 13',
    (SELECT count(*)
     FROM pg_class AS c
     JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'r') = 13);
END;
$$;

DO $$
DECLARE
  v_total integer;
  v_failed integer;
  v_detail text;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE NOT ok),
         string_agg(n::text || ':' || name || coalesce(' [' || nullif(detail, '') || ']', ''), '; ' ORDER BY n)
           FILTER (WHERE NOT ok)
    INTO v_total, v_failed, v_detail
  FROM v4_19_be1_results;

  IF v_total <> 66 OR v_failed <> 0 THEN
    RAISE EXCEPTION 'V4 #19-BE1 schema slice failed: %/% assertions failed: %',
      v_failed, v_total, coalesce(v_detail, 'assertion count mismatch');
  END IF;
END;
$$;

ROLLBACK;
