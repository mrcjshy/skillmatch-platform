-- ADM-01 local SQL verification: Admin directory status filter and Worker strikes. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE adm01_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON adm01_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO adm01_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.jwt(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('role', 'authenticated', true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.clear_jwt()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('role', 'postgres', true);
  RESET ROLE;
END;
$$;

-- Runs p_sql as p_uid (or as anon when p_anon) and returns its SQLSTATE.
CREATE OR REPLACE FUNCTION pg_temp.state(p_sql text, p_uid uuid DEFAULT NULL, p_anon boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  IF p_uid IS NOT NULL THEN PERFORM pg_temp.jwt(p_uid);
  ELSIF p_anon THEN PERFORM set_config('role', 'anon', true);
  END IF;
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE; END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

-- Runs one directory function as p_uid and returns its single row as jsonb.
CREATE OR REPLACE FUNCTION pg_temp.dir(p_uid uuid, p_sql text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  EXECUTE format('SELECT to_jsonb(r) FROM (%s) AS r', p_sql) INTO v;
  PERFORM pg_temp.clear_jwt();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.names(p jsonb)
RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(e->>'full_name', ',' ORDER BY e->>'full_name'), '') FROM jsonb_array_elements(p->'items') AS e;
$$;

CREATE OR REPLACE FUNCTION pg_temp.keys(p jsonb)
RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(p->'items'->0) AS k;
$$;

DO $$
DECLARE
  admin_one uuid := '0adb0101-0000-4000-8000-000000000001';
  admin_off uuid := '0adb0101-0000-4000-8000-000000000002';
  client_on uuid := '0adb0101-0000-4000-8000-000000000003';
  client_off uuid := '0adb0101-0000-4000-8000-000000000004';
  worker_on uuid := '0adb0101-0000-4000-8000-000000000005';
  worker_off uuid := '0adb0101-0000-4000-8000-000000000006';
  worker_new uuid := '0adb0101-0000-4000-8000-000000000007';
  u uuid;
  e text;
BEGIN
  FOREACH u IN ARRAY ARRAY[admin_one, admin_off, client_on, client_off, worker_on, worker_off, worker_new] LOOP
    e := 'adm01-' || right(u::text, 2) || '@example.test';
    INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    VALUES ('00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated',e,crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  END LOOP;
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (admin_one,'adm01-01@example.test','ADM01 Admin','09190000101','administrator','Santa Ana','Pateros',true),
    (admin_off,'adm01-02@example.test','ADM01 Inactive Admin','09190000102','administrator','Santa Ana','Pateros',false),
    (client_on,'adm01-03@example.test','ADM01 Client Active','09190000103','client','Santa Ana','Pateros',true),
    (client_off,'adm01-04@example.test','ADM01 Client Banned','09190000104','client','Santa Ana','Pateros',false),
    (worker_on,'adm01-05@example.test','ADM01 Worker Active','09190000105','worker','Santa Ana','Pateros',true),
    (worker_off,'adm01-06@example.test','ADM01 Worker Suspended','09190000106','worker','Santa Ana','Pateros',false),
    (worker_new,'adm01-07@example.test','ADM01 Worker No Profile','09190000107','worker','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified) VALUES
    ('0adb0101-1000-4000-8000-000000000005',worker_on,'fixture','none','available',true),
    ('0adb0101-1000-4000-8000-000000000006',worker_off,'fixture','none','busy',true);
  UPDATE public.worker_profiles SET strike_count = 1 WHERE user_id = worker_on;
  UPDATE public.worker_profiles SET strike_count = 3 WHERE user_id = worker_off;
END;
$$;

DO $$
DECLARE
  admin_one uuid := '0adb0101-0000-4000-8000-000000000001';
  admin_off uuid := '0adb0101-0000-4000-8000-000000000002';
  client_on uuid := '0adb0101-0000-4000-8000-000000000003';
  worker_on uuid := '0adb0101-0000-4000-8000-000000000005';
  s text;
  r jsonb;
  w jsonb;
BEGIN
  -- ---------- Authorization ----------
  s := pg_temp.state('SELECT * FROM public.get_admin_worker_directory_v2(''ADM01'',1,20,''all'')', worker_on);
  PERFORM pg_temp.pass(1, 'Worker cannot read the v2 Worker directory: 42501', s = '42501', s);
  s := pg_temp.state('SELECT * FROM public.get_admin_client_directory_v2(''ADM01'',1,20,''all'')', client_on);
  PERFORM pg_temp.pass(2, 'Client cannot read the v2 Client directory: 42501', s = '42501', s);
  s := pg_temp.state('SELECT * FROM public.get_admin_worker_directory_v2(''ADM01'',1,20,''all'')', admin_off);
  PERFORM pg_temp.pass(3, 'inactive Administrator cannot read: 42501', s = '42501', s);
  s := pg_temp.state('SELECT * FROM public.get_admin_client_directory_v2(''ADM01'',1,20,''all'')', NULL, true);
  PERFORM pg_temp.pass(4, 'anon cannot execute: 42501', s = '42501', s);

  -- ---------- Input ----------
  s := pg_temp.state('SELECT * FROM public.get_admin_worker_directory_v2(''ADM01'',1,20,''banned'')', admin_one);
  PERFORM pg_temp.pass(5, 'unknown status value: 22023', s = '22023', s);
  s := pg_temp.state('SELECT * FROM public.get_admin_client_directory_v2(''ADM01'',1,20,NULL)', admin_one);
  PERFORM pg_temp.pass(6, 'NULL status: 22023', s = '22023', s);
  s := pg_temp.state('SELECT * FROM public.get_admin_worker_directory_v2(''ADM01'',1,51,''all'')', admin_one);
  PERFORM pg_temp.pass(7, 'page size 51 still refused: 22023', s = '22023', s);
  s := pg_temp.state(format('SELECT * FROM public.get_admin_worker_directory_v2(%L,1,20,''all'')', repeat('a', 101)), admin_one);
  PERFORM pg_temp.pass(8, '101-character search still refused: 22023', s = '22023', s);

  -- ---------- Worker directory ----------
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_worker_directory_v2(''ADM01'')');
  PERFORM pg_temp.pass(9, 'default status is all: every fixture Worker',
    (r->>'total_count')::int = 3 AND pg_temp.names(r) = 'ADM01 Worker Active,ADM01 Worker No Profile,ADM01 Worker Suspended', r::text);
  PERFORM pg_temp.pass(10, 'Worker rows carry exactly the v1 keys plus strike_count',
    pg_temp.keys(r) = 'availability_status,created_at,full_name,has_profile,is_active,is_verified,strike_count,user_id', pg_temp.keys(r));
  SELECT e INTO w FROM jsonb_array_elements(r->'items') AS e WHERE e->>'full_name' = 'ADM01 Worker Suspended';
  PERFORM pg_temp.pass(11, 'suspended Worker shows 3 strikes and inactive',
    (w->>'strike_count')::int = 3 AND (w->>'is_active')::boolean = false, w::text);
  SELECT e INTO w FROM jsonb_array_elements(r->'items') AS e WHERE e->>'full_name' = 'ADM01 Worker Active';
  PERFORM pg_temp.pass(12, 'active Worker shows 1 strike', (w->>'strike_count')::int = 1, w::text);
  SELECT e INTO w FROM jsonb_array_elements(r->'items') AS e WHERE e->>'full_name' = 'ADM01 Worker No Profile';
  PERFORM pg_temp.pass(13, 'Worker without a profile has null strikes and null profile fields',
    w->'strike_count' = 'null'::jsonb AND (w->>'has_profile')::boolean = false AND w->'is_verified' = 'null'::jsonb, w::text);

  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_worker_directory_v2(''ADM01'',1,20,''active'')');
  PERFORM pg_temp.pass(14, 'active filter: active Workers only',
    (r->>'total_count')::int = 2 AND pg_temp.names(r) = 'ADM01 Worker Active,ADM01 Worker No Profile', r::text);
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_worker_directory_v2(''ADM01'',1,20,''inactive'')');
  PERFORM pg_temp.pass(15, 'inactive filter: banned or suspended Workers only',
    (r->>'total_count')::int = 1 AND pg_temp.names(r) = 'ADM01 Worker Suspended', r::text);
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_worker_directory_v2(''Profile'',1,20,''active'')');
  PERFORM pg_temp.pass(16, 'search and filter combine', pg_temp.names(r) = 'ADM01 Worker No Profile', r::text);
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_worker_directory_v2(''ADM01'',2,2,''all'')');
  PERFORM pg_temp.pass(17, 'paging keeps the total and returns the remainder',
    (r->>'total_count')::int = 3 AND jsonb_array_length(r->'items') = 1 AND (r->>'page')::int = 2, r::text);

  -- ---------- Client directory ----------
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_client_directory_v2(''ADM01'',1,20,''all'')');
  PERFORM pg_temp.pass(18, 'Client all: both fixture Clients with the v1 keys',
    (r->>'total_count')::int = 2 AND pg_temp.keys(r) = 'created_at,full_name,is_active,user_id', r::text);
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_client_directory_v2(''ADM01'',1,20,''inactive'')');
  PERFORM pg_temp.pass(19, 'Client inactive filter', pg_temp.names(r) = 'ADM01 Client Banned', r::text);
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_client_directory_v2(''ADM01'',1,20,''active'')');
  PERFORM pg_temp.pass(20, 'Client active filter', pg_temp.names(r) = 'ADM01 Client Active', r::text);

  -- ---------- v1 compatibility (installed builds) ----------
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_worker_directory(''ADM01'',1,20)');
  PERFORM pg_temp.pass(21, 'v1 Worker directory unchanged: same keys, no strike_count, all statuses',
    pg_temp.keys(r) = 'availability_status,created_at,full_name,has_profile,is_active,is_verified,user_id'
    AND (r->>'total_count')::int = 3, pg_temp.keys(r));
  r := pg_temp.dir(admin_one, 'SELECT * FROM public.get_admin_client_directory(''ADM01'',1,20)');
  PERFORM pg_temp.pass(22, 'v1 Client directory unchanged',
    pg_temp.keys(r) = 'created_at,full_name,is_active,user_id' AND (r->>'total_count')::int = 2, pg_temp.keys(r));

  -- ---------- Function properties ----------
  PERFORM pg_temp.pass(23, 'v2 functions: authenticated only',
    has_function_privilege('authenticated', 'public.get_admin_worker_directory_v2(text,integer,integer,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_admin_worker_directory_v2(text,integer,integer,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.get_admin_worker_directory_v2(text,integer,integer,text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.get_admin_client_directory_v2(text,integer,integer,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_admin_client_directory_v2(text,integer,integer,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.get_admin_client_directory_v2(text,integer,integer,text)', 'EXECUTE'));
  PERFORM pg_temp.pass(24, 'v2 functions: SECURITY DEFINER, STABLE, empty search_path',
    (SELECT bool_and(prosecdef AND provolatile = 's' AND proconfig = ARRAY['search_path=""'])
       FROM pg_proc WHERE oid IN ('public.get_admin_worker_directory_v2(text,integer,integer,text)'::regprocedure,
                                  'public.get_admin_client_directory_v2(text,integer,integer,text)'::regprocedure)));
  PERFORM pg_temp.pass(25, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM adm01_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'ADM-01 failed % assertions', failed; END IF;
  RAISE NOTICE 'ADM-01: % assertions passed', (SELECT count(*) FROM adm01_results);
END;
$$;

ROLLBACK;
