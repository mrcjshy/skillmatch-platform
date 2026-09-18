-- R5D-IMG-B2 local SQL verification.
--
-- PROOF CLASS: BUCKET / POLICY SQL (storage.objects metadata).
-- This script does NOT perform Storage API binary uploads.
-- Actual image upload is deferred to M1/runtime.
--
-- Disposable fixtures only. Run against local Supabase after
-- db reset. The script ABORTs the outer transaction so no
-- fixture survives. Direct DELETE of storage.objects is allowed
-- only after set_config('storage.allow_delete_query') so the
-- RLS DELETE policy can be observed; production delete remains
-- the Storage API.

BEGIN;

CREATE TEMP TABLE r5d_img_b2_results (
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
  INSERT INTO r5d_img_b2_results(n, name, ok, detail)
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

CREATE OR REPLACE FUNCTION pg_temp.mk_worker(p_user_id uuid, p_profile_id uuid, p_email text)
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
    crypt('r5d-img-b2-local', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  );

  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'R5D IMG B2 Fixture', '09000000000', 'worker',
    'Test', 'Test City', true
  );

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

DO $$
DECLARE
  owner_user    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  other_user    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
  owner_profile uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
  other_profile uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
  owner_item    uuid := 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1';
  other_item    uuid := 'cccccccc-cccc-4ccc-8ccc-ccccccccccc2';
  img_select    uuid := 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1';
  img_delete    uuid := 'dddddddd-dddd-4ddd-8ddd-ddddddddddd2';
  ghost_profile uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1';
  ghost_item    uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2';
  v_count       int;
  v_seen        int;
  v_public      boolean;
  v_limit       bigint;
  v_mimes       text[];
  v_expected    text[] := ARRAY['image/jpeg', 'image/png', 'image/webp'];
  v_has_update  boolean;
  v_cols        text;
  v_item_cols   text;
  v_denied      boolean;
