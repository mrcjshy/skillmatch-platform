-- R5D-IMG-B1 local SQL verification. Disposable fixtures only. Run
-- against local Supabase after db reset. The script ABORTs the outer
-- transaction so no fixture survives.

BEGIN;

CREATE TEMP TABLE r5d_img_b1_results (
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
  INSERT INTO r5d_img_b1_results(n, name, ok, detail)
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
    crypt('r5d-img-b1-local', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
  );

  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'R5D IMG B1 Fixture', '09000000000', 'worker',
    'Test', 'Test City', true
  );

  INSERT INTO public.worker_profiles (
    id, user_id, bio, badge_level, availability_status
  ) VALUES (
    p_profile_id, p_user_id, 'local fixture', 'none', 'available'
  );
END;
$$;

DO $$
DECLARE
  owner_user    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  other_user    uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
  owner_profile uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
  other_profile uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
  owner_item    uuid := 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1';
  other_item    uuid := 'cccccccc-cccc-4ccc-8ccc-ccccccccccc2';
  cascade_item  uuid := 'cccccccc-cccc-4ccc-8ccc-ccccccccccc3';
  img_pos1      uuid := 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1';
  img_pos5      uuid := 'dddddddd-dddd-4ddd-8ddd-ddddddddddd5';
  img_owner_del uuid := 'dddddddd-dddd-4ddd-8ddd-ddddddddddd3';
  img_cascade   uuid := 'dddddddd-dddd-4ddd-8ddd-ddddddddddd4';
  v_count       int;
  v_seen        int;
  v_cols        text;
  v_has_update  boolean;
  v_image_url   text;
