-- V3-DB4 local SQL verification: Santa Ana geofence, INSERT bypass, title, description.
--
-- Seams:
--   official ring identity: 153 vertices including close, 152 unique
--   exact 8-decimal bbox (not a BETWEEN band)
--   serialized-ring djb2 fingerprint 626f7138
--   inside Santa Ana PASS
--   outside Santa Ana DENY
--   boundary vertex PASS
--   direct job_postings INSERT denied for authenticated
--   description required
--   title derived from primary required skill
--   matching fingerprints unchanged
--
-- Disposable fixtures only. ABORT so nothing survives.

BEGIN;

CREATE TEMP TABLE v3_db4_results (
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
  INSERT INTO v3_db4_results(n, name, ok, detail)
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
  p_role text
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
    p_user_id, 'authenticated', 'authenticated', p_email,
    crypt('v3-db4-local', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb, now(), now()
  );
  INSERT INTO public.users (
    id, email, full_name, phone, role, barangay, city, is_active
  ) VALUES (
    p_user_id, p_email, 'V3 DB4 Fixture', '09000000000', p_role,
    'Santa Ana', 'Pateros', true
  );
END;
$$;

-- FM999990.00000000 strips trailing zeros; trim of 999990.00000000 keeps
-- the locked 8-decimal literals (e.g. 121.06715730).
CREATE OR REPLACE FUNCTION pg_temp.coord8(p_val double precision)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT trim(both from to_char(round(p_val::numeric, 8), '999990.00000000'));
$$;

-- JS Number.toFixed(10) equivalent for the official ring serialization.
CREATE OR REPLACE FUNCTION pg_temp.coord10(p_val double precision)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT trim(both from to_char(round(p_val::numeric, 10), '999990.0000000000'));
$$;

-- JS djb2: hash = ((hash << 5) + hash + charCode) >>> 0
CREATE OR REPLACE FUNCTION pg_temp.js_djb2_hex(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_hash bigint := 5381;
  v_i integer;
  v_c integer;
  v_shifted_u bigint;
  v_shifted_s bigint;
  v_sum bigint;
BEGIN
  FOR v_i IN 1..char_length(p_value) LOOP
    v_c := ascii(substr(p_value, v_i, 1));
    v_shifted_u := (v_hash << 5) & 4294967295;
    IF v_shifted_u >= 2147483648 THEN
      v_shifted_s := v_shifted_u - 4294967296;
    ELSE
      v_shifted_s := v_shifted_u;
    END IF;
    v_sum := v_shifted_s + v_hash + v_c;
    v_hash := v_sum % 4294967296;
    IF v_hash < 0 THEN
      v_hash := v_hash + 4294967296;
    END IF;
  END LOOP;
  RETURN lpad(to_hex(v_hash), 8, '0');
END;
$$;

DO $$
DECLARE
  client_own   uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01';
  client_other uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02';
  skill_id     uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddd01';
  job_in       uuid;
  v_title      text;
  v_desc       text;
  v_count      int;
  v_hash       text;
  v_n          int;
  v_unique     int;
  v_xmin       double precision;
  v_ymin       double precision;
  v_xmax       double precision;
  v_ymax       double precision;
  v_xmin_s     text;
  v_ymin_s     text;
  v_xmax_s     text;
  v_ymax_s     text;
  v_serial     text;
  v_fp         text;
  v_vx         double precision;
  v_vy         double precision;
  v_ring       double precision[][];
  -- Official COD-AB display centroid: interior proof pin only, not the geofence.
  lat_in       constant double precision := 14.54445140;
  lng_in       constant double precision := 121.07205067;
  lat_out      constant double precision := 14.55801;
  lng_out      constant double precision := 121.06942;
BEGIN
  PERFORM pg_temp.mk_user(client_own, 'v3db4-cown@example.test', 'client');
  PERFORM pg_temp.mk_user(client_other, 'v3db4-coth@example.test', 'client');
  INSERT INTO public.skills (id, skill_name, category)
  VALUES (skill_id, 'V3 DB4 Carpentry', 'trade');

  SELECT array_length(private.santa_ana_pateros_boundary_ring(), 1) INTO v_n;
  PERFORM pg_temp.pass(1, 'official ring has 153 vertices including close',
    v_n = 153, coalesce(v_n::text, 'null'));

  v_ring := private.santa_ana_pateros_boundary_ring();
  SELECT count(*) INTO v_unique
  FROM (
    SELECT DISTINCT v_ring[i][1], v_ring[i][2]
    FROM generate_subscripts(v_ring, 1) AS i
  ) u;
  PERFORM pg_temp.pass(21, 'official ring has 152 unique vertices',
    v_unique = 152, coalesce(v_unique::text, 'null'));

  SELECT min(v_ring[i][1]), min(v_ring[i][2]), max(v_ring[i][1]), max(v_ring[i][2])
    INTO v_xmin, v_ymin, v_xmax, v_ymax
  FROM generate_subscripts(v_ring, 1) AS i;
  v_xmin_s := pg_temp.coord8(v_xmin);
  v_ymin_s := pg_temp.coord8(v_ymin);
  v_xmax_s := pg_temp.coord8(v_xmax);
  v_ymax_s := pg_temp.coord8(v_ymax);
  PERFORM pg_temp.pass(2, 'ring bbox matches COD-AB Santa Ana at 8 decimals',
    v_xmin_s = '121.06715730'
    AND v_ymin_s = '14.54026308'
    AND v_xmax_s = '121.07805766'
    AND v_ymax_s = '14.54868468',
    format('%s,%s,%s,%s', v_xmin_s, v_ymin_s, v_xmax_s, v_ymax_s));

  SELECT string_agg(
           pg_temp.coord10(v_ring[i][1]) || ',' || pg_temp.coord10(v_ring[i][2]),
           ';' ORDER BY i
         )
    INTO v_serial
  FROM generate_subscripts(v_ring, 1) AS i;
  v_fp := pg_temp.js_djb2_hex(v_serial);
  PERFORM pg_temp.pass(22, 'official ring djb2 fingerprint',
    v_fp = '626f7138', coalesce(v_fp, 'null'));

  PERFORM pg_temp.pass(3, 'display centroid is inside the polygon',
    private.point_in_service_area_ring(lng_in, lat_in));

  PERFORM pg_temp.pass(4, 'legacy R5E pin is outside the polygon',
    NOT private.point_in_service_area_ring(lng_out, lat_out));

  v_vx := v_ring[1][1];
  v_vy := v_ring[1][2];
  PERFORM pg_temp.pass(5, 'boundary vertex counts as inside',
    private.point_in_service_area_ring(v_vx, v_vy),
    coalesce(v_vx::text, 'null') || ',' || coalesce(v_vy::text, 'null'));

  -- 6 inside create PASS
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    job_in := public.create_my_job_with_location(
      'ignored caller title',
      'Repair a cabinet in Santa Ana.',
      '12 Test Street',
      now() + interval '2 days',
      500,
      'cod',
      ARRAY[skill_id],
      lat_in,
      lng_in
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'inside Santa Ana create PASS',
      job_in IS NOT NULL, coalesce(job_in::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(6, 'inside Santa Ana create PASS',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  SELECT title, description INTO v_title, v_desc
  FROM public.job_postings WHERE id = job_in;
  PERFORM pg_temp.pass(7, 'title is derived from primary skill name',
    v_title = 'V3 DB4 Carpentry', coalesce(v_title, 'null'));
  PERFORM pg_temp.pass(8, 'required description is persisted',
    v_desc = 'Repair a cabinet in Santa Ana.', coalesce(v_desc, 'null'));

  -- 9 outside DENY
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'x', 'outside pin', '12 Test Street', now() + interval '2 days',
      500, 'cod', ARRAY[skill_id], lat_out, lng_out);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'outside Santa Ana create DENY', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(9, 'outside Santa Ana create DENY',
      SQLSTATE = '22023', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 10 empty description DENY
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'x', '   ', '12 Test Street', now() + interval '2 days',
      500, 'cod', ARRAY[skill_id], lat_in, lng_in);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'blank description DENY', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(10, 'blank description DENY',
      SQLSTATE = '22023', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 11 boundary vertex create PASS
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.create_my_job_with_location(
      'x', 'boundary pin', '12 Test Street', now() + interval '2 days',
      500, 'cod', ARRAY[skill_id], v_vy, v_vx);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'boundary vertex create PASS', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(11, 'boundary vertex create PASS',
      false, SQLSTATE || ' ' || SQLERRM);
  END;

  -- 12 outside update DENY
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    PERFORM public.update_my_open_job_location(job_in, 'moved', lat_out, lng_out);
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'outside Santa Ana update DENY', false, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(12, 'outside Santa Ana update DENY',
      SQLSTATE = '22023', SQLSTATE || ' ' || SQLERRM);
  END;

  -- 13 authenticated INSERT bypass denied
  BEGIN
    PERFORM pg_temp.jwt(client_own);
    SET LOCAL ROLE authenticated;
    INSERT INTO public.job_postings (
      client_id, title, description, address, barangay, city, payment_method
    ) VALUES (
      client_own, 'bypass', 'bypass', '1 Street', 'Santa Ana', 'Pateros', 'cod'
    );
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'authenticated direct job_postings INSERT denied',
      false, 'insert succeeded');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'authenticated direct job_postings INSERT denied',
      true, SQLSTATE);
  WHEN OTHERS THEN
    PERFORM pg_temp.clear_jwt();
    PERFORM pg_temp.pass(13, 'authenticated direct job_postings INSERT denied',
      SQLSTATE = '42501', SQLSTATE || ' ' || SQLERRM);
  END;

  PERFORM pg_temp.pass(14, 'authenticated INSERT privilege on job_postings revoked',
    NOT has_table_privilege('authenticated', 'public.job_postings', 'INSERT')
    AND NOT has_table_privilege('anon', 'public.job_postings', 'INSERT'));

  -- 15-18 matching fingerprints unchanged
  SELECT md5(pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(15, 'compute_job_matches fingerprint unchanged',
    v_hash = 'b9b686e6b0b9a87ee8618b5600b1ed62', v_hash);
  SELECT md5(pg_get_functiondef('public.match_workers_for_job(uuid)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(16, 'match_workers_for_job fingerprint unchanged',
    v_hash = '9239550ea9da726a3002bb3503d12f73', v_hash);
  SELECT md5(pg_get_functiondef('private.location_points(text,text,text,text)'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(17, 'location_points fingerprint unchanged',
    v_hash = '3da08e1ce3b7b7089ff51285a7c33dae', v_hash);
  SELECT md5(pg_get_functiondef('public.list_my_job_opportunities()'::regprocedure))
    INTO v_hash;
  PERFORM pg_temp.pass(18, 'list_my_job_opportunities fingerprint unchanged',
    v_hash = 'a135ec4ddac213df3f3ef147f93e0fc9', v_hash);

  SELECT private.location_points('Santa Ana', 'Pateros', 'Santa Ana', 'Pateros') INTO v_count;
  PERFORM pg_temp.pass(19, 'location_points still 30 for same barangay+city',
    v_count = 30, v_count::text);

  PERFORM pg_temp.pass(20, 'public application table count remains 13',
    (SELECT count(*) FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r') = 13);
END;
$$;

DO $$
DECLARE
  v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM v3_db4_results WHERE NOT ok;
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'V3-DB4 FAILED % case(s)', v_fail;
  END IF;
  RAISE NOTICE 'V3-DB4 % / % PASS',
    (SELECT count(*) FROM v3_db4_results WHERE ok),
    (SELECT count(*) FROM v3_db4_results);
END;
$$;

ABORT;
