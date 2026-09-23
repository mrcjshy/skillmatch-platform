-- AA-04 focused local checks. Synthetic accounts and profiles roll back.
BEGIN;
CREATE TEMP TABLE aa04_results (name text, ok boolean);
CREATE FUNCTION pg_temp.check(p_name text, p_ok boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO aa04_results VALUES (p_name, p_ok);
  RAISE NOTICE '%: %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, p_name;
END;
$$;
CREATE FUNCTION pg_temp.claim(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
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
CREATE FUNCTION pg_temp.fixture(p_id uuid, p_role text, p_name text, p_active boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (instance_id, id, aud, role, email, created_at, updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000', p_id, 'authenticated', 'authenticated',
          p_id::text || '@aa04.test', now(), now());
  INSERT INTO public.users (id, email, full_name, phone, role, barangay, city, is_active, created_at)
  VALUES (p_id, p_id::text || '@aa04.test', p_name, '09000000000', p_role,
          'Santa Ana', 'Pateros', p_active, '2026-01-01 00:00:00+00');
END;
$$;

DO $$
DECLARE
  v_admin uuid := gen_random_uuid();
  v_inactive uuid := gen_random_uuid();
  v_worker uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_literal uuid := gen_random_uuid();
  v_row record;
  v_denied boolean;
  v_i integer;
  v_uid uuid;
  v_case record;
BEGIN
  PERFORM pg_temp.fixture(v_admin, 'administrator', 'AA04 Admin');
  PERFORM pg_temp.fixture(v_inactive, 'administrator', 'AA04 Inactive Admin', false);
  FOR v_i IN 1..51 LOOP
    v_uid := gen_random_uuid();
    IF v_i = 1 THEN v_worker := v_uid; END IF;
    PERFORM pg_temp.fixture(v_uid, 'worker', 'AA04 Worker ' || lpad(v_i::text, 3, '0'));
  END LOOP;
  INSERT INTO public.worker_profiles (user_id, is_verified, availability_status)
  VALUES (v_worker, true, 'available');
  PERFORM pg_temp.fixture(v_client, 'client', 'AA04 Client');
  PERFORM pg_temp.fixture(v_literal, 'client', E'AA04 %_\\ Literal');
  UPDATE public.users SET is_active = NULL WHERE id = v_client;
  -- GAP-002 permits an unrelated profile; directory role comes from users.
  INSERT INTO public.worker_profiles (user_id) VALUES (v_client);

  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_worker_directory('AA04 Worker');
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('default page and count',
    v_row.total_count = 51 AND v_row.page = 1 AND v_row.page_size = 20
    AND jsonb_array_length(v_row.items) = 20);
  PERFORM pg_temp.check('worker response keys only',
    (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(v_row.items->0) AS key)
    = ARRAY['availability_status','created_at','full_name','has_profile','is_active',
            'is_verified','user_id']::text[]);
  PERFORM pg_temp.check('worker role separation',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_row.items) AS item
                WHERE item->>'user_id' = v_client::text));
  PERFORM pg_temp.check('created-at tie uses UUID descending',
    v_row.items->0->>'user_id' = (
      SELECT id::text FROM public.users WHERE role = 'worker' AND full_name LIKE 'AA04 Worker%'
      ORDER BY id DESC LIMIT 1));

  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_worker_directory('AA04 Worker', 2, 50);
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('exact boundary and final partial page',
    v_row.total_count = 51 AND jsonb_array_length(v_row.items) = 1);
  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_worker_directory('AA04 Worker', 3, 50);
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('beyond end keeps count', v_row.total_count = 51 AND v_row.items = '[]'::jsonb);
  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_worker_directory('AA04 Worker', 1, 1);
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('page size one', v_row.total_count = 51 AND jsonb_array_length(v_row.items) = 1);
  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_worker_directory('worker 001', 1, 20);
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('case-insensitive substring and profile metadata',
    v_row.total_count = 1 AND v_row.items->0->>'user_id' = v_worker::text
    AND v_row.items->0->>'has_profile' = 'true'
    AND v_row.items->0->>'is_verified' = 'true');
  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_worker_directory('Worker 002');
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('missing profile remains and nulls are explicit',
    v_row.total_count = 1 AND v_row.items->0->>'has_profile' = 'false'
    AND v_row.items->0->'is_verified' = 'null'::jsonb
    AND v_row.items->0->'availability_status' = 'null'::jsonb);

  FOR v_case IN SELECT * FROM (VALUES ('%', 1), ('_', 1), (E'\\', 1),
                                    (E' aa04 %_\\ literal ', 1), ('AA04 no match', 0)) AS x(term, expected) LOOP
    PERFORM pg_temp.claim(v_admin);
    SELECT * INTO v_row FROM public.get_admin_client_directory(v_case.term);
    PERFORM pg_temp.clear_claim();
    PERFORM pg_temp.check('literal search ' || v_case.term, v_row.total_count = v_case.expected);
  END LOOP;
  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_client_directory('AA04 Client');
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('client role separation and approved keys',
    v_row.total_count = 1 AND v_row.items->0->>'user_id' = v_client::text
    AND v_row.items->0->>'is_active' = 'false'
    AND (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(v_row.items->0) AS key)
      = ARRAY['created_at','full_name','is_active','user_id']::text[]);
  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_client_directory(NULL);
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('null search has no filter',
    v_row.total_count = (SELECT count(*) FROM public.users WHERE role = 'client'));
  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_client_directory('   ');
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('blank trimmed search has no filter',
    v_row.total_count = (SELECT count(*) FROM public.users WHERE role = 'client'));
  PERFORM pg_temp.claim(v_admin);
  SELECT * INTO v_row FROM public.get_admin_client_directory(repeat('x', 100));
  PERFORM pg_temp.clear_claim();
  PERFORM pg_temp.check('100-character search accepted', v_row.total_count = 0 AND v_row.items = '[]'::jsonb);

  -- Exercise both RPCs against the same ECMAScript trim/code-point boundary.
  FOR v_i IN 1..2 LOOP
    PERFORM pg_temp.claim(v_admin);
    IF v_i = 1 THEN
      SELECT * INTO v_row FROM public.get_admin_worker_directory(E'\t\nAA04 Worker 001\r\n');
    ELSE
      SELECT * INTO v_row FROM public.get_admin_client_directory(E'\t\nAA04 Client\r\n');
    END IF;
    PERFORM pg_temp.clear_claim();
    PERFORM pg_temp.check('boundary tabs/newlines match ' || v_i,
      v_row.total_count = 1 AND v_row.items->0->>'user_id' =
        CASE WHEN v_i = 1 THEN v_worker::text ELSE v_client::text END);

    PERFORM pg_temp.claim(v_admin);
    IF v_i = 1 THEN
      SELECT * INTO v_row FROM public.get_admin_worker_directory(E' \t\n\r\f');
    ELSE
      SELECT * INTO v_row FROM public.get_admin_client_directory(E' \t\n\r\f');
    END IF;
    PERFORM pg_temp.clear_claim();
    PERFORM pg_temp.check('boundary whitespace only has no filter ' || v_i,
      v_row.total_count = (SELECT count(*) FROM public.users
                           WHERE role = CASE WHEN v_i = 1 THEN 'worker' ELSE 'client' END));

    FOR v_case IN SELECT * FROM (VALUES
      ('trim before 100-character limit', E'\t' || repeat('x', 100) || E'\n'),
      ('100 supplementary characters', repeat(U&'\+01F600', 100))
    ) AS x(name, term) LOOP
      PERFORM pg_temp.claim(v_admin);
      IF v_i = 1 THEN
        SELECT * INTO v_row FROM public.get_admin_worker_directory(v_case.term);
      ELSE
        SELECT * INTO v_row FROM public.get_admin_client_directory(v_case.term);
      END IF;
      PERFORM pg_temp.clear_claim();
      PERFORM pg_temp.check(v_case.name || ' accepted ' || v_i,
        v_row.total_count = 0 AND v_row.items = '[]'::jsonb);
    END LOOP;

    FOR v_case IN SELECT * FROM (VALUES
      ('101 characters after trimming', E'\t' || repeat('x', 101) || E'\n'),
      ('101 supplementary characters', repeat(U&'\+01F600', 101))
    ) AS x(name, term) LOOP
      v_denied := false;
      BEGIN
        PERFORM pg_temp.claim(v_admin);
        IF v_i = 1 THEN
          PERFORM public.get_admin_worker_directory(v_case.term);
        ELSE
          PERFORM public.get_admin_client_directory(v_case.term);
        END IF;
      EXCEPTION WHEN SQLSTATE '22023' THEN v_denied := true;
      END;
      PERFORM pg_temp.clear_claim();
      PERFORM pg_temp.check(v_case.name || ' rejected ' || v_i, v_denied);
    END LOOP;
  END LOOP;

  FOR v_case IN SELECT * FROM (VALUES
    ('search too long', repeat('x', 101), 1, 20),
    ('page zero', '', 0, 20), ('page size zero', '', 1, 0),
    ('page size 51', '', 1, 51), ('null page', '', NULL::integer, 20),
    ('null page size', '', 1, NULL::integer)
  ) AS x(name, term, page, size) LOOP
    v_denied := false;
    BEGIN
      PERFORM pg_temp.claim(v_admin);
      PERFORM public.get_admin_client_directory(v_case.term, v_case.page, v_case.size);
    EXCEPTION WHEN SQLSTATE '22023' THEN v_denied := true;
    END;
    PERFORM pg_temp.clear_claim();
    PERFORM pg_temp.check(v_case.name || ' invalid', v_denied);
  END LOOP;

  FOR v_case IN SELECT * FROM (VALUES
    ('Worker', v_worker), ('Client', v_client), ('inactive Admin', v_inactive),
    ('signed out', NULL::uuid)
  ) AS x(name, uid) LOOP
    FOR v_i IN 1..2 LOOP
      v_denied := false;
      BEGIN
        IF v_case.uid IS NULL THEN
          PERFORM pg_temp.clear_claim();
          SET LOCAL ROLE anon;
        ELSE
          PERFORM pg_temp.claim(v_case.uid);
        END IF;
        IF v_i = 1 THEN
          PERFORM public.get_admin_worker_directory(repeat('x', 101), 0, 0);
        ELSE
          PERFORM public.get_admin_client_directory(repeat('x', 101), 0, 0);
        END IF;
      EXCEPTION WHEN SQLSTATE '42501' THEN v_denied := true;
      END;
      PERFORM pg_temp.clear_claim();
      PERFORM pg_temp.check(v_case.name || ' denied by ' ||
        CASE WHEN v_i = 1 THEN 'Worker' ELSE 'Client' END || ' RPC before validation', v_denied);
    END LOOP;
  END LOOP;
  PERFORM pg_temp.check('narrow ACLs',
    has_function_privilege('authenticated', 'public.get_admin_worker_directory(text,integer,integer)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.get_admin_client_directory(text,integer,integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_admin_worker_directory(text,integer,integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_admin_client_directory(text,integer,integer)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.get_admin_worker_directory(text,integer,integer)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.get_admin_client_directory(text,integer,integer)', 'EXECUTE'));
  PERFORM pg_temp.check('function owner and security metadata',
    (SELECT count(*) = 2 FROM pg_proc AS p
     JOIN pg_namespace AS n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('get_admin_worker_directory', 'get_admin_client_directory')
       AND p.proowner = 'postgres'::regrole AND p.provolatile = 's'
       AND p.prosecdef AND p.proconfig @> ARRAY['search_path=""']::text[]));
END;
$$;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM aa04_results WHERE NOT ok OR ok IS NULL) THEN
    RAISE EXCEPTION 'AA-04 failed checks';
  END IF;
  RAISE NOTICE 'AA-04 % checks passed', (SELECT count(*) FROM aa04_results);
END;
$$;
ABORT;