BEGIN
  PERFORM pg_temp.mk_worker(owner_user, owner_profile, 'r5d-img-b1-owner@example.test');
  PERFORM pg_temp.mk_worker(other_user, other_profile, 'r5d-img-b1-other@example.test');

  INSERT INTO public.portfolio_items (
    id, worker_id, title, description, project_scale
  ) VALUES
    (owner_item, owner_profile, 'Owner project', 'own', 'small'),
    (other_item, other_profile, 'Other project', 'other', 'medium'),
    (cascade_item, owner_profile, 'Cascade project', 'cascade', 'large');

  -- 1. table creates
  PERFORM pg_temp.pass(1, 'public.portfolio_item_images exists',
    to_regclass('public.portfolio_item_images') IS NOT NULL);

  -- 2. position 1 accepted
  BEGIN
    INSERT INTO public.portfolio_item_images (
      id, portfolio_item_id, storage_path, position
    ) VALUES (
      img_pos1, owner_item,
      owner_profile::text || '/' || owner_item::text || '/' || img_pos1::text || '.jpg',
      1
    );
    PERFORM pg_temp.pass(2, 'position 1 accepted', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.pass(2, 'position 1 accepted', false, SQLERRM);
  END;

  -- 3. position 5 accepted
  BEGIN
    INSERT INTO public.portfolio_item_images (
      id, portfolio_item_id, storage_path, position
    ) VALUES (
      img_pos5, owner_item,
      owner_profile::text || '/' || owner_item::text || '/' || img_pos5::text || '.jpg',
      5
    );
    PERFORM pg_temp.pass(3, 'position 5 accepted', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.pass(3, 'position 5 accepted', false, SQLERRM);
  END;

  -- 4. position 6 rejected
  BEGIN
    INSERT INTO public.portfolio_item_images (
      portfolio_item_id, storage_path, position
    ) VALUES (
      owner_item,
      owner_profile::text || '/' || owner_item::text || '/pos6.jpg',
      6
    );
    PERFORM pg_temp.pass(4, 'position 6 rejected', false, 'insert succeeded');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.pass(4, 'position 6 rejected', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.pass(4, 'position 6 rejected', false, SQLERRM);
  END;

  -- 5. duplicate (portfolio_item_id, position) rejected
  BEGIN
    INSERT INTO public.portfolio_item_images (
      portfolio_item_id, storage_path, position
    ) VALUES (
      owner_item,
      owner_profile::text || '/' || owner_item::text || '/dup-pos.jpg',
      1
    );
    PERFORM pg_temp.pass(5, 'duplicate item position rejected', false, 'insert succeeded');
  EXCEPTION WHEN unique_violation THEN
    PERFORM pg_temp.pass(5, 'duplicate item position rejected', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.pass(5, 'duplicate item position rejected', false, SQLERRM);
  END;

  -- 6. duplicate storage_path rejected
  BEGIN
    INSERT INTO public.portfolio_item_images (
      portfolio_item_id, storage_path, position
    ) VALUES (
      owner_item,
      owner_profile::text || '/' || owner_item::text || '/' || img_pos1::text || '.jpg',
      2
    );
    PERFORM pg_temp.pass(6, 'duplicate storage_path rejected', false, 'insert succeeded');
  EXCEPTION WHEN unique_violation THEN
    PERFORM pg_temp.pass(6, 'duplicate storage_path rejected', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.pass(6, 'duplicate storage_path rejected', false, SQLERRM);
  END;

  -- 7. deleting parent cascades image metadata
  INSERT INTO public.portfolio_item_images (
    id, portfolio_item_id, storage_path, position
  ) VALUES (
    img_cascade, cascade_item,
    owner_profile::text || '/' || cascade_item::text || '/' || img_cascade::text || '.jpg',
    1
  );
  DELETE FROM public.portfolio_items WHERE id = cascade_item;
  SELECT count(*) INTO v_count
  FROM public.portfolio_item_images
  WHERE id = img_cascade;
  PERFORM pg_temp.pass(7, 'parent delete cascades image rows',
    v_count = 0, 'remaining=' || v_count);

  -- 8-10. authenticated owner SELECT / INSERT / DELETE
  INSERT INTO public.portfolio_item_images (
    id, portfolio_item_id, storage_path, position
  ) VALUES (
    img_owner_del, owner_item,
    owner_profile::text || '/' || owner_item::text || '/' || img_owner_del::text || '.jpg',
    3
  );

  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM public.portfolio_item_images
    WHERE portfolio_item_id = owner_item;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'owner SELECT succeeds',
      v_seen >= 3, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(8, 'owner SELECT succeeds', false, SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.portfolio_item_images (
      portfolio_item_id, storage_path, position
    ) VALUES (
      owner_item,
      owner_profile::text || '/' || owner_item::text || '/owner-insert.jpg',
      4
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'owner INSERT succeeds', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'owner INSERT succeeds', false, SQLERRM);
  END;

  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    DELETE FROM public.portfolio_item_images WHERE id = img_owner_del;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'owner DELETE succeeds',
      v_count = 1, 'deleted=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'owner DELETE succeeds', false, SQLERRM);
  END;

  -- 11. non-owner SELECT returns no image metadata
  BEGIN
    PERFORM pg_temp.jwt(other_user);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen
    FROM public.portfolio_item_images
    WHERE portfolio_item_id = owner_item;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'non-owner SELECT returns no rows',
      v_seen = 0, 'seen=' || v_seen);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'non-owner SELECT returns no rows', false, SQLERRM);
  END;

  -- 12. non-owner INSERT denied
  BEGIN
    PERFORM pg_temp.jwt(other_user);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.portfolio_item_images (
      portfolio_item_id, storage_path, position
    ) VALUES (
      owner_item,
      owner_profile::text || '/' || owner_item::text || '/other-insert.jpg',
      2
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'non-owner INSERT denied', false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'non-owner INSERT denied', true);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      12,
      'non-owner INSERT denied',
      SQLSTATE IN ('42501', 'P0001'),
      SQLSTATE || ' ' || SQLERRM
    );
  END;

  -- 13. non-owner DELETE denied (zero rows)
  SELECT count(*) INTO v_count
  FROM public.portfolio_item_images
  WHERE id = img_pos1;
  BEGIN
    PERFORM pg_temp.jwt(other_user);
    SET LOCAL ROLE authenticated;
    DELETE FROM public.portfolio_item_images WHERE id = img_pos1;
    GET DIAGNOSTICS v_seen = ROW_COUNT;
    PERFORM pg_temp.clear_jwt();
    SELECT count(*) INTO v_count
    FROM public.portfolio_item_images
    WHERE id = img_pos1;
    PERFORM pg_temp.pass(13, 'non-owner DELETE denied',
      v_seen = 0 AND v_count = 1,
      'deleted=' || v_seen || ' remaining=' || v_count);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'non-owner DELETE denied', false, SQLERRM);
  END;

  -- 14. UPDATE unavailable
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name = 'portfolio_item_images'
      AND grantee = 'authenticated'
      AND privilege_type = 'UPDATE'
  ) INTO v_has_update;
  BEGIN
    PERFORM pg_temp.jwt(owner_user);
    SET LOCAL ROLE authenticated;
    UPDATE public.portfolio_item_images
    SET position = 2
    WHERE id = img_pos1;
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'UPDATE unavailable', false, 'update succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(14, 'UPDATE unavailable', NOT v_has_update);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(
      14,
      'UPDATE unavailable',
      SQLSTATE = '42501' AND NOT v_has_update,
      SQLSTATE || ' grant_update=' || v_has_update
    );
  END;

  -- 15. anon cannot access
  BEGIN
    SET LOCAL ROLE anon;
    EXECUTE 'SELECT count(*) FROM public.portfolio_item_images';
    RESET ROLE;
    PERFORM pg_temp.pass(15, 'anon cannot access', false, 'select succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.pass(15, 'anon cannot access', true);
  WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.pass(15, 'anon cannot access', SQLSTATE = '42501', SQLERRM);
  END;

  -- 16. existing portfolio_items behavior unchanged
  SELECT a.attname INTO v_image_url
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'portfolio_items'
    AND a.attname = 'image_url'
    AND a.attnum > 0
    AND NOT a.attisdropped;
  SELECT count(*) INTO v_count
  FROM public.portfolio_items
  WHERE id IN (owner_item, other_item);
  PERFORM pg_temp.pass(16, 'portfolio_items image_url and rows unchanged',
    v_image_url = 'image_url' AND v_count = 2,
    'image_url=' || coalesce(v_image_url, 'missing') || ' rows=' || v_count);

  -- 17. application schema otherwise 13 public tables; image columns exact
  SELECT count(*) INTO v_count
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.relname NOT LIKE 'pg_%';
  SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO v_cols
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'portfolio_item_images'
    AND a.attnum > 0
    AND NOT a.attisdropped;
  PERFORM pg_temp.pass(17, 'public table count is 13 and image columns exact',
    v_count = 13 AND v_cols = 'id,portfolio_item_id,storage_path,position,created_at',
    'tables=' || v_count || ' cols=' || v_cols);
END;
$$;

SELECT n, name, ok, detail
FROM r5d_img_b1_results
ORDER BY n;

SELECT
  count(*) FILTER (WHERE ok) AS passed,
  count(*) FILTER (WHERE NOT ok) AS failed,
  count(*) AS total
FROM r5d_img_b1_results;

ABORT;
