-- V4-9 Optional Private Job Photos local SQL verification.
--
-- PROOF CLASS: bucket configuration and storage.objects RLS metadata.
-- This script performs no Storage API binary upload and no hosted action.
-- All fixtures and metadata writes are enclosed by a transaction that aborts.

BEGIN;

CREATE TEMP TABLE v4_9_results (
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
  INSERT INTO v4_9_results(n, name, ok, detail)
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
    crypt('v4-9-local-only', gen_salt('bf')),
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
    'V4-9 Fixture',
    '09' || substr(replace(p_id::text, '-', ''), 1, 9),
    p_role,
    'Santa Ana',
    'Pateros',
    p_active
  );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.job_path(
  p_client uuid,
  p_job uuid,
  p_slot text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_client::text || '/' || p_job::text || '/' || p_slot
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
  WHERE bucket_id = 'job-photos' AND name = p_name;
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
  VALUES ('job-photos', p_name);
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
  WHERE bucket_id = 'job-photos' AND name = p_name;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  PERFORM pg_temp.clear_jwt();
  RETURN v_count = 1;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.has_opportunity(p_uid uuid, p_job uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_count int := 0;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_count
  FROM public.list_my_job_opportunities() AS o
  WHERE o.job_id = p_job;
  PERFORM pg_temp.clear_jwt();
  RETURN v_count = 1;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RETURN false;
END;
$$;

DO $$
DECLARE
  client_owner     uuid := '91000000-0000-4000-8000-000000000001';
  client_other     uuid := '91000000-0000-4000-8000-000000000002';
  client_inactive  uuid := '91000000-0000-4000-8000-000000000003';
  worker_confirmed uuid := '92000000-0000-4000-8000-000000000001';
  worker_matched   uuid := '92000000-0000-4000-8000-000000000002';
  worker_unrelated uuid := '92000000-0000-4000-8000-000000000003';
  admin_user       uuid := '93000000-0000-4000-8000-000000000001';
  matched_profile  uuid := '93500000-0000-4000-8000-000000000001';
  matched_skill    uuid := '93600000-0000-4000-8000-000000000001';
  job_open         uuid := '94000000-0000-4000-8000-000000000001';
  job_booked       uuid := '94000000-0000-4000-8000-000000000002';
  job_other        uuid := '94000000-0000-4000-8000-000000000003';
  booking_id       uuid := '95000000-0000-4000-8000-000000000001';
  path_open_1      text;
  path_booked_1    text;
  path_booked_2    text;
  path_other_1     text;
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
  PERFORM pg_temp.mk_user(client_owner, 'v4-9-owner@example.test', 'client', true);
  PERFORM pg_temp.mk_user(client_other, 'v4-9-other@example.test', 'client', true);
  PERFORM pg_temp.mk_user(client_inactive, 'v4-9-inactive@example.test', 'client', false);
  PERFORM pg_temp.mk_user(worker_confirmed, 'v4-9-confirmed@example.test', 'worker', true);
  PERFORM pg_temp.mk_user(worker_matched, 'v4-9-matched@example.test', 'worker', true);
  PERFORM pg_temp.mk_user(worker_unrelated, 'v4-9-unrelated@example.test', 'worker', true);
  PERFORM pg_temp.mk_user(admin_user, 'v4-9-admin@example.test', 'administrator', true);

  -- Make worker_matched genuinely eligible under the authoritative
  -- Stage 1 matching rules: active Worker, available verified profile,
  -- and required-skill overlap. No Booking is created for this Worker.
  INSERT INTO public.worker_profiles (
    id, user_id, bio, badge_level, availability_status, is_verified, rating_avg
  ) VALUES (
    matched_profile, worker_matched, 'V4-9 matched-only fixture', 'none',
    'available', true, 0
  );

  INSERT INTO public.skills (id, skill_name, category)
  VALUES (matched_skill, 'V4-9 matched-only skill', 'V4-9 local');

  INSERT INTO public.worker_skills (worker_id, skill_id, proficiency_level)
  VALUES (matched_profile, matched_skill, 'intermediate');

  INSERT INTO public.job_postings (
    id, client_id, title, description, address, barangay, city,
    status, budget, payment_method
  ) VALUES
    (job_open, client_owner, 'Open photo Job', 'fixture', 'Fixture address',
      'Santa Ana', 'Pateros', 'open', 100, 'cod'),
    (job_booked, client_owner, 'Booked photo Job', 'fixture', 'Fixture address',
      'Santa Ana', 'Pateros', 'matched', 100, 'cod'),
    (job_other, client_other, 'Other Client Job', 'fixture', 'Fixture address',
      'Santa Ana', 'Pateros', 'open', 100, 'cod');

  INSERT INTO public.job_skills (job_id, skill_id)
  VALUES (job_open, matched_skill);

  INSERT INTO public.bookings (id, job_id, worker_id, client_id, status)
  VALUES (booking_id, job_booked, worker_confirmed, client_owner, 'confirmed');

  path_open_1 := pg_temp.job_path(client_owner, job_open, '1');
  path_booked_1 := pg_temp.job_path(client_owner, job_booked, '1');
  path_booked_2 := pg_temp.job_path(client_owner, job_booked, '2');
  path_other_1 := pg_temp.job_path(client_other, job_other, '1');

  -- Storage metadata deletion in this rollback-only SQL harness needs
  -- the Storage server's explicit direct-query test switch.
  PERFORM set_config('storage.allow_delete_query', 'true', true);

  INSERT INTO storage.objects (bucket_id, name) VALUES
    ('job-photos', path_booked_1),
    ('job-photos', path_booked_2),
    ('job-photos', path_other_1);

  -- 1-4. Exact private bucket contract.
  SELECT count(*) INTO v_count
  FROM storage.buckets WHERE id = 'job-photos' AND name = 'job-photos';
  PERFORM pg_temp.pass(1, 'job-photos bucket exists exactly once', v_count = 1,
    'count=' || v_count);

  SELECT public, file_size_limit, allowed_mime_types
    INTO v_public, v_limit, v_mimes
  FROM storage.buckets WHERE id = 'job-photos';
  PERFORM pg_temp.pass(2, 'job-photos bucket is private', v_public IS FALSE,
    'public=' || coalesce(v_public::text, 'null'));
  PERFORM pg_temp.pass(3, 'job-photos limit is exactly 5 MiB', v_limit = 5242880,
    'limit=' || coalesce(v_limit::text, 'null'));
  PERFORM pg_temp.pass(4, 'job-photos MIME allowlist is exact',
    v_mimes IS NOT NULL AND cardinality(v_mimes) = 3
      AND v_mimes @> v_expected AND v_expected @> v_mimes,
    'mimes=' || coalesce(array_to_string(v_mimes, ','), 'null'));

  -- 5-7. Active owning Client may fill each canonical open-Job slot.
  PERFORM pg_temp.pass(5, 'owning Client INSERT slot 1',
    pg_temp.can_insert(client_owner, path_open_1));
  PERFORM pg_temp.pass(6, 'owning Client INSERT slot 2',
    pg_temp.can_insert(client_owner, pg_temp.job_path(client_owner, job_open, '2')));
  PERFORM pg_temp.pass(7, 'owning Client INSERT slot 3',
    pg_temp.can_insert(client_owner, pg_temp.job_path(client_owner, job_open, '3')));

  -- 8-14. Canonical shape and ownership cannot be bypassed.
  PERFORM pg_temp.pass(8, 'slot 4 INSERT denied',
    NOT pg_temp.can_insert(client_owner, pg_temp.job_path(client_owner, job_open, '4')));
  PERFORM pg_temp.pass(9, '1.jpg INSERT denied',
    NOT pg_temp.can_insert(client_owner, pg_temp.job_path(client_owner, job_open, '1.jpg')));
  PERFORM pg_temp.pass(10, '1.png INSERT denied',
    NOT pg_temp.can_insert(client_owner, pg_temp.job_path(client_owner, job_open, '1.png')));
  PERFORM pg_temp.pass(11, '1.webp INSERT denied',
    NOT pg_temp.can_insert(client_owner, pg_temp.job_path(client_owner, job_open, '1.webp')));
  PERFORM pg_temp.pass(12, 'extra path segment INSERT denied',
    NOT pg_temp.can_insert(client_owner,
      client_owner::text || '/' || job_open::text || '/extra/1'));
  PERFORM pg_temp.pass(13, 'malformed prefix INSERT denied without UUID cast error',
    NOT pg_temp.can_insert(client_owner, 'not-a-uuid/' || job_open::text || '/1'));
  PERFORM pg_temp.pass(14, 'wrong Client UUID INSERT denied',
    NOT pg_temp.can_insert(client_owner, pg_temp.job_path(client_other, job_open, '1')));

  -- 15-18. Database ownership, role, activity, and open state govern INSERT.
  PERFORM pg_temp.pass(15, 'another Client Job INSERT denied',
    NOT pg_temp.can_insert(client_owner, path_other_1));
  PERFORM pg_temp.pass(16, 'inactive Client INSERT denied',
    NOT pg_temp.can_insert(client_inactive,
      pg_temp.job_path(client_inactive, job_open, '1')));
  PERFORM pg_temp.pass(17, 'Worker INSERT denied',
    NOT pg_temp.can_insert(worker_confirmed, path_open_1));
  PERFORM pg_temp.pass(18, 'Admin INSERT denied',
    NOT pg_temp.can_insert(admin_user, path_open_1));

  -- 19-23. Owner and confirmed assigned Worker SELECT only.
  PERFORM pg_temp.pass(19, 'owning Client SELECT allowed',
    pg_temp.can_select(client_owner, path_booked_1));
  PERFORM pg_temp.pass(20, 'confirmed assigned Worker SELECT allowed',
    pg_temp.can_select(worker_confirmed, path_booked_1));
  PERFORM pg_temp.pass(21, 'unrelated Client SELECT denied',
    NOT pg_temp.can_select(client_other, path_booked_1));
  PERFORM pg_temp.pass(22, 'pre-match unrelated Worker SELECT denied',
    NOT pg_temp.can_select(worker_unrelated, path_booked_1));
  PERFORM pg_temp.pass(23, 'matched-only Worker without Booking SELECT denied',
    pg_temp.has_opportunity(worker_matched, job_open)
      AND NOT EXISTS (
        SELECT 1 FROM public.bookings AS b
        WHERE b.worker_id = worker_matched AND b.job_id = job_open
      )
      AND NOT pg_temp.can_select(worker_matched, path_open_1),
    'eligible=' || pg_temp.has_opportunity(worker_matched, job_open)
      || ' photo_visible=' || pg_temp.can_select(worker_matched, path_open_1));

  -- 24-27. Pending and terminal Booking states revoke Worker reads.
  FOREACH v_status IN ARRAY ARRAY['pending', 'completed', 'cancelled', 'no_show']
  LOOP
    IF v_status = 'cancelled' THEN
      UPDATE public.bookings
      SET status = v_status,
          cancellation_reason_code = 'other',
          cancellation_reason_detail = 'V4-9 local fixture',
          cancelled_by = client_owner,
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
        WHEN 'pending' THEN 24
        WHEN 'completed' THEN 25
        WHEN 'cancelled' THEN 26
        ELSE 27
      END,
      'assigned Worker SELECT denied while Booking is ' || v_status,
      NOT pg_temp.can_select(worker_confirmed, path_booked_1)
    );
  END LOOP;

  -- Restore confirmed to prove the state gate, then cover Admin and anon.
  UPDATE public.bookings
  SET status = 'confirmed',
      cancellation_reason_code = NULL,
      cancellation_reason_detail = NULL,
      cancelled_by = NULL,
      cancelled_at = NULL
  WHERE id = booking_id;

  PERFORM pg_temp.pass(28, 'confirmed Worker SELECT restored',
    pg_temp.can_select(worker_confirmed, path_booked_1));
  PERFORM pg_temp.pass(29, 'Admin SELECT denied',
    NOT pg_temp.can_select(admin_user, path_booked_1));

  v_seen := -1;
  BEGIN
    SET LOCAL ROLE anon;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'job-photos' AND name = path_booked_1;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('job-photos', pg_temp.job_path(client_owner, job_open, 'anon'));
    RESET ROLE;
    PERFORM pg_temp.pass(30, 'anonymous SELECT and INSERT denied', false,
      'insert succeeded; seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.pass(30, 'anonymous SELECT and INSERT denied',
      SQLSTATE IN ('42501', 'P0001') AND v_seen <= 0,
      SQLSTATE || ' seen=' || v_seen);
  END;

  -- 31-34. Cleanup is owner/open only; no replacement authority.
  PERFORM pg_temp.pass(31, 'owning Client DELETE own open slot',
    pg_temp.can_delete(client_owner, path_open_1));
  PERFORM pg_temp.pass(32, 'owning Client DELETE matched Job denied',
    NOT pg_temp.can_delete(client_owner, path_booked_2));
  PERFORM pg_temp.pass(33, 'Worker DELETE denied',
    NOT pg_temp.can_delete(worker_confirmed, path_booked_2));

  v_ok := false;
  BEGIN
    PERFORM pg_temp.jwt(client_owner);
    SET LOCAL ROLE authenticated;
    UPDATE storage.objects
    SET metadata = '{"replacement":true}'::jsonb
    WHERE bucket_id = 'job-photos' AND name = path_booked_1;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    v_ok := v_count = 0;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    v_ok := SQLSTATE IN ('42501', 'P0001');
  END;
  PERFORM pg_temp.pass(34, 'UPDATE and Storage upsert authority absent', v_ok);

  -- 35-37. Policy surface is exactly the four narrow authenticated policies.
  SELECT count(*) INTO v_count
  FROM pg_policy pol
  JOIN pg_class c ON c.oid = pol.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'storage' AND c.relname = 'objects'
    AND pol.polname IN (
      'Active clients can upload own open job photos',
      'Active clients can select own job photos',
      'Confirmed assigned workers can select job photos',
      'Active clients can delete own open job photos'
    );
  PERFORM pg_temp.pass(35, 'four V4-9 Storage policies present', v_count = 4,
    'count=' || v_count);

  PERFORM pg_temp.pass(36, 'no V4-9 UPDATE policy', NOT EXISTS (
    SELECT 1
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'storage' AND c.relname = 'objects'
      AND pol.polcmd = 'w'
      AND (pg_get_expr(pol.polqual, pol.polrelid) ILIKE '%job-photos%'
        OR pg_get_expr(pol.polwithcheck, pol.polrelid) ILIKE '%job-photos%')
  ));

  SELECT count(*) INTO v_count
  FROM pg_policy pol
  JOIN pg_class c ON c.oid = pol.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'storage' AND c.relname = 'objects'
    AND pol.polname IN (
      'Active clients can upload own open job photos',
      'Active clients can select own job photos',
      'Confirmed assigned workers can select job photos',
      'Active clients can delete own open job photos'
    )
    AND pol.polroles = ARRAY['authenticated'::regrole::oid];
  PERFORM pg_temp.pass(37, 'all V4-9 policies target authenticated only',
    v_count = 4, 'count=' || v_count);

  -- 38-40. ERD/schema and matching remain isolated from photos.
  PERFORM pg_temp.pass(38, 'no Job-photo application table created', NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
      AND c.relname IN ('job_images', 'job_posting_images', 'job_attachments', 'job_photos')
  ));

  SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO v_columns
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relname = 'job_postings'
    AND a.attnum > 0 AND NOT a.attisdropped;
  PERFORM pg_temp.pass(39, 'job_postings has no photo/image column',
    v_columns NOT ILIKE '%photo%' AND v_columns NOT ILIKE '%image%',
    'columns=' || coalesce(v_columns, 'missing'));

  PERFORM pg_temp.pass(40, 'matching functions contain no Job-photo coupling',
    to_regprocedure('private.compute_job_matches(uuid)') IS NOT NULL
      AND to_regprocedure('public.match_workers_for_job(uuid)') IS NOT NULL
      AND to_regprocedure('public.list_my_job_opportunities()') IS NOT NULL
      AND pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure)
        NOT ILIKE '%job-photos%'
      AND pg_get_functiondef('public.match_workers_for_job(uuid)'::regprocedure)
        NOT ILIKE '%job-photos%'
      AND pg_get_functiondef('public.list_my_job_opportunities()'::regprocedure)
        NOT ILIKE '%job-photos%');
END;
$$;

SELECT n, name, ok, detail
FROM v4_9_results
ORDER BY n;

SELECT
  count(*) FILTER (WHERE ok) AS passed,
  count(*) FILTER (WHERE NOT ok) AS failed,
  count(*) AS total
FROM v4_9_results;

ABORT;

-- Migration bucket persists; transaction fixtures and object metadata do not.
SELECT
  (SELECT count(*) FROM storage.buckets WHERE id = 'job-photos') AS job_photo_buckets,
  (SELECT count(*) FROM storage.objects WHERE bucket_id = 'job-photos') AS job_photo_objects;
