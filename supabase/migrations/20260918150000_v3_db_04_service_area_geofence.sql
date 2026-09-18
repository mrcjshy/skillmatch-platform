-- ============================================================
-- V3-DB-04: SANTA ANA SERVICE-AREA GEOFENCE + TITLE/DESCRIPTION
-- ============================================================
--
-- SCOPE
-- -----
-- Official NAMRIA/PSA COD-AB (HDX, dataset version 03) Barangay
-- Santa Ana, Pateros boundary is the Job-pin geofence.
--
--   Feature name: Santa Ana (Pateros)
--   COD-AB ADM4 p-code: PH1307606007
--   Current PSA PSGC: 1381701007 (PSA recode of legacy 137606007)
--   Geometry: Polygon, WGS 84 / EPSG:4326
--   Vertices including close: 153
--
-- The official feature ring is the geofence. The shapefile
-- center_lat/center_lon display centroid is NOT the geofence.
--
-- Also in this migration (same RPC owner):
--   * public.create_my_job_with_location derives title from the
--     primary required skill name (p_title kept for 9-arg callers)
--   * Job description is required
--   * authenticated/anon INSERT on public.job_postings is revoked so
--     a Client cannot bypass the geofence
--
-- Matching is untouched. GPS is not a matching input.
-- No hosted deployment.
-- ============================================================


-- ---------- 1. Official ring ----------

