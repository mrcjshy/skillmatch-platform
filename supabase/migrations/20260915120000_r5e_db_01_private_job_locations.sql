-- ============================================================
-- R5E-DB-01: PRIVATE JOB COORDINATE CONTRACT
-- ============================================================
--
-- SCOPE
-- -----
-- Implements the locked R5E-D1 Job-pin contract:
--   1. private.job_locations (one-to-one Job pin; not a 14th public table)
--   2. exact coordinate constraints
--   3. grants/revokes so anon/authenticated cannot touch the private table
--   4. atomic public.create_my_job_with_location
--   5. owner public.update_my_open_job_location
--   6. public.get_job_approximate_area (barangay/city/area key only)
--   7. public.get_authorized_job_location (exact pin; confirmed or open-owner)
--   8. revoke authenticated/anon SELECT on job_postings.address
--
-- D-001: public application-table count remains 13.
-- D-002: matching untouched. No GPS scoring. No Worker Zones.
-- D-003: Worker-choice booking untouched.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No latitude/longitude columns on public.job_postings.
--   * No Worker-location table, history, Realtime, or tracking.
--   * No change to private.compute_job_matches, private.location_points,
--     or public.match_workers_for_job.
--   * No DROP/CREATE of public.list_my_job_opportunities().
--   * No mobile/UI, maps, expo-location, or Open in Maps.
--   * Existing N7 direct job_postings INSERT (without coordinates)
--     remains for legacy Client posting until R5E-M1.
-- ============================================================


-- ---------- 1. PRIVATE ONE-TO-ONE JOB PIN ----------

CREATE TABLE private.job_locations (
  job_id     uuid PRIMARY KEY
             REFERENCES public.job_postings(id) ON DELETE CASCADE,
  latitude   double precision NOT NULL,
  longitude  double precision NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT job_locations_latitude_chk
    CHECK (latitude >= -90::double precision
       AND latitude <=  90::double precision
       AND latitude = latitude),
  CONSTRAINT job_locations_longitude_chk
    CHECK (longitude >= -180::double precision
       AND longitude <=  180::double precision
       AND longitude = longitude)
);

ALTER TABLE private.job_locations OWNER TO postgres;

COMMENT ON TABLE private.job_locations IS
  'R5E-DB1: current exact Job pin. Private one-to-one with '
  'public.job_postings. Not a D-001 application table. No history and '
  'no Worker location.';

ALTER TABLE private.job_locations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.job_locations FROM PUBLIC;
REVOKE ALL ON TABLE private.job_locations FROM anon;
REVOKE ALL ON TABLE private.job_locations FROM authenticated;
REVOKE ALL ON TABLE private.job_locations FROM service_role;


-- ---------- 2. COORDINATE ASSERTION ----------

