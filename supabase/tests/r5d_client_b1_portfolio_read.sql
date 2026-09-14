-- R5D-CLIENT-B1 local SQL verification.
--
-- PROOF CLASS: RLS / storage.objects metadata SELECT.
-- This script does NOT call the Storage HTTP API or createSignedUrls.
-- Object SELECT is the documented signed-URL authorization seam.
--
-- Disposable fixtures only. Run against local Supabase after
-- db reset. The script ABORTs the outer transaction so no
-- fixture survives.

BEGIN;

CREATE TEMP TABLE r5d_client_b1_results (
  n      int,
  name   text,
  ok     boolean,
  detail text
);

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO r5d_client_b1_results(n, name, ok, detail)
  VALUES (p_n, p_name, p_ok, p_detail);
  IF NOT p_ok THEN
    RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  ELSE
    RAISE NOTICE 'PASS % %', p_n, p_name;
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
  p_user_id uuid,
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
    p_user_id,
    'authenticated',
    'authenticated',
    p_email,
    crypt('r5d-client-b1-local', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  );

  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'R5D CLIENT B1 Fixture', '09000000000', p_role,
    'Test', 'Test City', p_active
  );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.mk_worker(p_user_id uuid, p_profile_id uuid, p_email text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_temp.mk_user(p_user_id, p_email, 'worker', true);
  INSERT INTO public.worker_profiles (
    id, user_id, bio, badge_level, availability_status
  ) VALUES (
    p_profile_id, p_user_id, 'local fixture', 'none', 'available'
  );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.owned_path(p_profile uuid, p_item uuid, p_file text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_profile::text || '/' || p_item::text || '/' || p_file
$$;

CREATE OR REPLACE FUNCTION pg_temp.count_item(p_uid uuid, p_item uuid)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_seen int;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_seen
  FROM public.portfolio_items
  WHERE id = p_item;
  PERFORM pg_temp.clear_jwt();
  RETURN v_seen;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.count_image(p_uid uuid, p_image uuid)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_seen int;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_seen
  FROM public.portfolio_item_images
  WHERE id = p_image;
  PERFORM pg_temp.clear_jwt();
  RETURN v_seen;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.count_object(p_uid uuid, p_path text)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_seen int;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_seen
  FROM storage.objects
  WHERE bucket_id = 'portfolio'
    AND name = p_path;
  PERFORM pg_temp.clear_jwt();
  RETURN v_seen;
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.clear_jwt();
  RAISE;
END;
$$;

DO $$
DECLARE
  worker_a_user    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  worker_b_user    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  client_auth      uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa11';
  client_other     uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa12';
  client_inactive  uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa13';
  worker_a_profile uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01';
  worker_b_profile uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb02';
  item_a           uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc01';
  item_b           uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc02';
  item_a_write     uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccc03';
  img_a            uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddd01';
  img_b            uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddd02';
  img_a_del        uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddd03';
  job_auth         uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';
  job_other        uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02';
  job_inactive     uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03';
  booking_auth     uuid := 'ffffffff-ffff-4fff-8fff-ffffffffff01';
  booking_other    uuid := 'ffffffff-ffff-4fff-8fff-ffffffffff02';
  booking_inactive uuid := 'ffffffff-ffff-4fff-8fff-ffffffffff03';
  path_a           text;
  path_b           text;
  path_ghost       text;
  path_other_bucket text := 'wrong-bucket.jpg';
  v_count          int;
  v_seen           int;
  v_public         boolean;
  v_limit          bigint;
  v_mimes          text[];
  v_expected       text[] := ARRAY['image/jpeg', 'image/png', 'image/webp'];
  v_names          text;
  v_def            text;
  v_denied         boolean;
  v_status         text;
BEGIN
  path_a := pg_temp.owned_path(worker_a_profile, item_a, img_a::text || '.jpg');
  path_b := pg_temp.owned_path(worker_b_profile, item_b, img_b::text || '.png');
  path_ghost := pg_temp.owned_path(worker_a_profile, item_a, 'ghost-no-metadata.jpg');

  PERFORM pg_temp.mk_worker(worker_a_user, worker_a_profile, 'r5d-client-b1-wa@example.test');
  PERFORM pg_temp.mk_worker(worker_b_user, worker_b_profile, 'r5d-client-b1-wb@example.test');
  PERFORM pg_temp.mk_user(client_auth, 'r5d-client-b1-ca@example.test', 'client', true);
  PERFORM pg_temp.mk_user(client_other, 'r5d-client-b1-co@example.test', 'client', true);
  PERFORM pg_temp.mk_user(client_inactive, 'r5d-client-b1-ci@example.test', 'client', false);

  INSERT INTO public.job_postings (
    id, client_id, title, description, barangay, city, status, payment_method
  ) VALUES
    (job_auth, client_auth, 'Auth job', 'fixture', 'Test', 'Test City', 'matched', 'cod'),
    (job_other, client_other, 'Other job', 'fixture', 'Test', 'Test City', 'matched', 'cod'),
    (job_inactive, client_inactive, 'Inactive job', 'fixture', 'Test', 'Test City', 'matched', 'cod');

  INSERT INTO public.bookings (
    id, job_id, worker_id, client_id, status
  ) VALUES
    (booking_auth, job_auth, worker_a_user, client_auth, 'confirmed'),
    (booking_other, job_other, worker_b_user, client_other, 'confirmed'),
    (booking_inactive, job_inactive, worker_a_user, client_inactive, 'confirmed');

  INSERT INTO public.portfolio_items (
    id, worker_id, title, description, project_scale
  ) VALUES
    (item_a, worker_a_profile, 'Worker A project', 'a', 'small'),
    (item_b, worker_b_profile, 'Worker B project', 'b', 'medium');

  INSERT INTO public.portfolio_item_images (
    id, portfolio_item_id, storage_path, position
  ) VALUES
    (img_a, item_a, path_a, 1),
    (img_b, item_b, path_b, 1),
    (
      img_a_del, item_a,
      pg_temp.owned_path(worker_a_profile, item_a, img_a_del::text || '.jpg'),
      2
    );

  PERFORM set_config('storage.allow_delete_query', 'true', true);

  INSERT INTO storage.objects (bucket_id, name) VALUES
    ('portfolio', path_a),
    ('portfolio', path_b),
    ('portfolio', path_ghost),
    (
      'portfolio',
      pg_temp.owned_path(worker_a_profile, item_a, img_a_del::text || '.jpg')
    );

  INSERT INTO storage.buckets (id, name, public)
  VALUES ('r5d-client-b1-other', 'r5d-client-b1-other', false);
  INSERT INTO storage.objects (bucket_id, name)
  VALUES ('r5d-client-b1-other', path_other_bucket);

  -- 1. residual broad SELECT gone
  SELECT string_agg(pol.polname, ',' ORDER BY pol.polname) INTO v_names
  FROM pg_policy pol
  JOIN pg_class c ON c.oid = pol.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'portfolio_items';
  PERFORM pg_temp.pass(1, 'broad authenticated portfolio_items SELECT dropped',
    v_names IS NOT NULL
      AND v_names NOT LIKE '%Anyone authenticated can read portfolio items%',
    'policies=' || coalesce(v_names, 'none'));

  -- 2-4. new Client SELECT policies
  PERFORM pg_temp.pass(2, 'Client portfolio_items SELECT policy present',
    EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = 'portfolio_items'
        AND pol.polname = 'Clients can select confirmed counterpart portfolio items'
        AND pol.polcmd = 'r'
    ));

  PERFORM pg_temp.pass(3, 'Client portfolio_item_images SELECT policy present',
    EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = 'portfolio_item_images'
        AND pol.polname = 'Clients can select confirmed counterpart portfolio item images'
        AND pol.polcmd = 'r'
    ));

  PERFORM pg_temp.pass(4, 'Client storage.objects SELECT policy present',
    EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'storage' AND c.relname = 'objects'
        AND pol.polname = 'Clients can select confirmed counterpart portfolio objects'
        AND pol.polcmd = 'r'
    ));

  -- 5. Worker-own policies preserved
  PERFORM pg_temp.pass(5, 'Worker portfolio management policy preserved',
    EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = 'portfolio_items'
        AND pol.polname = 'Workers can manage their own portfolio'
    )
    AND EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = 'portfolio_item_images'
        AND pol.polname = 'Workers can select own portfolio item images'
    )
    AND EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'storage' AND c.relname = 'objects'
        AND pol.polname = 'Workers can select own portfolio objects'
    )
    AND EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'storage' AND c.relname = 'objects'
        AND pol.polname = 'Workers can upload own portfolio objects'
    )
    AND EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'storage' AND c.relname = 'objects'
        AND pol.polname = 'Workers can delete own portfolio objects'
    ));

  -- 6. no public portfolio RPC
  SELECT count(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname ILIKE '%portfolio%';
  PERFORM pg_temp.pass(6, 'no public portfolio RPC',
    v_count = 0, 'public_portfolio_functions=' || v_count);

  -- 7. bucket contract unchanged
  SELECT public, file_size_limit, allowed_mime_types
    INTO v_public, v_limit, v_mimes
  FROM storage.buckets
  WHERE id = 'portfolio';
  PERFORM pg_temp.pass(7, 'portfolio bucket contract unchanged',
    v_public IS FALSE
      AND v_limit = 5242880
      AND v_mimes IS NOT NULL
      AND v_mimes @> v_expected
      AND v_expected @> v_mimes
      AND cardinality(v_mimes) = 3,
    'public=' || coalesce(v_public::text, 'null')
      || ' limit=' || coalesce(v_limit::text, 'null')
      || ' mimes=' || coalesce(array_to_string(v_mimes, ','), 'null'));

  -- 8. matching functions unchanged
  v_def := pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure);
  PERFORM pg_temp.pass(8, 'matching functions unchanged',
    to_regprocedure('public.match_workers_for_job(uuid)') IS NOT NULL
      AND to_regprocedure('private.compute_job_matches(uuid)') IS NOT NULL
      AND to_regprocedure('public.list_my_job_opportunities()') IS NOT NULL
      AND v_def LIKE '%* 50%'
      AND v_def LIKE '%* 20%'
      AND v_def LIKE '%location_points%'
      AND v_def NOT ILIKE '%portfolio%',
    'compute_mentions_portfolio=' || (v_def ILIKE '%portfolio%'));

  -- 9-11. authorized confirmed Client reads Worker A
  v_seen := pg_temp.count_item(client_auth, item_a);
  PERFORM pg_temp.pass(9, 'confirmed Client SELECT Worker A portfolio_items',
    v_seen = 1, 'seen=' || v_seen);

  v_seen := pg_temp.count_image(client_auth, img_a);
  PERFORM pg_temp.pass(10, 'confirmed Client SELECT Worker A image metadata',
    v_seen = 1, 'seen=' || v_seen);

  v_seen := pg_temp.count_object(client_auth, path_a);
  PERFORM pg_temp.pass(11, 'confirmed Client SELECT Worker A exact Storage object',
    v_seen = 1, 'seen=' || v_seen);

  -- 12-14. same Client cannot read Worker B
  v_seen := pg_temp.count_item(client_auth, item_b);
  PERFORM pg_temp.pass(12, 'confirmed Client cannot SELECT Worker B item',
    v_seen = 0, 'seen=' || v_seen);

  v_seen := pg_temp.count_image(client_auth, img_b);
  PERFORM pg_temp.pass(13, 'confirmed Client cannot SELECT Worker B image',
    v_seen = 0, 'seen=' || v_seen);

  v_seen := pg_temp.count_object(client_auth, path_b);
  PERFORM pg_temp.pass(14, 'confirmed Client cannot SELECT Worker B object',
    v_seen = 0, 'seen=' || v_seen);

  -- 15-17. other Client cannot read Worker A; can read own Worker B
  v_seen := pg_temp.count_item(client_other, item_a);
  PERFORM pg_temp.pass(15, 'other Client cannot SELECT Worker A item',
    v_seen = 0, 'seen=' || v_seen);

  v_seen := pg_temp.count_item(client_other, item_b);
  PERFORM pg_temp.pass(16, 'other Client SELECT own confirmed Worker B item',
    v_seen = 1, 'seen=' || v_seen);

  v_seen := pg_temp.count_image(client_other, img_a);
  PERFORM pg_temp.pass(17, 'other Client cannot SELECT Worker A image',
    v_seen = 0, 'seen=' || v_seen);

  v_seen := pg_temp.count_object(client_other, path_a);
  PERFORM pg_temp.pass(18, 'other Client cannot SELECT Worker A object',
    v_seen = 0, 'seen=' || v_seen);

  -- 19-21. inactive Client with confirmed Booking still denied
  v_seen := pg_temp.count_item(client_inactive, item_a);
  PERFORM pg_temp.pass(19, 'inactive Client cannot SELECT Worker A item',
    v_seen = 0, 'seen=' || v_seen);

  v_seen := pg_temp.count_image(client_inactive, img_a);
  PERFORM pg_temp.pass(20, 'inactive Client cannot SELECT Worker A image',
    v_seen = 0, 'seen=' || v_seen);

  v_seen := pg_temp.count_object(client_inactive, path_a);
  PERFORM pg_temp.pass(21, 'inactive Client cannot SELECT Worker A object',
    v_seen = 0, 'seen=' || v_seen);

  -- 22. anon denied
  v_seen := -1;
  BEGIN
    SET LOCAL ROLE anon;
    SELECT count(*) INTO v_seen FROM public.portfolio_items WHERE id = item_a;
    SELECT count(*) INTO v_count FROM public.portfolio_item_images WHERE id = img_a;
    SELECT count(*) INTO v_limit FROM storage.objects WHERE name = path_a;
    RESET ROLE;
    PERFORM pg_temp.pass(22, 'anon cannot SELECT portfolio text/images/objects',
      v_seen <= 0 AND v_count <= 0 AND v_limit <= 0,
      'items=' || v_seen || ' images=' || v_count || ' objects=' || v_limit);
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.pass(22, 'anon cannot SELECT portfolio text/images/objects',
      v_seen <= 0);
  WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.pass(
      22,
      'anon cannot SELECT portfolio text/images/objects',
      SQLSTATE IN ('42501', 'P0001') AND v_seen <= 0,
      SQLSTATE || ' seen=' || v_seen
    );
  END;

  -- 23-26. non-confirmed statuses hide Worker A from the same Client
  FOREACH v_status IN ARRAY ARRAY['completed', 'cancelled', 'pending', 'no_show']
  LOOP
    UPDATE public.bookings SET status = v_status WHERE id = booking_auth;
    v_seen := pg_temp.count_item(client_auth, item_a);
    v_count := pg_temp.count_image(client_auth, img_a);
    v_limit := pg_temp.count_object(client_auth, path_a);
    PERFORM pg_temp.pass(
      CASE v_status
        WHEN 'completed' THEN 23
        WHEN 'cancelled' THEN 24
        WHEN 'pending' THEN 25
        ELSE 26
      END,
      'Client cannot SELECT Worker A while Booking is ' || v_status,
      v_seen = 0 AND v_count = 0 AND v_limit = 0,
      'items=' || v_seen || ' images=' || v_count || ' objects=' || v_limit
    );
  END LOOP;

  UPDATE public.bookings SET status = 'confirmed' WHERE id = booking_auth;
  v_seen := pg_temp.count_item(client_auth, item_a);
  PERFORM pg_temp.pass(27, 'Client SELECT restored when Booking returns to confirmed',
    v_seen = 1, 'seen=' || v_seen);

  -- 28-30. exact metadata Storage boundary
  v_seen := pg_temp.count_object(client_auth, path_ghost);
  PERFORM pg_temp.pass(28, 'same Worker folder object without metadata DENIED',
    v_seen = 0, 'seen=' || v_seen);

  v_seen := pg_temp.count_object(client_auth, path_b);
  PERFORM pg_temp.pass(29, 'other Worker exact object DENIED',
    v_seen = 0, 'seen=' || v_seen);

  BEGIN
    PERFORM pg_temp.jwt(client_auth);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'r5d-client-b1-other'
      AND name = path_other_bucket;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(30, 'wrong bucket object not visible via portfolio policy',
      v_seen = 0, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      30,
      'wrong bucket object not visible via portfolio policy',
      SQLSTATE IN ('42501', 'P0001'),
      SQLSTATE || ' ' || SQLERRM
    );
  END;

  -- 31-37. Client writes forbidden
  BEGIN
    PERFORM pg_temp.jwt(client_auth);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.portfolio_items (worker_id, title, project_scale)
    VALUES (worker_a_profile, 'Client insert', 'small');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(31, 'Client INSERT portfolio_items denied', false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(31, 'Client INSERT portfolio_items denied', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      31,
      'Client INSERT portfolio_items denied',
      SQLSTATE IN ('42501', 'P0001'),
      SQLSTATE || ' ' || SQLERRM
    );
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_auth);
    SET LOCAL ROLE authenticated;
    UPDATE public.portfolio_items
    SET title = 'Client rewrite'
    WHERE id = item_a;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(32, 'Client UPDATE portfolio_items denied',
      v_count = 0, 'updated=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      32,
      'Client UPDATE portfolio_items denied',
      SQLSTATE IN ('42501', 'P0001'),
      SQLSTATE || ' ' || SQLERRM
    );
  END;

  SELECT count(*) INTO v_count FROM public.portfolio_items WHERE id = item_a;
  BEGIN
    PERFORM pg_temp.jwt(client_auth);
    SET LOCAL ROLE authenticated;
    DELETE FROM public.portfolio_items WHERE id = item_a;
    GET DIAGNOSTICS v_seen = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    SELECT count(*) INTO v_count FROM public.portfolio_items WHERE id = item_a;
    PERFORM pg_temp.pass(33, 'Client DELETE portfolio_items denied',
      v_seen = 0 AND v_count = 1,
      'deleted=' || v_seen || ' remaining=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(33, 'Client DELETE portfolio_items denied', false, SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_auth);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.portfolio_item_images (
      portfolio_item_id, storage_path, position
    ) VALUES (
      item_a,
      pg_temp.owned_path(worker_a_profile, item_a, 'client-insert.webp'),
      3
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(34, 'Client INSERT portfolio_item_images denied', false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(34, 'Client INSERT portfolio_item_images denied', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      34,
      'Client INSERT portfolio_item_images denied',
      SQLSTATE IN ('42501', 'P0001'),
      SQLSTATE || ' ' || SQLERRM
    );
  END;

  SELECT count(*) INTO v_count FROM public.portfolio_item_images WHERE id = img_a;
  BEGIN
    PERFORM pg_temp.jwt(client_auth);
    SET LOCAL ROLE authenticated;
    DELETE FROM public.portfolio_item_images WHERE id = img_a;
    GET DIAGNOSTICS v_seen = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    SELECT count(*) INTO v_count FROM public.portfolio_item_images WHERE id = img_a;
    PERFORM pg_temp.pass(35, 'Client DELETE portfolio_item_images denied',
      v_seen = 0 AND v_count = 1,
      'deleted=' || v_seen || ' remaining=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(35, 'Client DELETE portfolio_item_images denied', false, SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(client_auth);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(worker_a_profile, item_a, 'client-upload.jpg')
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(36, 'Client INSERT portfolio Storage object denied', false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(36, 'Client INSERT portfolio Storage object denied', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      36,
      'Client INSERT portfolio Storage object denied',
      SQLSTATE IN ('42501', 'P0001'),
      SQLSTATE || ' ' || SQLERRM
    );
  END;

  SELECT count(*) INTO v_count FROM storage.objects WHERE name = path_a;
  BEGIN
    PERFORM pg_temp.jwt(client_auth);
    SET LOCAL ROLE authenticated;
    DELETE FROM storage.objects
    WHERE bucket_id = 'portfolio' AND name = path_a;
    GET DIAGNOSTICS v_seen = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    SELECT count(*) INTO v_count FROM storage.objects WHERE name = path_a;
    PERFORM pg_temp.pass(37, 'Client DELETE portfolio Storage object denied',
      v_seen = 0 AND v_count = 1,
      'deleted=' || v_seen || ' remaining=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(37, 'Client DELETE portfolio Storage object denied', false, SQLERRM);
  END;

  -- 38-44. Worker-own regression; other Worker still hidden
  v_seen := pg_temp.count_item(worker_a_user, item_a);
  PERFORM pg_temp.pass(38, 'Worker SELECT own portfolio_items',
    v_seen = 1, 'seen=' || v_seen);

  v_seen := pg_temp.count_item(worker_a_user, item_b);
  PERFORM pg_temp.pass(39, 'Worker cannot SELECT other Worker portfolio_items',
    v_seen = 0, 'seen=' || v_seen);

  BEGIN
    PERFORM pg_temp.jwt(worker_a_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.portfolio_items (
      id, worker_id, title, description, project_scale
    ) VALUES (
      item_a_write, worker_a_profile, 'Worker write item', 'w', 'large'
    );
    UPDATE public.portfolio_items
    SET title = 'Worker updated title'
    WHERE id = item_a_write;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    DELETE FROM public.portfolio_items WHERE id = item_a_write;
    GET DIAGNOSTICS v_seen = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(40, 'Worker INSERT/UPDATE/DELETE own portfolio_items',
      v_count = 1 AND v_seen = 1,
      'updated=' || v_count || ' deleted=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(40, 'Worker INSERT/UPDATE/DELETE own portfolio_items', false, SQLERRM);
  END;

  v_seen := pg_temp.count_image(worker_a_user, img_a);
  PERFORM pg_temp.pass(41, 'Worker SELECT own image metadata',
    v_seen = 1, 'seen=' || v_seen);

  BEGIN
    PERFORM pg_temp.jwt(worker_a_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.portfolio_item_images (
      portfolio_item_id, storage_path, position
    ) VALUES (
      item_a,
      pg_temp.owned_path(worker_a_profile, item_a, 'worker-insert.webp'),
      3
    );
    DELETE FROM public.portfolio_item_images WHERE id = img_a_del;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(42, 'Worker INSERT/DELETE own image metadata',
      v_count = 1, 'deleted=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(42, 'Worker INSERT/DELETE own image metadata', false, SQLERRM);
  END;

  v_seen := pg_temp.count_object(worker_a_user, path_a);
  PERFORM pg_temp.pass(43, 'Worker SELECT own canonical Storage object',
    v_seen = 1, 'seen=' || v_seen);

  BEGIN
    PERFORM pg_temp.jwt(worker_a_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(worker_a_profile, item_a, 'worker-upload.png')
    );
    DELETE FROM storage.objects
    WHERE bucket_id = 'portfolio'
      AND name = pg_temp.owned_path(worker_a_profile, item_a, img_a_del::text || '.jpg');
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(44, 'Worker INSERT/DELETE own canonical Storage objects',
      v_count = 1, 'deleted=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(44, 'Worker INSERT/DELETE own canonical Storage objects', false, SQLERRM);
  END;

  -- 45. no Admin write policy added
  PERFORM pg_temp.pass(45, 'no Admin portfolio write policy added',
    NOT EXISTS (
      SELECT 1 FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE pol.polname ILIKE '%admin%'
        AND (
          (n.nspname = 'public' AND c.relname IN ('portfolio_items', 'portfolio_item_images'))
          OR (n.nspname = 'storage' AND c.relname = 'objects' AND pol.polname ILIKE '%portfolio%')
        )
        AND pol.polcmd IN ('a', 'w', 'd')
    ));

  -- 46. fixtures remain only inside this aborted transaction
  SELECT count(*) INTO v_count
  FROM public.portfolio_items
  WHERE id NOT IN (item_a, item_b);
  PERFORM pg_temp.pass(46, 'only disposable local fixtures exist before rollback',
    v_count = 0, 'extra_items=' || v_count);
END;
$$;

SELECT n, name, ok, detail
FROM r5d_client_b1_results
ORDER BY n;

SELECT
  count(*) FILTER (WHERE ok) AS passed,
  count(*) FILTER (WHERE NOT ok) AS failed,
  count(*) AS total
FROM r5d_client_b1_results;

ABORT;

-- Post-rollback leftover check. Migration bucket remains; fixtures must not.
SELECT
  (SELECT count(*) FROM public.portfolio_item_images) AS portfolio_item_images,
  (SELECT count(*) FROM public.portfolio_items) AS portfolio_items,
  (SELECT count(*) FROM public.bookings) AS bookings,
  (SELECT count(*) FROM storage.objects) AS storage_objects,
  (SELECT count(*) FROM storage.buckets WHERE id <> 'portfolio') AS extra_buckets;