CREATE FUNCTION private.santa_ana_pateros_boundary_ring()
RETURNS double precision[][]
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $fn$
  SELECT ARRAY[
ARRAY[121.0739152770,14.5486115600]::double precision[],ARRAY[121.0740378720,14.5484979970]::double precision[],ARRAY[121.0740618600,14.5484084390]::double precision[],ARRAY[121.0740482150,14.5483656250]::double precision[],ARRAY[121.0744552350,14.5481133440]::double precision[],ARRAY[121.0748260490,14.5482162840]::double precision[],ARRAY[121.0749289730,14.5482230430]::double precision[],ARRAY[121.0748895350,14.5479570030]::double precision[],ARRAY[121.0749496940,14.5479347220]::double precision[],ARRAY[121.0750276160,14.5479167840]::double precision[],ARRAY[121.0751145740,14.5478901600]::double precision[],ARRAY[121.0751815280,14.5478734490]::double precision[],ARRAY[121.0752144020,14.5478450580]::double precision[],ARRAY[121.0752517590,14.5478136780]::double precision[],ARRAY[121.0752936000,14.5477852860]::double precision[],ARRAY[121.0753399230,14.5477852860]::double precision[],ARRAY[121.0753982000,14.5477718380]::double precision[],ARRAY[121.0754559860,14.5477490300]::double precision[],ARRAY[121.0755105490,14.5477224480]::double precision[],ARRAY[121.0755525210,14.5476930670]::double precision[],ARRAY[121.0755791030,14.5476608890]::double precision[],ARRAY[121.0756322680,14.5476399030]::double precision[],ARRAY[121.0756966240,14.5476105220]::double precision[],ARRAY[121.0757612350,14.5475847530]::double precision[],ARRAY[121.0758276290,14.5475697610]::double precision[],ARRAY[121.0758854560,14.5475633360]::double precision[],ARRAY[121.0759454250,14.5475590520]::double precision[],ARRAY[121.0760909960,14.5475226690]::double precision[],ARRAY[121.0763534920,14.5473854730]::double precision[],ARRAY[121.0764194480,14.5473415030]::double precision[],ARRAY[121.0764735660,14.5473127530]::double precision[],ARRAY[121.0765141540,14.5472721640]::double precision[],ARRAY[121.0765438760,14.5472399180]::double precision[],ARRAY[121.0765755370,14.5472399180]::double precision[],ARRAY[121.0766359810,14.5472255260]::double precision[],ARRAY[121.0766820340,14.5471881080]::double precision[],ARRAY[121.0767223300,14.5471305420]::double precision[],ARRAY[121.0767712610,14.5470960030]::double precision[],ARRAY[121.0768086790,14.5470585850]::double precision[],ARRAY[121.0768403410,14.5470211670]::double precision[],ARRAY[121.0768662450,14.5469952630]::double precision[],ARRAY[121.0768950280,14.5469693580]::double precision[],ARRAY[121.0769266890,14.5469520880]::double precision[],ARRAY[121.0769525940,14.5469492100]::double precision[],ARRAY[121.0769928900,14.5469204270]::double precision[],ARRAY[121.0770159170,14.5468772520]::double precision[],ARRAY[121.0770533340,14.5468513480]::double precision[],ARRAY[121.0770993870,14.5468139300]::double precision[],ARRAY[121.0771684660,14.5467707550]::double precision[],ARRAY[121.0772490590,14.5467045550]::double precision[],ARRAY[121.0773440420,14.5466297190]::double precision[],ARRAY[121.0774248790,14.5466165680]::double precision[],ARRAY[121.0775869700,14.5466663920]::double precision[],ARRAY[121.0777392270,14.5467512880]::double precision[],ARRAY[121.0778987200,14.5468049480]::double precision[],ARRAY[121.0780234190,14.5468672970]::double precision[],ARRAY[121.0780576600,14.5468941640]::double precision[],ARRAY[121.0774137940,14.5459979930]::double precision[],ARRAY[121.0773025170,14.5459066400]::double precision[],ARRAY[121.0767646550,14.5454623340]::double precision[],ARRAY[121.0763972710,14.5453311260]::double precision[],ARRAY[121.0760430080,14.5452130380]::double precision[],ARRAY[121.0757412280,14.5448456540]::double precision[],ARRAY[121.0756231400,14.5444782700]::double precision[],ARRAY[121.0756013580,14.5444245290]::double precision[],ARRAY[121.0754263270,14.5439927980]::double precision[],ARRAY[121.0751507890,14.5434942050]::double precision[],ARRAY[121.0747309220,14.5432842710]::double precision[],ARRAY[121.0743785080,14.5431103060]::double precision[],ARRAY[121.0741929660,14.5430218540]::double precision[],ARRAY[121.0739277230,14.5429543840]::double precision[],ARRAY[121.0737742850,14.5429151710]::double precision[],ARRAY[121.0735631650,14.5428512830]::double precision[],ARRAY[121.0730645720,14.5426544700]::double precision[],ARRAY[121.0725791000,14.5423658110]::double precision[],ARRAY[121.0720673870,14.5419590640]::double precision[],ARRAY[121.0719878620,14.5417385880]::double precision[],ARRAY[121.0718641070,14.5413870250]::double precision[],ARRAY[121.0717656070,14.5411849340]::double precision[],ARRAY[121.0717123310,14.5411260320]::double precision[],ARRAY[121.0716353960,14.5410407600]::double precision[],ARRAY[121.0715423400,14.5408480000]::double precision[],ARRAY[121.0713961090,14.5406685350]::double precision[],ARRAY[121.0712631710,14.5404358940]::double precision[],ARRAY[121.0710571180,14.5403295440]::double precision[],ARRAY[121.0708842990,14.5402963090]::double precision[],ARRAY[121.0707247730,14.5402763690]::double precision[],ARRAY[121.0705187200,14.5402630750]::double precision[],ARRAY[121.0703791350,14.5402763690]::double precision[],ARRAY[121.0701930230,14.5402963090]::double precision[],ARRAY[121.0699907940,14.5403439930]::double precision[],ARRAY[121.0699271470,14.5403627780]::double precision[],ARRAY[121.0696413310,14.5404425410]::double precision[],ARRAY[121.0694286310,14.5405355970]::double precision[],ARRAY[121.0692159310,14.5406220060]::double precision[],ARRAY[121.0691295220,14.5406751810]::double precision[],ARRAY[121.0689699960,14.5406751810]::double precision[],ARRAY[121.0688104710,14.5407748850]::double precision[],ARRAY[121.0686841800,14.5408014720]::double precision[],ARRAY[121.0686253050,14.5408468030]::double precision[],ARRAY[121.0685941370,14.5408747730]::double precision[],ARRAY[121.0685379490,14.5409211160]::double precision[],ARRAY[121.0683784240,14.5410008790]::double precision[],ARRAY[121.0681657240,14.5410872880]::double precision[],ARRAY[121.0679330830,14.5412002850]::double precision[],ARRAY[121.0673967940,14.5414599930]::double precision[],ARRAY[121.0673047940,14.5415869930]::double precision[],ARRAY[121.0672437940,14.5416669930]::double precision[],ARRAY[121.0671573000,14.5418460130]::double precision[],ARRAY[121.0671907940,14.5419599930]::double precision[],ARRAY[121.0672127940,14.5421269930]::double precision[],ARRAY[121.0681790170,14.5439786820]::double precision[],ARRAY[121.0683320840,14.5441809790]::double precision[],ARRAY[121.0683511590,14.5442096490]::double precision[],ARRAY[121.0685379490,14.5445370200]::double precision[],ARRAY[121.0686083050,14.5446607190]::double precision[],ARRAY[121.0686890520,14.5448928680]::double precision[],ARRAY[121.0687496130,14.5449877460]::double precision[],ARRAY[121.0688833540,14.5451783880]::double precision[],ARRAY[121.0688902340,14.5451884150]::double precision[],ARRAY[121.0690364650,14.5453745280]::double precision[],ARRAY[121.0692434280,14.5456007090]::double precision[],ARRAY[121.0694121960,14.5458032300]::double precision[],ARRAY[121.0695269580,14.5459416200]::double precision[],ARRAY[121.0697328540,14.5461508910]::double precision[],ARRAY[121.0698062010,14.5462224740]::double precision[],ARRAY[121.0698439460,14.5462596240]::double precision[],ARRAY[121.0699049970,14.5463196590]::double precision[],ARRAY[121.0700933200,14.5464845570]::double precision[],ARRAY[121.0703883630,14.5467356750]::double precision[],ARRAY[121.0706051300,14.5468634290]::double precision[],ARRAY[121.0706813710,14.5469087550]::double precision[],ARRAY[121.0708099410,14.5469847480]::double precision[],ARRAY[121.0709308270,14.5470561890]::double precision[],ARRAY[121.0711568210,14.5471891270]::double precision[],ARRAY[121.0714226960,14.5472954770]::double precision[],ARRAY[121.0715146920,14.5473325790]::double precision[],ARRAY[121.0715690440,14.5473525150]::double precision[],ARRAY[121.0716838050,14.5473727670]::double precision[],ARRAY[121.0717816910,14.5474166470]::double precision[],ARRAY[121.0719875870,14.5475111570]::double precision[],ARRAY[121.0721937350,14.5476677020]::double precision[],ARRAY[121.0724330220,14.5477275240]::double precision[],ARRAY[121.0725859010,14.5477740520]::double precision[],ARRAY[121.0727986010,14.5478604620]::double precision[],ARRAY[121.0730113010,14.5479402240]::double precision[],ARRAY[121.0731575850,14.5481369030]::double precision[],ARRAY[121.0732626110,14.5483539560]::double precision[],ARRAY[121.0731886760,14.5485971500]::double precision[],ARRAY[121.0732622410,14.5486115430]::double precision[],ARRAY[121.0734699360,14.5486447940]::double precision[],ARRAY[121.0737690460,14.5486846750]::double precision[],ARRAY[121.0739152770,14.5486115600]::double precision[]
  ];