CREATE FUNCTION private.assert_job_coordinates(
  p_latitude double precision,
  p_longitude double precision
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF p_latitude IS NULL
     OR p_longitude IS NULL
     OR p_latitude <> p_latitude
     OR p_longitude <> p_longitude
     OR p_latitude < -90::double precision
     OR p_latitude > 90::double precision
     OR p_longitude < -180::double precision
     OR p_longitude > 180::double precision
  THEN
    RAISE EXCEPTION 'invalid job location'
      USING ERRCODE = '22023';
  END IF;
END;
$$;

ALTER FUNCTION private.assert_job_coordinates(double precision, double precision)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION private.assert_job_coordinates(double precision, double precision)
  FROM PUBLIC, anon, authenticated, service_role;


-- ---------- 3. ATOMIC CREATE ----------

CREATE FUNCTION public.create_my_job_with_location(
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
AS $$
DECLARE
  v_caller  uuid := auth.uid();
  v_title   text;
  v_address text;
  v_method  text;
  v_job_id  uuid;
  v_skills  uuid[];
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to create a job'
      USING ERRCODE = '42501';
  END IF;

  v_title := btrim(coalesce(p_title, ''));
  IF char_length(v_title) < 1 OR char_length(v_title) > 150 THEN
    RAISE EXCEPTION 'invalid job title'
      USING ERRCODE = '22023';
  END IF;

  v_address := btrim(coalesce(p_address, ''));
  IF char_length(v_address) < 1 THEN
    RAISE EXCEPTION 'invalid job address'
      USING ERRCODE = '22023';
  END IF;

  PERFORM private.assert_job_coordinates(p_latitude, p_longitude);

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
    NULLIF(btrim(coalesce(p_description, '')), ''),
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
$$;

ALTER FUNCTION public.create_my_job_with_location(
  text, text, text, timestamptz, numeric, text, uuid[], double precision, double precision
) OWNER TO postgres;

COMMENT ON FUNCTION public.create_my_job_with_location(
  text, text, text, timestamptz, numeric, text, uuid[], double precision, double precision
) IS
  'R5E-DB1: atomic active-Client Job + required skills + private pin. '
  'Caller is auth.uid(). Barangay/city are server-written Santa Ana / '
  'Pateros. Exact coordinates never land on public.job_postings.';

REVOKE ALL ON FUNCTION public.create_my_job_with_location(
  text, text, text, timestamptz, numeric, text, uuid[], double precision, double precision
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_my_job_with_location(
  text, text, text, timestamptz, numeric, text, uuid[], double precision, double precision
) FROM anon;
REVOKE ALL ON FUNCTION public.create_my_job_with_location(
  text, text, text, timestamptz, numeric, text, uuid[], double precision, double precision
) FROM authenticated;
REVOKE ALL ON FUNCTION public.create_my_job_with_location(
  text, text, text, timestamptz, numeric, text, uuid[], double precision, double precision
) FROM service_role;
GRANT EXECUTE ON FUNCTION public.create_my_job_with_location(
  text, text, text, timestamptz, numeric, text, uuid[], double precision, double precision
) TO authenticated;


-- ---------- 4. OWNER UPDATE WHILE OPEN ----------

CREATE FUNCTION public.update_my_open_job_location(
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
AS $$
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

  PERFORM private.assert_job_coordinates(p_latitude, p_longitude);

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
$$;

ALTER FUNCTION public.update_my_open_job_location(
  uuid, text, double precision, double precision
) OWNER TO postgres;

COMMENT ON FUNCTION public.update_my_open_job_location(
  uuid, text, double precision, double precision
) IS
  'R5E-DB1: owning active Client may replace address and pin only while '
  'the Job is open/unaccepted. Identity is auth.uid().';

REVOKE ALL ON FUNCTION public.update_my_open_job_location(
  uuid, text, double precision, double precision
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_my_open_job_location(
  uuid, text, double precision, double precision
) FROM anon;
REVOKE ALL ON FUNCTION public.update_my_open_job_location(
  uuid, text, double precision, double precision
) FROM authenticated;
REVOKE ALL ON FUNCTION public.update_my_open_job_location(
  uuid, text, double precision, double precision
) FROM service_role;
GRANT EXECUTE ON FUNCTION public.update_my_open_job_location(
  uuid, text, double precision, double precision
) TO authenticated;


-- ---------- 5. PRE-ACCEPT APPROXIMATE AREA ----------

CREATE FUNCTION public.get_job_approximate_area(p_job_id uuid)
RETURNS TABLE (
  job_id               uuid,
  barangay             character varying,
  city                 character varying,
  approximate_area_key text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_ok     boolean := false;
BEGIN
  IF v_caller IS NULL
     OR NOT (private.is_active_worker() OR private.is_active_client())
  THEN
    RAISE EXCEPTION 'not authorized to view job area'
      USING ERRCODE = '42501';
  END IF;

  IF p_job_id IS NULL THEN
    RAISE EXCEPTION 'this job area is not available'
      USING ERRCODE = 'SM409';
  END IF;

  IF private.is_active_client() THEN
    SELECT true INTO v_ok
    FROM public.job_postings AS jp
    WHERE jp.id = p_job_id
      AND jp.client_id = v_caller
      AND jp.status = 'open';
  END IF;

  IF NOT COALESCE(v_ok, false) AND private.is_active_worker() THEN
    SELECT true INTO v_ok
    FROM public.job_postings AS jp
    JOIN LATERAL private.compute_job_matches(jp.id) AS m ON m.worker_id = v_caller
    WHERE jp.id = p_job_id
      AND jp.status = 'open';
  END IF;

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'this job area is not available'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT
    jp.id,
    jp.barangay,
    jp.city,
    CASE
      WHEN jp.barangay = 'Santa Ana' AND jp.city = 'Pateros'
        THEN 'santa_ana_pateros'
      ELSE 'general_barangay_city'
    END
  FROM public.job_postings AS jp
  WHERE jp.id = p_job_id;
END;
$$;

ALTER FUNCTION public.get_job_approximate_area(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.get_job_approximate_area(uuid) IS
  'R5E-DB1: pre-accept approximate Job area. Returns barangay, city, and '
  'a deployment area key derived only from those fields. Never returns '
  'address or the private pin. Eligible open-Job Workers or the owning '
  'Client of an open Job. Identity is auth.uid().';

REVOKE ALL ON FUNCTION public.get_job_approximate_area(uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_job_approximate_area(uuid)
  FROM anon;
REVOKE ALL ON FUNCTION public.get_job_approximate_area(uuid)
  FROM authenticated;
REVOKE ALL ON FUNCTION public.get_job_approximate_area(uuid)
  FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_job_approximate_area(uuid)
  TO authenticated;


-- ---------- 6. EXACT LOCATION READ ----------

CREATE FUNCTION public.get_authorized_job_location(p_job_id uuid)
RETURNS TABLE (
  job_id    uuid,
  address   text,
  latitude  double precision,
  longitude double precision,
  barangay  character varying,
  city      character varying
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_ok     boolean := false;
BEGIN
  IF v_caller IS NULL
     OR NOT (private.is_active_worker() OR private.is_active_client())
  THEN
    RAISE EXCEPTION 'not authorized to view job location'
      USING ERRCODE = '42501';
  END IF;

  IF p_job_id IS NULL THEN
    RAISE EXCEPTION 'this job location is not available'
      USING ERRCODE = 'SM409';
  END IF;

  IF private.is_active_client() THEN
    SELECT true INTO v_ok
    FROM public.job_postings AS jp
    WHERE jp.id = p_job_id
      AND jp.client_id = v_caller
      AND jp.status = 'open';
  END IF;

  IF NOT COALESCE(v_ok, false) THEN
    SELECT true INTO v_ok
    FROM public.bookings AS b
    WHERE b.job_id = p_job_id
      AND b.status = 'confirmed'
      AND (
        (b.worker_id = v_caller AND private.is_active_worker())
        OR (b.client_id = v_caller AND private.is_active_client())
      );
  END IF;

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'this job location is not available'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT
    jp.id,
    jp.address,
    jl.latitude,
    jl.longitude,
    jp.barangay,
    jp.city
  FROM public.job_postings AS jp
  LEFT JOIN private.job_locations AS jl
    ON jl.job_id = jp.id
  WHERE jp.id = p_job_id;
END;
$$;

ALTER FUNCTION public.get_authorized_job_location(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.get_authorized_job_location(uuid) IS
  'R5E-DB1: exact Job address and pin. Allowed only for the owning '
  'active Client of an open Job, or a confirmed Booking participant. '
  'Terminal, no_show, nonparticipant, and unknown ids share SM409. '
  'Identity is auth.uid(). Legacy Jobs without a pin return NULL '
  'coordinates.';

REVOKE ALL ON FUNCTION public.get_authorized_job_location(uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_authorized_job_location(uuid)
  FROM anon;
REVOKE ALL ON FUNCTION public.get_authorized_job_location(uuid)
  FROM authenticated;
REVOKE ALL ON FUNCTION public.get_authorized_job_location(uuid)
  FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_authorized_job_location(uuid)
  TO authenticated;


-- ---------- 7. CLOSE AUTHENTICATED-WIDE ADDRESS SELECT ----------
--
-- Row policy "Anyone authenticated can read open jobs" (USING true)
-- remains for non-address columns needed by current Client job lists
-- and payment-method reads. Exact address is withdrawn at the column
-- GRANT layer. SECURITY DEFINER RPCs still project address only when
-- their own status gates allow it (R3B lists; get_authorized_job_location).

REVOKE SELECT ON TABLE public.job_postings FROM PUBLIC;
REVOKE SELECT ON TABLE public.job_postings FROM anon;
REVOKE SELECT ON TABLE public.job_postings FROM authenticated;

GRANT SELECT (
  id,
  client_id,
  title,
  description,
  barangay,
  city,
  scheduled_at,
  status,
  budget,
  created_at,
  payment_method
) ON TABLE public.job_postings TO authenticated;
