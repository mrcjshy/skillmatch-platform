-- REG-02 local SQL verification: Client home pin, optional Client account type, completion.
-- Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE reg02_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON reg02_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO reg02_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
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

CREATE OR REPLACE FUNCTION pg_temp.state(p_sql text, p_uid uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  IF p_uid IS NOT NULL THEN PERFORM pg_temp.jwt(p_uid); END IF;
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE; END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.as_json(p_sql text, p_uid uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.jwt(p_uid);
  EXECUTE p_sql INTO v;
  PERFORM pg_temp.clear_jwt();
  RETURN v;
END;
$$;


DO $$
DECLARE u uuid;
BEGIN
  FOREACH u IN ARRAY ARRAY['03030303-0000-4000-8000-000000000001'::uuid, '03030303-0000-4000-8000-000000000002'::uuid, '03030303-0000-4000-8000-000000000003'::uuid] LOOP
    INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    VALUES ('00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated','reg02-'||right(u::text,2)||'@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  END LOOP;
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    ('03030303-0000-4000-8000-000000000001','reg02-01@example.test','Ana Santos','09210000001','client','Santa Ana','Pateros',true),
    ('03030303-0000-4000-8000-000000000002','reg02-02@example.test','Juan Cruz','09210000002','worker','Santa Ana','Pateros',true),
    ('03030303-0000-4000-8000-000000000003','reg02-03@example.test','Off Client','09210000003','client','Santa Ana','Pateros',false);
END;
$$;

DO $$
DECLARE
  client uuid := '03030303-0000-4000-8000-000000000001';
  worker uuid := '03030303-0000-4000-8000-000000000002';
  inactive uuid := '03030303-0000-4000-8000-000000000003';
  ring double precision[][];
  inside_lat double precision := 0;
  inside_lng double precision := 0;
  n integer;
  s text;
  r jsonb;
BEGIN
  -- A point inside the official ring: the mean of its vertices (the ring is convex enough here),
  -- confirmed by the same point-in-polygon check the RPC uses.
  ring := private.santa_ana_pateros_boundary_ring();
  n := array_length(ring, 1);
  FOR i IN 1..n LOOP
    inside_lng := inside_lng + ring[i][1] / n;
    inside_lat := inside_lat + ring[i][2] / n;
  END LOOP;
  PERFORM pg_temp.pass(1, 'fixture point is inside the service area', private.point_in_service_area_ring(inside_lng, inside_lat), inside_lat || ',' || inside_lng);

  s := pg_temp.state(format('SELECT public.save_my_home_location(%s, %s)', inside_lat, inside_lng), worker);
  PERFORM pg_temp.pass(2, 'Worker cannot save a home pin: 42501', s = '42501', s);
  s := pg_temp.state(format('SELECT public.save_my_home_location(%s, %s)', inside_lat, inside_lng), inactive);
  PERFORM pg_temp.pass(3, 'inactive Client cannot save a home pin: 42501', s = '42501', s);
  s := pg_temp.state('SELECT public.save_my_home_location(14.6, 121.2)', client);
  PERFORM pg_temp.pass(4, 'pin outside Santa Ana: 22023', s = '22023', s);
  s := pg_temp.state($q$SELECT public.save_my_home_location('NaN'::float8, 121.07)$q$, client);
  PERFORM pg_temp.pass(5, 'non-finite pin: 22023', s = '22023', s);
  PERFORM pg_temp.pass(6, 'denials stored nothing', (SELECT home_latitude IS NULL FROM public.users WHERE id = client));

  r := pg_temp.as_json($q$SELECT to_jsonb(r) FROM public.save_my_profile_details('Ana', NULL, 'Santos', NULL, '5 B. Morcilla', 'Santa Ana', 'Pateros', 'Metro Manila', NULL, NULL) AS r$q$, client);
  PERFORM pg_temp.pass(7, 'Client details save with no account type', r->>'profile_completed_at' IS NOT NULL
    AND (SELECT client_account_type IS NULL AND business_name IS NULL FROM public.users WHERE id = client), r::text);
  s := pg_temp.state($q$SELECT public.save_my_profile_details('Ana', NULL, 'Santos', NULL, 'x', 'Santa Ana', 'Pateros', 'Metro Manila', 'company', NULL)$q$, client);
  PERFORM pg_temp.pass(8, 'an invalid account type is still rejected: 22023', s = '22023', s);
  s := pg_temp.state($q$SELECT public.save_my_profile_details('Ana', NULL, 'Santos', NULL, 'x', 'Santa Ana', 'Pateros', 'Metro Manila', 'business', NULL)$q$, client);
  PERFORM pg_temp.pass(9, 'a business without a name is still rejected: 22023', s = '22023', s);

  PERFORM pg_temp.pass(10, 'Client without a home pin is not complete',
    pg_temp.as_json('SELECT to_jsonb(r) FROM public.get_my_profile_completion() AS r', client) = '{"profile_complete":false,"resume_complete":true}'::jsonb);

  r := pg_temp.as_json(format('SELECT to_jsonb(r) FROM public.save_my_home_location(%s, %s) AS r', inside_lat, inside_lng), client);
  PERFORM pg_temp.pass(11, 'Client saves a home pin inside Santa Ana',
    abs((r->>'home_latitude')::float8 - inside_lat) < 1e-12 AND abs((r->>'home_longitude')::float8 - inside_lng) < 1e-12, r::text);
  PERFORM pg_temp.pass(12, 'Client with details and pin is complete',
    pg_temp.as_json('SELECT to_jsonb(r) FROM public.get_my_profile_completion() AS r', client) = '{"profile_complete":true,"resume_complete":true}'::jsonb);

  s := pg_temp.state(format('UPDATE public.users SET home_longitude = NULL WHERE id = %L', client), client);
  PERFORM pg_temp.pass(13, 'a half pin is rejected: 23514', s = '23514', s);

  PERFORM pg_temp.pass(14, 'grants: authenticated only',
    has_function_privilege('authenticated', 'public.save_my_home_location(double precision,double precision)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.save_my_home_location(double precision,double precision)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.save_my_profile_details(text,text,text,text,text,text,text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.save_my_profile_details(text,text,text,text,text,text,text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_my_profile_completion()', 'EXECUTE'));
  PERFORM pg_temp.pass(15, 'public application table count stays 13 (D-001)',
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') = 13);
END;
$$;

DO $$
DECLARE failed integer;
BEGIN
  SELECT count(*) INTO failed FROM reg02_results WHERE NOT ok;
  IF failed <> 0 THEN RAISE EXCEPTION 'REG-02 failed % assertions', failed; END IF;
  RAISE NOTICE 'REG-02: % assertions passed', (SELECT count(*) FROM reg02_results);
END;
$$;

ROLLBACK;