BEGIN
  PERFORM pg_temp.mk_worker(owner_user, owner_profile, 'r5d-img-b2-owner@example.test');
  PERFORM pg_temp.mk_worker(other_user, other_profile, 'r5d-img-b2-other@example.test');

  INSERT INTO public.portfolio_items (
    id, worker_id, title, description, project_scale
  ) VALUES
    (owner_item, owner_profile, 'Owner project', 'own', 'small'),
    (other_item, other_profile, 'Other project', 'other', 'medium');

  PERFORM set_config('storage.allow_delete_query', 'true', true);

  -- 1-5. bucket definition
  SELECT count(*) INTO v_count FROM storage.buckets WHERE id = 'portfolio';
  PERFORM pg_temp.pass(1, 'portfolio bucket exists', v_count = 1, 'count=' || v_count);

  SELECT public, file_size_limit, allowed_mime_types
    INTO v_public, v_limit, v_mimes
  FROM storage.buckets
  WHERE id = 'portfolio';

  PERFORM pg_temp.pass(2, 'portfolio bucket is private',
    v_public IS FALSE, 'public=' || coalesce(v_public::text, 'null'));

  PERFORM pg_temp.pass(3, 'file size limit is 5 MiB',
    v_limit = 5242880, 'limit=' || coalesce(v_limit::text, 'null'));

  PERFORM pg_temp.pass(4, 'MIME allow-list exact',
    v_mimes IS NOT NULL
      AND v_mimes @> v_expected
      AND v_expected @> v_mimes
      AND cardinality(v_mimes) = 3,
    'mimes=' || coalesce(array_to_string(v_mimes, ','), 'null'));

  SELECT count(*) INTO v_count FROM storage.buckets;
  PERFORM pg_temp.pass(5, 'only portfolio and worker-identity buckets',
    v_count = 2
    AND EXISTS (
      SELECT 1 FROM storage.buckets
      WHERE id = 'portfolio' AND public IS FALSE
    )
    AND EXISTS (
      SELECT 1 FROM storage.buckets
      WHERE id = 'worker-identity' AND public IS FALSE
    ),
    'buckets=' || v_count);

  -- Seed one owned object as postgres so SELECT can be proven without
  -- depending on the INSERT policy under test in the same case.
  INSERT INTO storage.objects (bucket_id, name)
  VALUES (
    'portfolio',
    pg_temp.owned_path(owner_profile, owner_item, img_select::text || '.jpg')
  );

  INSERT INTO storage.objects (bucket_id, name)
  VALUES (
    'portfolio',
    pg_temp.owned_path(owner_profile, owner_item, img_delete::text || '.jpg')
  );

  -- 6. owner SELECT
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'portfolio'
      AND name = pg_temp.owned_path(owner_profile, owner_item, img_select::text || '.jpg');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'owner object SELECT allowed',
      v_seen = 1, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'owner object SELECT allowed', false, SQLERRM);
  END;

  -- 7. owner INSERT
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(owner_profile, owner_item, 'owner-insert.webp')
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'owner object INSERT policy allowed', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(7, 'owner object INSERT policy allowed', false, SQLERRM);
  END;

  -- 8. owner DELETE
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    DELETE FROM storage.objects
    WHERE bucket_id = 'portfolio'
      AND name = pg_temp.owned_path(owner_profile, owner_item, img_delete::text || '.jpg');
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'owner object DELETE allowed',
      v_count = 1, 'deleted=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'owner object DELETE allowed', false, SQLERRM);
  END;

  -- 9. owner UPDATE unavailable (no UPDATE policy; RLS default-deny)
  SELECT EXISTS (
    SELECT 1
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'storage'
      AND c.relname = 'objects'
      AND pol.polcmd = 'w'
  ) INTO v_has_update;
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    UPDATE storage.objects
    SET metadata = '{"probe":true}'::jsonb
    WHERE bucket_id = 'portfolio'
      AND name = pg_temp.owned_path(owner_profile, owner_item, img_select::text || '.jpg');
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    SELECT metadata ? 'probe' INTO v_denied
    FROM storage.objects
    WHERE bucket_id = 'portfolio'
      AND name = pg_temp.owned_path(owner_profile, owner_item, img_select::text || '.jpg');
    PERFORM pg_temp.pass(
      9,
      'owner UPDATE unavailable',
      (NOT v_has_update) AND v_count = 0 AND v_denied IS NOT TRUE,
      'updated=' || v_count || ' policy_update=' || v_has_update
    );
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'owner UPDATE unavailable', NOT v_has_update);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      9,
      'owner UPDATE unavailable',
      SQLSTATE = '42501' AND NOT v_has_update,
      SQLSTATE || ' policy_update=' || v_has_update
    );
  END;

  -- 10. non-owner SELECT hidden
  BEGIN
    PERFORM pg_temp.jwt(other_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'portfolio'
      AND name = pg_temp.owned_path(owner_profile, owner_item, img_select::text || '.jpg');
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'non-owner SELECT hidden',
      v_seen = 0, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'non-owner SELECT hidden', false, SQLERRM);
  END;

  -- 11. non-owner INSERT denied
  BEGIN
    PERFORM pg_temp.jwt(other_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(owner_profile, owner_item, 'other-insert.png')
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'non-owner INSERT denied', false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'non-owner INSERT denied', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      11,
      'non-owner INSERT denied',
      SQLSTATE IN ('42501', 'P0001'),
      SQLSTATE || ' ' || SQLERRM
    );
  END;

  -- 12. non-owner DELETE denied
  SELECT count(*) INTO v_count
  FROM storage.objects
  WHERE name = pg_temp.owned_path(owner_profile, owner_item, img_select::text || '.jpg');
  BEGIN
    PERFORM pg_temp.jwt(other_user);
    SET LOCAL ROLE authenticated;
    DELETE FROM storage.objects
    WHERE bucket_id = 'portfolio'
      AND name = pg_temp.owned_path(owner_profile, owner_item, img_select::text || '.jpg');
    GET DIAGNOSTICS v_seen = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    SELECT count(*) INTO v_count
    FROM storage.objects
    WHERE name = pg_temp.owned_path(owner_profile, owner_item, img_select::text || '.jpg');
    PERFORM pg_temp.pass(12, 'non-owner DELETE denied',
      v_seen = 0 AND v_count = 1,
      'deleted=' || v_seen || ' remaining=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'non-owner DELETE denied', false, SQLERRM);
  END;

  -- 13. anon denied (no policy TO anon; grants remain on storage.objects)
  v_seen := -1;
  BEGIN
    SET LOCAL ROLE anon;
    SELECT count(*) INTO v_seen
    FROM storage.objects
    WHERE bucket_id = 'portfolio';
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(owner_profile, owner_item, 'anon.jpg')
    );
    RESET ROLE;
    PERFORM pg_temp.pass(13, 'anon denied', false, 'insert succeeded seen=' || v_seen);
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.pass(13, 'anon denied', v_seen <= 0, 'seen=' || v_seen);
  WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.pass(
      13,
      'anon denied',
      SQLSTATE IN ('42501', 'P0001') AND v_seen <= 0,
      SQLSTATE || ' seen=' || v_seen
    );
  END;

  -- 14. unrelated bucket not covered
  INSERT INTO storage.buckets (id, name, public)
  VALUES ('r5d-img-b2-other', 'r5d-img-b2-other', false);
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'r5d-img-b2-other',
      pg_temp.owned_path(owner_profile, owner_item, 'other-bucket.jpg')
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'unrelated bucket not covered', false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'unrelated bucket not covered', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      14,
      'unrelated bucket not covered',
      SQLSTATE IN ('42501', 'P0001'),
      SQLSTATE || ' ' || SQLERRM
    );
  END;

  -- 15. mixed / unowned path denied
  v_denied := true;
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(owner_profile, other_item, 'mixed-own-folder.jpg')
    );
    PERFORM pg_temp.clear_jwt();
    v_denied := false;
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    IF SQLSTATE NOT IN ('42501', 'P0001') THEN
      v_denied := false;
    END IF;
  END;
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(other_profile, owner_item, 'mixed-other-folder.jpg')
    );
    PERFORM pg_temp.clear_jwt();
    v_denied := false;
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    IF SQLSTATE NOT IN ('42501', 'P0001') THEN
      v_denied := false;
    END IF;
  END;
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(ghost_profile, ghost_item, 'unowned-uuids.jpg')
    );
    PERFORM pg_temp.clear_jwt();
    v_denied := false;
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    IF SQLSTATE NOT IN ('42501', 'P0001') THEN
      v_denied := false;
    END IF;
  END;
  PERFORM pg_temp.pass(15, 'mixed ownership and unowned UUID folders denied', v_denied);

  -- 16. malformed path denied
  v_denied := true;
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('portfolio', owner_profile::text || '/one-folder.jpg');
    PERFORM pg_temp.clear_jwt();
    v_denied := false;
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    IF SQLSTATE NOT IN ('42501', 'P0001') THEN
      v_denied := false;
    END IF;
  END;
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      owner_profile::text || '/' || owner_item::text || '/extra/too-deep.jpg'
    );
    PERFORM pg_temp.clear_jwt();
    v_denied := false;
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    IF SQLSTATE NOT IN ('42501', 'P0001') THEN
      v_denied := false;
    END IF;
  END;
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('portfolio', 'no-folder.jpg');
    PERFORM pg_temp.clear_jwt();
    v_denied := false;
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    IF SQLSTATE NOT IN ('42501', 'P0001') THEN
      v_denied := false;
    END IF;
  END;
  PERFORM pg_temp.pass(16, 'malformed path denied', v_denied);

  -- 17. valid owned two-folder path accepted
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name)
    VALUES (
      'portfolio',
      pg_temp.owned_path(owner_profile, owner_item, 'second-valid.png')
    );
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      17,
      'valid owned two-folder path accepted',
      v_count = 1
        AND cardinality(storage.foldername(
          pg_temp.owned_path(owner_profile, owner_item, 'second-valid.png')
        )) = 2,
      'inserted=' || v_count
    );
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(17, 'valid owned two-folder path accepted', false, SQLERRM);
  END;

  -- 18-21. B1 / application / matching non-regression
  SELECT to_regclass('public.portfolio_item_images') IS NOT NULL INTO v_denied;
  SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO v_cols
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'portfolio_item_images'
    AND a.attnum > 0
    AND NOT a.attisdropped;
  PERFORM pg_temp.pass(18, 'B1 portfolio_item_images intact',
    v_denied AND v_cols = 'id,portfolio_item_id,storage_path,position,created_at',
    'cols=' || coalesce(v_cols, 'missing'));

  SELECT count(*) INTO v_count
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.relname NOT LIKE 'pg_%';
  PERFORM pg_temp.pass(19, 'application tables still 13',
    v_count = 13, 'tables=' || v_count);

  SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO v_item_cols
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'portfolio_items'
    AND a.attnum > 0
    AND NOT a.attisdropped;
  SELECT count(*) INTO v_count
  FROM public.portfolio_items
  WHERE id IN (owner_item, other_item);
  PERFORM pg_temp.pass(20, 'portfolio_items unchanged',
    v_item_cols = 'id,worker_id,title,description,image_url,project_scale,created_at'
      AND v_count = 2,
    'cols=' || coalesce(v_item_cols, 'missing') || ' rows=' || v_count);

  PERFORM pg_temp.pass(21, 'matching functions unchanged',
    to_regprocedure('public.match_workers_for_job(uuid)') IS NOT NULL
      AND to_regprocedure('private.compute_job_matches(uuid)') IS NOT NULL
      AND to_regprocedure('public.list_my_job_opportunities()') IS NOT NULL);

  -- 22. fixtures remain only inside this aborted transaction
  SELECT count(*) INTO v_count
  FROM public.portfolio_items
  WHERE id NOT IN (owner_item, other_item);
  PERFORM pg_temp.pass(22, 'only disposable local fixtures exist before rollback',
    v_count = 0, 'extra_items=' || v_count);
END;
$$;

SELECT n, name, ok, detail
FROM r5d_img_b2_results
ORDER BY n;

SELECT
  count(*) FILTER (WHERE ok) AS passed,
  count(*) FILTER (WHERE NOT ok) AS failed,
  count(*) AS total
FROM r5d_img_b2_results;

ABORT;

-- Post-rollback leftover check. Migration bucket remains; fixtures must not.
SELECT
  (SELECT count(*) FROM public.portfolio_item_images) AS portfolio_item_images,
  (SELECT count(*) FROM public.portfolio_items) AS portfolio_items,
  (SELECT count(*) FROM storage.objects) AS storage_objects,
  (SELECT count(*) FROM storage.buckets WHERE id <> 'portfolio') AS extra_buckets;
