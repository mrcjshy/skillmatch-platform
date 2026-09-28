-- V4-4 Worker Profile Photos local SQL verification.
--
-- PROOF CLASS: bucket configuration and storage.objects RLS metadata.
-- This script performs no Storage API binary upload and no hosted action.
-- All fixtures and metadata writes are enclosed by a transaction that aborts.

BEGIN;

CREATE TEMP TABLE v4_4_results (
  n      int,
  name   text,
  ok     boolean,
  detail text
);

CREATE OR REPLACE FUNCTION pg_temp.pass(
  p_n int,
  p_name text,
  p_ok boolean,
  p_detail text DEFAULT ''
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO v4_4_results(n, name, ok, detail)
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

CREATE OR REPLACE FUNCTION pg_temp.mk_user(
  p_id uuid,
  p_email text,
  p_role text,
  p_active boolean
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    p_id,
    'authenticated',
    'authenticated',
    p_email,
    crypt('v4-4-local-only', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  );

  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_id,
    p_email,
    'V4-4 Fixture',
    '09' || substr(replace(p_id::text, '-', ''), 1, 9),
    p_role,
    'Santa Ana',
    'Pateros',
    p_active
  );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.avatar_path(p_worker_user_id uuid)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_worker_user_id::text || '/avatar'
$$;

CREATE OR REPLACE FUNCTION pg_temp.can_select(p_uid uuid, p_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_count
  FROM storage.objects
  WHERE bucket_id = 'worker-profile-photos' AND name = p_name;
  PERFORM pg_temp.clear_jwt();
  RETURN v_count = 1;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.can_insert(p_uid uuid, p_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  INSERT INTO storage.objects (bucket_id, name)
  VALUES ('worker-profile-photos', p_name);
  PERFORM pg_temp.clear_jwt();
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.can_delete(p_uid uuid, p_name text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  DELETE FROM storage.objects
  WHERE bucket_id = 'worker-profile-photos' AND name = p_name;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  PERFORM pg_temp.clear_jwt();
  RETURN v_count = 1;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RETURN false;
END;
$$;

DO $$
DECLARE
  worker_owner     uuid := '44000000-0000-4000-8000-000000000001';
  worker_other     uuid := '44000000-0000-4000-8000-000000000002';
  worker_upload    uuid := '44000000-0000-4000-8000-000000000003';
  worker_inactive  uuid := '44000000-0000-4000-8000-000000000004';
  client_confirmed uuid := '44100000-0000-4000-8000-000000000001';
  client_other     uuid := '44100000-0000-4000-8000-000000000002';
  client_inactive  uuid := '44100000-0000-4000-8000-000000000003';
  admin_user       uuid := '44200000-0000-4000-8000-000000000001';
  profile_owner    uuid := '44300000-0000-4000-8000-000000000001';
  profile_other    uuid := '44300000-0000-4000-8000-000000000002';
  profile_upload   uuid := '44300000-0000-4000-8000-000000000003';
  profile_inactive uuid := '44300000-0000-4000-8000-000000000004';
  job_confirmed    uuid := '44400000-0000-4000-8000-000000000001';
  booking_id       uuid := '44500000-0000-4000-8000-000000000001';
  path_owner       text;
  path_other       text;
  path_upload      text;
  path_inactive    text;
  v_count          int;
  v_seen           int;
  v_public         boolean;
  v_limit          bigint;
  v_mimes          text[];
  v_expected       text[] := ARRAY['image/jpeg', 'image/png', 'image/webp'];
  v_columns        text;
  v_status         text;
  v_ok             boolean;
BEGIN
  PERFORM pg_temp.mk_user(worker_owner, 'v4-4-owner@example.test', 'worker', true);
  PERFORM pg_temp.mk_user(worker_other, 'v4-4-other-worker@example.test', 'worker', true);
  PERFORM pg_temp.mk_user(worker_upload, 'v4-4-upload@example.test', 'worker', true);
  PERFORM pg_temp.mk_user(worker_inactive, 'v4-4-inactive-worker@example.test', 'worker', false);
  PERFORM pg_temp.mk_user(client_confirmed, 'v4-4-confirmed-client@example.test', 'client', true);
  PERFORM pg_temp.mk_user(client_other, 'v4-4-other-client@example.test', 'client', true);
  PERFORM pg_temp.mk_user(client_inactive, 'v4-4-inactive-client@example.test', 'client', false);
  PERFORM pg_temp.mk_user(admin_user, 'v4-4-admin@example.test', 'administrator', true);

  INSERT INTO public.worker_profiles (
    id, user_id, bio, badge_level, availability_status, is_verified, rating_avg
  ) VALUES
    (profile_owner, worker_owner, 'V4-4 owner', 'none', 'available', false, 0),
    (profile_other, worker_other, 'V4-4 other', 'none', 'available', false, 0),
    (profile_upload, worker_upload, 'V4-4 upload', 'none', 'available', false, 0),
    (profile_inactive, worker_inactive, 'V4-4 inactive', 'none', 'available', false, 0);

  INSERT INTO public.job_postings (
    id, client_id, title, description, address, barangay, city,
    status, budget, payment_method
  ) VALUES (
    job_confirmed, client_confirmed, 'V4-4 confirmed Job', 'fixture',
    'Fixture address', 'Santa Ana', 'Pateros', 'matched', 100, 'cod'
  );

  INSERT INTO public.bookings (id, job_id, worker_id, client_id, status)
  VALUES (booking_id, job_confirmed, worker_owner, client_confirmed, 'confirmed');

  path_owner := pg_temp.avatar_path(worker_owner);
  path_other := pg_temp.avatar_path(worker_other);
  path_upload := pg_temp.avatar_path(worker_upload);
  path_inactive := pg_temp.avatar_path(worker_inactive);

  PERFORM set_config('storage.allow_delete_query', 'true', true);

  INSERT INTO storage.objects (bucket_id, name) VALUES
    ('worker-profile-photos', path_owner),
    ('worker-profile-photos', path_other),
    ('worker-profile-photos', path_inactive),
    ('worker-profile-photos', worker_owner::text || '/avatar.jpg'),
    ('worker-profile-photos', worker_owner::text || '/extra/avatar'),
    ('worker-profile-photos', 'not-a-uuid/avatar');

  -- 1-4. Exact private bucket contract.
  SELECT count(*) INTO v_count
  FROM storage.buckets
  WHERE id = 'worker-profile-photos' AND name = 'worker-profile-photos';
  PERFORM pg_temp.pass(1, 'worker-profile-photos bucket exists exactly once',
    v_count = 1, 'count=' || v_count);

  SELECT public, file_size_limit, allowed_mime_types
    INTO v_public, v_limit, v_mimes
  FROM storage.buckets
  WHERE id = 'worker-profile-photos';
  PERFORM pg_temp.pass(2, 'worker-profile-photos bucket is private',
    v_public IS FALSE, 'public=' || coalesce(v_public::text, 'null'));
  PERFORM pg_temp.pass(3, 'worker-profile-photos limit is exactly 5 MiB',
    v_limit = 5242880, 'limit=' || coalesce(v_limit::text, 'null'));
  PERFORM pg_temp.pass(4, 'worker-profile-photos MIME allowlist is exact',
    v_mimes IS NOT NULL AND cardinality(v_mimes) = 3
      AND v_mimes @> v_expected AND v_expected @> v_mimes,
    'mimes=' || coalesce(array_to_string(v_mimes, ','), 'null'));

  -- 5-12. Active Worker owns only the exact extensionless canonical key.
  PERFORM pg_temp.pass(5, 'active Worker SELECT own avatar',
    pg_temp.can_select(worker_owner, path_owner));
  PERFORM pg_temp.pass(6, 'cross-Worker INSERT path substitution denied',
    NOT pg_temp.can_insert(worker_owner, path_upload));
  PERFORM pg_temp.pass(7, 'active Worker INSERT own avatar',
    pg_temp.can_insert(worker_upload, path_upload));
  PERFORM pg_temp.pass(8, 'cross-Worker SELECT denied',
    NOT pg_temp.can_select(worker_owner, path_other));
  PERFORM pg_temp.pass(9, 'extension-bearing avatar denied',
    NOT pg_temp.can_select(worker_owner, worker_owner::text || '/avatar.jpg'));
  PERFORM pg_temp.pass(10, 'extra path depth denied',
    NOT pg_temp.can_select(worker_owner, worker_owner::text || '/extra/avatar'));
  PERFORM pg_temp.pass(11, 'malformed UUID-like folder denied without cast failure',
    NOT pg_temp.can_select(worker_owner, 'not-a-uuid/avatar'));
  PERFORM pg_temp.pass(12, 'inactive Worker owner SELECT denied',
    NOT pg_temp.can_select(worker_inactive, path_inactive));

  -- 13-19. Active confirmed Client sees only the assigned Worker's exact key.
  PERFORM pg_temp.pass(13, 'confirmed assigned Client SELECT allowed',
    pg_temp.can_select(client_confirmed, path_owner));
  PERFORM pg_temp.pass(14, 'confirmed Client path substitution denied',
    NOT pg_temp.can_select(client_confirmed, path_other));
  PERFORM pg_temp.pass(15, 'unrelated Client SELECT denied',
    NOT pg_temp.can_select(client_other, path_owner));
  PERFORM pg_temp.pass(16, 'inactive Client SELECT denied',
    NOT pg_temp.can_select(client_inactive, path_owner));

  FOREACH v_status IN ARRAY ARRAY['pending', 'completed', 'cancelled', 'no_show']
  LOOP
    IF v_status = 'cancelled' THEN
      UPDATE public.bookings
      SET status = v_status,
          cancellation_reason_code = 'other',
          cancellation_reason_detail = 'V4-4 local fixture',
          cancelled_by = client_confirmed,
          cancelled_at = now()
      WHERE id = booking_id;
    ELSE
      UPDATE public.bookings
      SET status = v_status,
          cancellation_reason_code = NULL,
          cancellation_reason_detail = NULL,
          cancelled_by = NULL,
          cancelled_at = NULL
      WHERE id = booking_id;
    END IF;

    PERFORM pg_temp.pass(
      CASE v_status
        WHEN 'pending' THEN 17
        WHEN 'completed' THEN 18
        WHEN 'cancelled' THEN 19
        ELSE 20
      END,
      'assigned Client SELECT denied while Booking is ' || v_status,
      NOT pg_temp.can_select(client_confirmed, path_owner)
    );
  END LOOP;

  UPDATE public.bookings
  SET status = 'confirmed',
      cancellation_reason_code = NULL,
      cancellation_reason_detail = NULL,
      cancelled_by = NULL,
      cancelled_at = NULL
  WHERE id = booking_id;
  PERFORM pg_temp.pass(21, 'confirmed Client SELECT restored',
    pg_temp.can_select(client_confirmed, path_owner));

  -- 22-28. No Client writes, Admin special access, anon/public access, or UPDATE.
  PERFORM pg_temp.pass(22, 'Client INSERT denied',
    NOT pg_temp.can_insert(client_confirmed, client_confirmed::text || '/avatar'));
  PERFORM pg_temp.pass(23, 'Client DELETE denied',
    NOT pg_temp.can_delete(client_confirmed, path_owner));
  PERFORM pg_temp.pass(24, 'Admin SELECT denied',
    NOT pg_temp.can_select(admin_user, path_owner));
  PERFORM pg_temp.pass(25, 'Admin INSERT denied',
    NOT pg_temp.can_insert(admin_user, admin_user::text || '/avatar'));

  v_seen := -1;
  BEGIN
    SET LOCAL ROLE anon;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'worker-profile-photos' AND name = path_owner;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('worker-profile-photos', 'anonymous/avatar');
    RESET ROLE;
    PERFORM pg_temp.pass(26, 'anonymous SELECT and INSERT denied', false,
      'insert succeeded; seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.pass(26, 'anonymous SELECT and INSERT denied',
      SQLSTATE IN ('42501', 'P0001') AND v_seen <= 0,
      SQLSTATE || ' seen=' || v_seen);
  END;

  v_ok := false;
  BEGIN
    PERFORM pg_temp.jwt(worker_owner);
    SET LOCAL ROLE authenticated;
    UPDATE storage.objects
    SET metadata = '{"replacement":true}'::jsonb
    WHERE bucket_id = 'worker-profile-photos' AND name = path_owner;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    v_ok := v_count = 0;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    v_ok := SQLSTATE IN ('42501', 'P0001');
  END;
  PERFORM pg_temp.pass(27, 'UPDATE and Storage upsert authority absent', v_ok);

  PERFORM pg_temp.pass(28, 'active Worker DELETE own avatar',
    pg_temp.can_delete(worker_upload, path_upload));
  PERFORM pg_temp.pass(29, 'cross-Worker DELETE denied',
    NOT pg_temp.can_delete(worker_owner, path_other));
  PERFORM pg_temp.pass(30, 'inactive Worker DELETE denied',
    NOT pg_temp.can_delete(worker_inactive, path_inactive));

  -- 31-33. Policy surface is exactly four narrow authenticated policies.
  SELECT count(*) INTO v_count
  FROM pg_policy pol
  JOIN pg_class c ON c.oid = pol.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'storage' AND c.relname = 'objects'
    AND pol.polname IN (
      'Active workers can select own profile photo',
      'Active workers can upload own profile photo',
      'Active workers can delete own profile photo',
      'Confirmed clients can select assigned worker profile photo'
    );
  PERFORM pg_temp.pass(31, 'four V4-4 Storage policies present',
    v_count = 4, 'count=' || v_count);

  PERFORM pg_temp.pass(32, 'no V4-4 UPDATE policy', NOT EXISTS (
    SELECT 1
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'storage' AND c.relname = 'objects'
      AND pol.polcmd = 'w'
      AND (pg_get_expr(pol.polqual, pol.polrelid) ILIKE '%worker-profile-photos%'
        OR pg_get_expr(pol.polwithcheck, pol.polrelid) ILIKE '%worker-profile-photos%')
  ));

  SELECT count(*) INTO v_count
  FROM pg_policy pol
  JOIN pg_class c ON c.oid = pol.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'storage' AND c.relname = 'objects'
    AND pol.polname IN (
      'Active workers can select own profile photo',
      'Active workers can upload own profile photo',
      'Active workers can delete own profile photo',
      'Confirmed clients can select assigned worker profile photo'
    )
    AND pol.polroles = ARRAY['authenticated'::regrole::oid];
  PERFORM pg_temp.pass(33, 'all V4-4 policies target authenticated only',
    v_count = 4, 'count=' || v_count);

  -- 34-36. No application table/column or matching-model coupling.
  PERFORM pg_temp.pass(34, 'no profile-photo application table created', NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
      AND c.relname IN (
        'profile_photos', 'worker_profile_photos', 'worker_photos', 'avatars'
      )
  ));

  SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO v_columns
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname = 'worker_profiles'
    AND a.attnum > 0 AND NOT a.attisdropped;
  PERFORM pg_temp.pass(35, 'worker_profiles has no photo/image/avatar column',
    v_columns NOT ILIKE '%photo%'
      AND v_columns NOT ILIKE '%image%'
      AND v_columns NOT ILIKE '%avatar%',
    'columns=' || coalesce(v_columns, 'missing'));

  PERFORM pg_temp.pass(36, 'matching functions contain no profile-photo coupling',
    to_regprocedure('private.compute_job_matches(uuid)') IS NOT NULL
      AND to_regprocedure('public.match_workers_for_job(uuid)') IS NOT NULL
      AND to_regprocedure('public.list_my_job_opportunities()') IS NOT NULL
      AND pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure)
        NOT ILIKE '%worker-profile-photos%'
      AND pg_get_functiondef('public.match_workers_for_job(uuid)'::regprocedure)
        NOT ILIKE '%worker-profile-photos%'
      AND pg_get_functiondef('public.list_my_job_opportunities()'::regprocedure)
        NOT ILIKE '%worker-profile-photos%');
END;
$$;

SELECT n, name, ok, detail
FROM v4_4_results
ORDER BY n;

SELECT
  count(*) FILTER (WHERE ok) AS passed,
  count(*) FILTER (WHERE NOT ok) AS failed,
  count(*) AS total
FROM v4_4_results;

ABORT;

-- Migration bucket persists; transaction fixtures and object metadata do not.
SELECT
  (SELECT count(*) FROM storage.buckets
    WHERE id = 'worker-profile-photos') AS worker_profile_photo_buckets,
  (SELECT count(*) FROM storage.objects
    WHERE bucket_id = 'worker-profile-photos') AS worker_profile_photo_objects;