$fn$;

ALTER FUNCTION private.santa_ana_pateros_boundary_ring() OWNER TO postgres;

COMMENT ON FUNCTION private.santa_ana_pateros_boundary_ring() IS
  'V3-DB4: NAMRIA/PSA COD-AB v03 Santa Ana, Pateros ADM4 ring. '
  'Each inner array is [longitude, latitude] in EPSG:4326. '
  'Source: HDX dataset cod-ab-phl, phl_admin4.shp, adm4_pcode '
  'PH1307606007, PSGC 1381701007. CC BY-IGO. Display centroid is not stored here.';

REVOKE ALL ON FUNCTION private.santa_ana_pateros_boundary_ring()
  FROM PUBLIC, anon, authenticated, service_role;


-- ---------- 2. Point-in-polygon (even-odd; vertices/edges inside) ----------

CREATE FUNCTION private.point_in_service_area_ring(
  p_longitude double precision,
  p_latitude double precision
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $fn$
DECLARE
  v_ring double precision[][];
  v_n    integer;
  v_i    integer;
  v_j    integer;
  v_xi   double precision;
  v_yi   double precision;
  v_xj   double precision;
  v_yj   double precision;
  v_inside boolean := false;
  v_den  double precision;
BEGIN
  IF p_longitude IS NULL OR p_latitude IS NULL
     OR p_longitude <> p_longitude OR p_latitude <> p_latitude THEN
    RETURN false;
  END IF;

  v_ring := private.santa_ana_pateros_boundary_ring();
  v_n := array_length(v_ring, 1);
  IF v_n IS NULL OR v_n < 4 THEN
    RETURN false;
  END IF;

  FOR v_i IN 1..v_n LOOP
    IF v_ring[v_i][1] = p_longitude AND v_ring[v_i][2] = p_latitude THEN
      RETURN true;
    END IF;
  END LOOP;

  v_j := v_n;
  FOR v_i IN 1..v_n LOOP
    v_xi := v_ring[v_i][1];
    v_yi := v_ring[v_i][2];
    v_xj := v_ring[v_j][1];
    v_yj := v_ring[v_j][2];
    IF (v_yi > p_latitude) IS DISTINCT FROM (v_yj > p_latitude) THEN
      v_den := v_yj - v_yi;
      IF v_den <> 0
         AND p_longitude < (((v_xj - v_xi) * (p_latitude - v_yi)) / v_den) + v_xi THEN
        v_inside := NOT v_inside;
      END IF;
    END IF;
    v_j := v_i;
  END LOOP;

  RETURN v_inside;
END;
$fn$;

ALTER FUNCTION private.point_in_service_area_ring(double precision, double precision)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION private.point_in_service_area_ring(double precision, double precision)
  FROM PUBLIC, anon, authenticated, service_role;


-- ---------- 3. Assertion ----------

CREATE FUNCTION private.assert_job_pin_in_service_area(
  p_latitude double precision,
  p_longitude double precision
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $fn$
BEGIN
  PERFORM private.assert_job_coordinates(p_latitude, p_longitude);
  IF NOT private.point_in_service_area_ring(p_longitude, p_latitude) THEN
    RAISE EXCEPTION 'job pin is outside the service area'
      USING ERRCODE = '22023';
  END IF;
END;
$fn$;

ALTER FUNCTION private.assert_job_pin_in_service_area(double precision, double precision)
  OWNER TO postgres;

COMMENT ON FUNCTION private.assert_job_pin_in_service_area(double precision, double precision) IS
  'V3-DB4: reject Job pins that are not inside the official Santa Ana, '
  'Pateros COD-AB polygon. Vertices and edges count as inside.';

REVOKE ALL ON FUNCTION private.assert_job_pin_in_service_area(double precision, double precision)
  FROM PUBLIC, anon, authenticated, service_role;


-- ---------- 4. Replace atomic create (geofence + required description + derived title) ----------

CREATE OR REPLACE FUNCTION public.create_my_job_with_location(
  p_title text,
  p_description text,
  p_address text,
  p_scheduled_at timestamp with time zone,
  p_budget numeric,
  p_payment_method text,
  p_skill_ids uuid[],
  p_latitude double precision,
  p_longitude double precision
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_title        text;
  v_description  text;
  v_address      text;
  v_method       text;
  v_job_id       uuid;
  v_skills       uuid[];
  v_primary      uuid;
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to create a job'
      USING ERRCODE = '42501';
  END IF;

  v_address := btrim(coalesce(p_address, ''));
  IF char_length(v_address) < 1 THEN
    RAISE EXCEPTION 'invalid job address'
      USING ERRCODE = '22023';
  END IF;

  PERFORM private.assert_job_pin_in_service_area(p_latitude, p_longitude);

  v_description := btrim(coalesce(p_description, ''));
  IF char_length(v_description) < 1 THEN
    RAISE EXCEPTION 'invalid job description'
      USING ERRCODE = '22023';
  END IF;

  v_method := btrim(coalesce(p_payment_method, ''));
  IF v_method IS DISTINCT FROM 'cod' AND v_method IS DISTINCT FROM 'qrph' THEN
    RAISE EXCEPTION 'invalid payment method'
      USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(DISTINCT s.skill_id)
    INTO v_skills
  FROM unnest(coalesce(p_skill_ids, ARRAY[]::uuid[])) AS s(skill_id);

  IF v_skills IS NULL OR array_length(v_skills, 1) IS NULL THEN
    RAISE EXCEPTION 'invalid required skills'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_skills) AS s(skill_id)
    LEFT JOIN public.skills AS sk ON sk.id = s.skill_id
    WHERE sk.id IS NULL
  ) THEN
    RAISE EXCEPTION 'invalid required skills'
      USING ERRCODE = '22023';
  END IF;

  -- Primary required skill = first provided skill id (not DISTINCT-reordered).
  SELECT x.skill_id
    INTO v_primary
  FROM unnest(coalesce(p_skill_ids, ARRAY[]::uuid[])) WITH ORDINALITY AS x(skill_id, ord)
  WHERE x.skill_id IS NOT NULL
  ORDER BY x.ord
  LIMIT 1;

  SELECT left(btrim(sk.skill_name::text), 150)
    INTO v_title
  FROM public.skills AS sk
  WHERE sk.id = v_primary;

  IF v_title IS NULL OR char_length(v_title) < 1 THEN
    RAISE EXCEPTION 'invalid job title'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.job_postings (
    client_id,
    title,
    description,
    address,
    barangay,
    city,
    scheduled_at,
    budget,
    payment_method
  ) VALUES (
    v_caller,
    v_title,
    v_description,
    v_address,
    'Santa Ana',
    'Pateros',
    p_scheduled_at,
    p_budget,
    v_method
  )
  RETURNING public.job_postings.id INTO v_job_id;

  INSERT INTO public.job_skills (job_id, skill_id)
  SELECT v_job_id, s.skill_id
  FROM unnest(v_skills) AS s(skill_id);

  INSERT INTO private.job_locations (job_id, latitude, longitude)
  VALUES (v_job_id, p_latitude, p_longitude);

  RETURN v_job_id;
END;
$fn$;

COMMENT ON FUNCTION public.create_my_job_with_location(
  text, text, text, timestamptz, numeric, text, uuid[], double precision, double precision
) IS
  'V3-DB4: atomic active-Client Job + required skills + private pin. '
  'Pin must lie in the official Santa Ana, Pateros COD-AB polygon. '
  'Description is required. Title is derived from the primary required '
  'skill name; p_title is retained only so existing 9-argument callers compile. '
  'GPS is not a matching input.';


-- ---------- 5. Owner update also geofenced ----------

CREATE OR REPLACE FUNCTION public.update_my_open_job_location(
  p_job_id uuid,
  p_address text,
  p_latitude double precision,
  p_longitude double precision
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_caller  uuid := auth.uid();
  v_address text;
  v_status  text;
  v_owner   uuid;
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to update job location'
      USING ERRCODE = '42501';
  END IF;

  IF p_job_id IS NULL THEN
    RAISE EXCEPTION 'this job location is not available'
      USING ERRCODE = 'SM409';
  END IF;

  v_address := btrim(coalesce(p_address, ''));
  IF char_length(v_address) < 1 THEN
    RAISE EXCEPTION 'invalid job address'
      USING ERRCODE = '22023';
  END IF;

  PERFORM private.assert_job_pin_in_service_area(p_latitude, p_longitude);

  SELECT jp.status::text, jp.client_id
    INTO v_status, v_owner
  FROM public.job_postings AS jp
  WHERE jp.id = p_job_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_owner IS DISTINCT FROM v_caller
     OR v_status IS DISTINCT FROM 'open'
  THEN
    RAISE EXCEPTION 'this job location is not available'
      USING ERRCODE = 'SM409';
  END IF;

  UPDATE public.job_postings AS jp
  SET address = v_address
  WHERE jp.id = p_job_id;

  INSERT INTO private.job_locations (job_id, latitude, longitude)
  VALUES (p_job_id, p_latitude, p_longitude)
  ON CONFLICT (job_id) DO UPDATE
    SET latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        updated_at = now();
END;
$fn$;

COMMENT ON FUNCTION public.update_my_open_job_location(
  uuid, text, double precision, double precision
) IS
  'V3-DB4: owning active Client may replace address and pin only while '
  'the Job is open/unaccepted. The new pin must lie in the official '
  'Santa Ana, Pateros COD-AB polygon.';


-- ---------- 6. Close direct INSERT bypass ----------

REVOKE INSERT ON TABLE public.job_postings FROM PUBLIC;
REVOKE INSERT ON TABLE public.job_postings FROM anon;
REVOKE INSERT ON TABLE public.job_postings FROM authenticated;
