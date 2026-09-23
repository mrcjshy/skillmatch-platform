-- AA-03B: fixed Santa Ana geographic aggregates. Apply only inside local
-- rollback verification until a separate hosted gate is authorized.

CREATE TABLE private.admin_geographic_publications (
  publication_date date NOT NULL,
  aggregation_version text NOT NULL,
  grid_version text NOT NULL,
  as_of timestamptz NOT NULL,
  coverage_status text NOT NULL CHECK
    (coverage_status IN ('complete', 'partial', 'no_mappable_data')),
  release_status text NOT NULL CHECK
    (release_status IN ('released', 'insufficient_data', 'no_mappable_data')),
  cells jsonb NOT NULL CHECK (jsonb_typeof(cells) = 'array'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (publication_date, aggregation_version, grid_version)
);
ALTER TABLE private.admin_geographic_publications OWNER TO postgres;
ALTER TABLE private.admin_geographic_publications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.admin_geographic_publications
  FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE private.admin_geographic_publications IS
  'AA-03B sanitized, daily frozen Admin geographic output only. No source rows, pins, IDs, hidden counts, or reasons.';

-- An intersection of the public COD-AB ring and a fixed 0.005-degree cell.
-- The six cells intersecting this version of the ring are checked by tests.
CREATE FUNCTION private.aa03_cell_polygon(p_e integer, p_n integer)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER SET search_path = ''
AS $fn$
DECLARE
  v_ring double precision[][] := private.santa_ana_pateros_boundary_ring();
  v_points jsonb := '[]'::jsonb;
  v_out jsonb;
  v_a jsonb;
  v_b jsonb;
  v_xa double precision;
  v_ya double precision;
  v_xb double precision;
  v_yb double precision;
  v_edge double precision;
  v_axis integer;
  v_pass integer;
  v_ain boolean;
  v_bin boolean;
  v_t double precision;
  v_x double precision;
  v_y double precision;
  v_i integer;
BEGIN
  IF p_e NOT BETWEEN 0 AND 2 OR p_n NOT BETWEEN 0 AND 1 THEN
    RETURN NULL;
  END IF;
  FOR v_i IN 1..array_length(v_ring, 1)-1 LOOP
    v_points := v_points || jsonb_build_array(
      jsonb_build_array(v_ring[v_i][1], v_ring[v_i][2]));
  END LOOP;
  -- Sutherland-Hodgman clipping, in fixed west/east/south/north order.
  FOR v_pass IN 1..4 LOOP
    IF jsonb_array_length(v_points) = 0 THEN RETURN NULL; END IF;
    v_axis := CASE WHEN v_pass <= 2 THEN 0 ELSE 1 END;
    v_edge := CASE v_pass
      WHEN 1 THEN 121.065 + p_e * 0.005
      WHEN 2 THEN 121.065 + (p_e + 1) * 0.005
      WHEN 3 THEN 14.540 + p_n * 0.005
      ELSE 14.540 + (p_n + 1) * 0.005 END;
    v_out := '[]'::jsonb;
    v_a := v_points->(jsonb_array_length(v_points)-1);
    FOR v_b IN SELECT value FROM jsonb_array_elements(v_points) LOOP
      v_xa := (v_a->>0)::double precision;
      v_ya := (v_a->>1)::double precision;
      v_xb := (v_b->>0)::double precision;
      v_yb := (v_b->>1)::double precision;
      v_ain := CASE v_pass WHEN 1 THEN v_xa >= v_edge
        WHEN 2 THEN v_xa <= v_edge WHEN 3 THEN v_ya >= v_edge
        ELSE v_ya <= v_edge END;
      v_bin := CASE v_pass WHEN 1 THEN v_xb >= v_edge
        WHEN 2 THEN v_xb <= v_edge WHEN 3 THEN v_yb >= v_edge
        ELSE v_yb <= v_edge END;
      IF v_ain IS DISTINCT FROM v_bin THEN
        v_t := (v_edge - CASE WHEN v_axis = 0 THEN v_xa ELSE v_ya END)
          / (CASE WHEN v_axis = 0 THEN v_xb-v_xa ELSE v_yb-v_ya END);
        v_x := CASE WHEN v_axis = 0 THEN v_edge ELSE v_xa+v_t*(v_xb-v_xa) END;
        v_y := CASE WHEN v_axis = 1 THEN v_edge ELSE v_ya+v_t*(v_yb-v_ya) END;
        v_out := v_out || jsonb_build_array(jsonb_build_array(
          round(v_x::numeric, 10), round(v_y::numeric, 10)));
      END IF;
      IF v_bin THEN v_out := v_out || jsonb_build_array(v_b); END IF;
      v_a := v_b;
    END LOOP;
    v_points := v_out;
  END LOOP;
  IF jsonb_array_length(v_points) < 3 THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('type', 'Polygon', 'coordinates',
    jsonb_build_array(v_points || jsonb_build_array(v_points->0)));
END;
$fn$;
ALTER FUNCTION private.aa03_cell_polygon(integer, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.aa03_cell_polygon(integer, integer)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION private.aa03_band(p_n bigint)
RETURNS text LANGUAGE sql IMMUTABLE SECURITY INVOKER SET search_path = ''
AS $fn$
  SELECT CASE WHEN p_n BETWEEN 3 AND 5 THEN '3-5'
    WHEN p_n BETWEEN 6 AND 10 THEN '6-10'
    WHEN p_n BETWEEN 11 AND 20 THEN '11-20'
    WHEN p_n >= 21 THEN '21+' ELSE NULL END;
$fn$;
ALTER FUNCTION private.aa03_band(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.aa03_band(bigint)
  FROM PUBLIC, anon, authenticated, service_role;

-- Sparse forward/backward joint feasibility over (Jobs, Bookings, accepted
-- Jobs). Every numeric limit fails closed; no independent layer audit.
CREATE FUNCTION private.aa03_joint_safe(
  p_cells jsonb, p_td integer, p_tb integer, p_tj integer
)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER SET search_path = ''
AS $fn$
DECLARE
  v_n integer := jsonb_array_length(p_cells);
  v_cands jsonb[] := ARRAY[]::jsonb[];
  v_c jsonb;
  v_band_d text;
  v_band_b text;
  v_dlo integer;
  v_dhi integer;
  v_blo integer;
  v_bhi integer;
  v_d integer;
  v_b integer;
  v_j integer;
  v_i integer;
  v_state numeric[];
  v_pre numeric[];
  v_suffix jsonb;
  v_smap jsonb;
  v_fwd jsonb := jsonb_build_array(jsonb_build_array(0));
  v_bwd jsonb := '{}'::jsonb;
  v_work bigint := 0;
  v_count bigint := 0;
  v_k numeric;
  v_sd numeric;
  v_sb numeric;
  v_sj numeric;
  v_needed numeric;
  v_target numeric;
  v_dvals jsonb;
  v_bvals jsonb;
  v_rec record;
BEGIN
  IF p_cells IS NULL OR jsonb_typeof(p_cells) <> 'array'
     OR v_n < 1 OR v_n > 64
     OR p_td < 0 OR p_tb < 0 OR p_tj < 0 THEN RETURN false; END IF;
  FOR v_i IN 0..v_n-1 LOOP
    v_band_d := p_cells->v_i->>'demand_band';
    v_band_b := p_cells->v_i->>'acceptance_band';
    v_dlo := CASE v_band_d WHEN '3-5' THEN 3 WHEN '6-10' THEN 6
      WHEN '11-20' THEN 11 WHEN '21+' THEN 21 ELSE NULL END;
    v_dhi := least(p_td, CASE v_band_d WHEN '3-5' THEN 5
      WHEN '6-10' THEN 10 WHEN '11-20' THEN 20
      WHEN '21+' THEN p_td ELSE -1 END);
    v_blo := CASE v_band_b WHEN '3-5' THEN 3 WHEN '6-10' THEN 6
      WHEN '11-20' THEN 11 WHEN '21+' THEN 21 ELSE NULL END;
    v_bhi := least(p_tb, CASE v_band_b WHEN '3-5' THEN 5
      WHEN '6-10' THEN 10 WHEN '11-20' THEN 20
      WHEN '21+' THEN p_tb ELSE -1 END);
    IF v_dlo IS NULL OR v_blo IS NULL OR v_dlo > v_dhi
       OR v_blo > v_bhi THEN RETURN false; END IF;
    v_c := '[]'::jsonb;
    FOR v_d IN v_dlo..v_dhi LOOP
      FOR v_b IN v_blo..v_bhi LOOP
        FOR v_j IN 3..least(v_d, v_b, p_tj) LOOP
          IF v_d-v_j = 0 OR v_d-v_j >= 3 THEN
            v_c := v_c || jsonb_build_array(
              jsonb_build_object('d',v_d,'b',v_b,'j',v_j));
            IF jsonb_array_length(v_c) > 10000 THEN RETURN false; END IF;
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    IF jsonb_array_length(v_c) = 0 THEN RETURN false; END IF;
    v_cands := array_append(v_cands, v_c);
  END LOOP;

  -- Encoding is exact numeric: ((d*(T_B+1)+b)*(T_J+1)+j).
  v_state := ARRAY[0::numeric];
  FOR v_i IN 1..v_n LOOP
    v_work := v_work + cardinality(v_state)
      * jsonb_array_length(v_cands[v_i]);
    IF v_work > 2000000 THEN RETURN false; END IF;
    SELECT array_agg(DISTINCT
      (((floor(s.k / ((p_tb::numeric+1)*(p_tj::numeric+1)))+c.d)
        *(p_tb::numeric+1)
        +floor(mod(s.k,(p_tb::numeric+1)*(p_tj::numeric+1))
          /(p_tj::numeric+1))+c.b)
        *(p_tj::numeric+1)+mod(s.k,p_tj::numeric+1)+c.j))
    INTO v_state
    FROM unnest(v_state) AS s(k)
    CROSS JOIN jsonb_to_recordset(v_cands[v_i])
      AS c(d integer,b integer,j integer)
    WHERE floor(s.k / ((p_tb::numeric+1)*(p_tj::numeric+1)))+c.d <= p_td
      AND floor(mod(s.k,(p_tb::numeric+1)*(p_tj::numeric+1))
        /(p_tj::numeric+1))+c.b <= p_tb
      AND mod(s.k,p_tj::numeric+1)+c.j <= p_tj;
    IF v_state IS NULL OR cardinality(v_state) > 200000 THEN RETURN false; END IF;
    v_count := v_count + cardinality(v_state);
    IF v_count > 200000 THEN RETURN false; END IF;
    v_fwd := v_fwd || jsonb_build_array(to_jsonb(v_state));
  END LOOP;
  v_target := ((p_td::numeric*(p_tb::numeric+1)+p_tb)
    *(p_tj::numeric+1)+p_tj);
  IF NOT v_state @> ARRAY[v_target] THEN RETURN false; END IF;

  v_state := ARRAY[0::numeric];
  v_bwd := jsonb_build_object(v_n::text, to_jsonb(v_state));
  FOR v_i IN REVERSE v_n..1 LOOP
    v_work := v_work + cardinality(v_state)
      * jsonb_array_length(v_cands[v_i]);
    IF v_work > 2000000 THEN RETURN false; END IF;
    SELECT array_agg(DISTINCT
      (((floor(s.k / ((p_tb::numeric+1)*(p_tj::numeric+1)))+c.d)
        *(p_tb::numeric+1)
        +floor(mod(s.k,(p_tb::numeric+1)*(p_tj::numeric+1))
          /(p_tj::numeric+1))+c.b)
        *(p_tj::numeric+1)+mod(s.k,p_tj::numeric+1)+c.j))
    INTO v_state
    FROM unnest(v_state) AS s(k)
    CROSS JOIN jsonb_to_recordset(v_cands[v_i])
      AS c(d integer,b integer,j integer)
    WHERE floor(s.k / ((p_tb::numeric+1)*(p_tj::numeric+1)))+c.d <= p_td
      AND floor(mod(s.k,(p_tb::numeric+1)*(p_tj::numeric+1))
        /(p_tj::numeric+1))+c.b <= p_tb
      AND mod(s.k,p_tj::numeric+1)+c.j <= p_tj;
    IF v_state IS NULL OR cardinality(v_state) > 200000 THEN RETURN false; END IF;
    v_count := v_count + cardinality(v_state);
    IF v_count > 200000 THEN RETURN false; END IF;
    v_bwd := v_bwd || jsonb_build_object((v_i-1)::text,to_jsonb(v_state));
  END LOOP;

  FOR v_i IN 0..v_n-1 LOOP
    SELECT array_agg(value::numeric) INTO v_pre
      FROM jsonb_array_elements_text(v_fwd->v_i);
    v_suffix := v_bwd->(v_i+1)::text;
    SELECT coalesce(jsonb_object_agg(value,'true'::jsonb),'{}'::jsonb)
      INTO v_smap FROM jsonb_array_elements_text(v_suffix);
    v_dvals := '{}'::jsonb;
    v_bvals := '{}'::jsonb;
    v_work := v_work + cardinality(v_pre)
      * jsonb_array_length(v_cands[v_i+1]);
    IF v_work > 2000000 THEN RETURN false; END IF;
    FOR v_rec IN SELECT * FROM jsonb_to_recordset(v_cands[v_i+1])
      AS c(d integer,b integer,j integer) LOOP
      FOREACH v_k IN ARRAY v_pre LOOP
        v_sd := floor(v_k / ((p_tb::numeric+1)*(p_tj::numeric+1)));
        v_sb := floor(mod(v_k,(p_tb::numeric+1)*(p_tj::numeric+1))
          /(p_tj::numeric+1));
        v_sj := mod(v_k,p_tj::numeric+1);
        IF p_td-v_sd-v_rec.d < 0 OR p_tb-v_sb-v_rec.b < 0
          OR p_tj-v_sj-v_rec.j < 0 THEN CONTINUE; END IF;
        v_needed := (((p_td-v_sd-v_rec.d)*(p_tb::numeric+1)
          +(p_tb-v_sb-v_rec.b))*(p_tj::numeric+1)
          +(p_tj-v_sj-v_rec.j));
        IF v_smap ? v_needed::text THEN
          v_dvals := v_dvals || jsonb_build_object(v_rec.d::text,true);
          v_bvals := v_bvals || jsonb_build_object(v_rec.b::text,true);
        END IF;
      END LOOP;
    END LOOP;
    IF (SELECT count(*) FROM jsonb_object_keys(v_dvals)) < 2
      OR (SELECT count(*) FROM jsonb_object_keys(v_bvals)) < 2
      THEN RETURN false; END IF;
  END LOOP;
  RETURN true;
END;
$fn$;
ALTER FUNCTION private.aa03_joint_safe(jsonb, integer, integer, integer)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION private.aa03_joint_safe(jsonb, integer, integer, integer)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_admin_geographic_analytics()
RETURNS TABLE (
  as_of timestamptz,
  aggregation_version text,
  grid_version text,
  coverage_status text,
  release_status text,
  cells jsonb
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_day date;
  v_agg constant text := 'aa03-geo-v1';
  v_grid constant text := 'sa-pateros-626f7138-g005-v1';
  v_cached private.admin_geographic_publications%ROWTYPE;
  v_as_of timestamptz;
  v_total_jobs bigint;
  v_mapped_jobs bigint;
  v_global_acceptance bigint;
  v_internal jsonb;
  v_bands jsonb := '[]'::jsonb;
  v_released jsonb := '[]'::jsonb;
  v_cell jsonb;
  v_geometry jsonb;
  v_td bigint := 0;
  v_tb bigint := 0;
  v_tj bigint := 0;
  v_coverage text;
  v_release text;
  v_e integer;
  v_n integer;
  v_dband text;
  v_bband text;
  v_unsafe boolean := false;
BEGIN
  -- This check must precede even a cache read or advisory lock.
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to read admin geographic analytics'
      USING ERRCODE = '42501';
  END IF;
  v_day := (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('aa03|' || v_day::text || '|' || v_agg || '|' || v_grid, 0));
  IF v_day <> (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date THEN
    RAISE EXCEPTION 'AA-03 publication day changed during lock wait'
      USING ERRCODE = '40001';
  END IF;
  SELECT * INTO v_cached FROM private.admin_geographic_publications AS p
    WHERE p.publication_date = v_day
      AND p.aggregation_version = v_agg AND p.grid_version = v_grid;
  IF FOUND THEN
    IF v_day <> (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date THEN
      RAISE EXCEPTION 'AA-03 publication day changed during cache read'
        USING ERRCODE = '40001';
    END IF;
    RETURN QUERY SELECT v_cached.as_of, v_cached.aggregation_version,
      v_cached.grid_version, v_cached.coverage_status,
      v_cached.release_status, v_cached.cells;
    RETURN;
  END IF;

  -- All source reads below share this single SELECT statement's MVCC snapshot.
  -- The private pin never enters the returned/cached JSON.
  WITH base AS MATERIALIZED (
    SELECT j.id, j.client_id,
      CASE WHEN jl.job_id IS NOT NULL
        AND private.point_in_service_area_ring(jl.longitude, jl.latitude)
        THEN floor((jl.longitude::numeric-121.065)/0.005)::integer
        ELSE NULL END AS e,
      CASE WHEN jl.job_id IS NOT NULL
        AND private.point_in_service_area_ring(jl.longitude, jl.latitude)
        THEN floor((jl.latitude::numeric-14.540)/0.005)::integer
        ELSE NULL END AS n
    FROM public.job_postings AS j
    LEFT JOIN private.job_locations AS jl ON jl.job_id = j.id
  ), accepted AS MATERIALIZED (
    SELECT b.id, b.job_id, b.worker_id, x.client_id, x.e, x.n
    FROM public.bookings AS b
    JOIN base AS x ON x.id = b.job_id
    WHERE b.status IN ('confirmed','completed','cancelled')
      AND x.e IS NOT NULL AND x.n IS NOT NULL
  ), accepted_jobs AS (
    SELECT DISTINCT job_id FROM accepted
  ), demand AS (
    SELECT x.e, x.n, count(*)::integer AS d,
      count(DISTINCT x.client_id)::integer AS dc,
      count(*) FILTER (WHERE aj.job_id IS NOT NULL)::integer AS j,
      count(DISTINCT x.client_id) FILTER
        (WHERE aj.job_id IS NULL)::integer AS rc
    FROM base AS x
    LEFT JOIN accepted_jobs AS aj ON aj.job_id = x.id
    WHERE x.e IS NOT NULL AND x.n IS NOT NULL
    GROUP BY x.e, x.n
  ), work AS (
    SELECT e,n,count(*)::integer AS b,
      count(DISTINCT client_id)::integer AS ac,
      count(DISTINCT worker_id)::integer AS aw
    FROM accepted GROUP BY e,n
  ), per_cell AS (
    SELECT d.e,d.n,d.d,d.dc,d.j,d.rc,
      coalesce(w.b,0) AS b,coalesce(w.ac,0) AS ac,
      coalesce(w.aw,0) AS aw
    FROM demand AS d LEFT JOIN work AS w USING (e,n)
  )
  SELECT clock_timestamp(),
    (SELECT count(*) FROM base),
    (SELECT count(*) FROM base WHERE e IS NOT NULL AND n IS NOT NULL),
    (SELECT count(*) FROM public.bookings
      WHERE status IN ('confirmed','completed','cancelled')),
    coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.e,c.n)
      FROM per_cell AS c),'[]'::jsonb)
  INTO v_as_of,v_total_jobs,v_mapped_jobs,v_global_acceptance,v_internal;

  v_coverage := CASE WHEN v_mapped_jobs = 0 THEN 'no_mappable_data'
    WHEN v_mapped_jobs = v_total_jobs THEN 'complete' ELSE 'partial' END;
  v_release := CASE WHEN v_mapped_jobs = 0 THEN 'no_mappable_data'
    ELSE 'insufficient_data' END;
  IF jsonb_array_length(v_internal) > 64 THEN v_unsafe := true; END IF;
  FOR v_cell IN SELECT value FROM jsonb_array_elements(v_internal) LOOP
    v_e := (v_cell->>'e')::integer;
    v_n := (v_cell->>'n')::integer;
    v_td := v_td + (v_cell->>'d')::bigint;
    v_tb := v_tb + (v_cell->>'b')::bigint;
    v_tj := v_tj + (v_cell->>'j')::bigint;
    v_dband := private.aa03_band((v_cell->>'d')::bigint);
    v_bband := private.aa03_band((v_cell->>'b')::bigint);
    IF v_e NOT BETWEEN 0 AND 2 OR v_n NOT BETWEEN 0 AND 1
      OR (v_cell->>'dc')::integer < 3
      OR (v_cell->>'ac')::integer < 3
      OR (v_cell->>'aw')::integer < 3
      OR ((v_cell->>'rc')::integer BETWEEN 1 AND 2)
      OR v_dband IS NULL OR v_bband IS NULL THEN v_unsafe := true; END IF;
    v_bands := v_bands || jsonb_build_array(jsonb_build_object(
      'demand_band',v_dband,'acceptance_band',v_bband));
  END LOOP;
  -- Applicable AA-01 totals are exact all-retained upper bounds. The audit
  -- conservatively treats the more restrictive mapped totals as public too.
  IF v_td <> v_mapped_jobs OR v_tb > v_global_acceptance
    OR v_td > 2147483647 OR v_tb > 2147483647 OR v_tj > 2147483647
    THEN v_unsafe := true; END IF;
  IF v_mapped_jobs > 0 AND NOT v_unsafe
    AND private.aa03_joint_safe(v_bands,v_td::integer,v_tb::integer,v_tj::integer)
  THEN
    FOR v_cell IN SELECT value FROM jsonb_array_elements(v_internal) LOOP
      v_e := (v_cell->>'e')::integer;
      v_n := (v_cell->>'n')::integer;
      v_geometry := private.aa03_cell_polygon(v_e,v_n);
      IF v_geometry IS NULL THEN
        RAISE EXCEPTION 'AA-03 fixed grid geometry unavailable'
          USING ERRCODE = 'XX000';
      END IF;
      v_released := v_released || jsonb_build_array(jsonb_build_object(
        'cell_id', 'sa-g005-e' || lpad(v_e::text,3,'0')
          || '-n' || lpad(v_n::text,3,'0'),
        'geometry',v_geometry,
        'demand_band',private.aa03_band((v_cell->>'d')::bigint),
        'acceptance_band',private.aa03_band((v_cell->>'b')::bigint)));
    END LOOP;
    v_release := 'released';
  END IF;
  IF v_day <> (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date THEN
    RAISE EXCEPTION 'AA-03 publication day changed during computation'
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO private.admin_geographic_publications
    (publication_date,aggregation_version,grid_version,as_of,
     coverage_status,release_status,cells)
  VALUES (v_day,v_agg,v_grid,v_as_of,v_coverage,v_release,v_released);
  DELETE FROM private.admin_geographic_publications
    WHERE publication_date < v_day-30;
  SELECT * INTO STRICT v_cached FROM private.admin_geographic_publications AS p
    WHERE p.publication_date = v_day
      AND p.aggregation_version = v_agg AND p.grid_version = v_grid;
  IF v_day <> (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date THEN
    RAISE EXCEPTION 'AA-03 publication day changed during cache read'
      USING ERRCODE = '40001';
  END IF;
  RETURN QUERY SELECT v_cached.as_of, v_cached.aggregation_version,
    v_cached.grid_version, v_cached.coverage_status,
    v_cached.release_status, v_cached.cells;
END;
$fn$;
ALTER FUNCTION public.get_admin_geographic_analytics() OWNER TO postgres;
COMMENT ON FUNCTION public.get_admin_geographic_analytics() IS
  'AA-03B: POST-only, active-Admin, daily frozen aggregate bands over the fixed Santa Ana grid; writes only a sanitized private publication cache.';
REVOKE ALL ON FUNCTION public.get_admin_geographic_analytics()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_admin_geographic_analytics()
  TO authenticated;
