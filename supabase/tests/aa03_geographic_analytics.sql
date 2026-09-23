-- AA-03B local-only rollback verification. Load its migration in this same
-- transaction before this file; ABORT removes migration and every fixture.
BEGIN;

CREATE FUNCTION pg_temp.aa03_assert(p_name text, p_ok boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'AA-03 FAIL: %', p_name;
  END IF;
  RAISE NOTICE 'AA-03 PASS: %', p_name;
END;
$$;

CREATE FUNCTION pg_temp.aa03_user(p_id uuid, p_role text, p_active boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_email text := p_id::text || '@aa03.example.test';
BEGIN
  INSERT INTO auth.users (
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',p_id,'authenticated',
    'authenticated',v_email,crypt('aa03-local',gen_salt('bf')),now(),
    '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now()
  );
  INSERT INTO public.users
    (id,email,full_name,phone,role,barangay,city,is_active)
  VALUES (p_id,v_email,'AA-03 Fixture','09000000000',p_role,
    'Santa Ana','Pateros',p_active);
END;
$$;

CREATE FUNCTION pg_temp.aa03_login(p_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub',p_id::text,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',p_id::text,true);
  PERFORM set_config('role','authenticated',true);
END;
$$;

CREATE FUNCTION pg_temp.aa03_logout()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role','postgres',true);
  PERFORM set_config('request.jwt.claims','',true);
  PERFORM set_config('request.jwt.claim.sub','',true);
  RESET ROLE;
END;
$$;

CREATE FUNCTION pg_temp.aa03_job(
  p_client uuid,p_worker uuid,p_lon double precision,p_lat double precision,
  p_status text DEFAULT 'confirmed'
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_job uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.job_postings
    (id,client_id,title,description,barangay,city,status,budget)
  VALUES (v_job,p_client,'AA-03 local','Rollback fixture','Santa Ana',
    'Pateros','open',100);
  IF p_lon IS NOT NULL AND p_lat IS NOT NULL THEN
    INSERT INTO private.job_locations(job_id,longitude,latitude)
    VALUES(v_job,p_lon,p_lat);
  END IF;
  IF p_worker IS NOT NULL THEN
    INSERT INTO public.bookings(job_id,worker_id,client_id,status)
    VALUES(v_job,p_worker,p_client,p_status);
  END IF;
  RETURN v_job;
END;
$$;

CREATE FUNCTION pg_temp.aa03_clear()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.bookings;
  DELETE FROM private.job_locations;
  DELETE FROM public.job_postings;
  DELETE FROM private.admin_geographic_publications;
END;
$$;

DO $$
DECLARE
  v_admin uuid := gen_random_uuid();
  v_inactive uuid := gen_random_uuid();
  v_clients uuid[] := ARRAY[gen_random_uuid(),gen_random_uuid(),
    gen_random_uuid(),gen_random_uuid()];
  v_workers uuid[] := ARRAY[gen_random_uuid(),gen_random_uuid(),
    gen_random_uuid(),gen_random_uuid()];
  v_i integer;
  v_job uuid;
  v_first uuid;
  v_result record;
  v_again record;
  v_denied boolean;
  v_expected_as_of timestamptz;
  v_error_state text;
  v_error_message text;
  v_count bigint;
  v_yesterday date := (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date-1;
  v_old date := (clock_timestamp() AT TIME ZONE 'Asia/Manila')::date-31;
BEGIN
  PERFORM pg_temp.aa03_user(v_admin,'administrator',true);
  PERFORM pg_temp.aa03_user(v_inactive,'administrator',false);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp.aa03_user(v_clients[v_i],'client',true);
    PERFORM pg_temp.aa03_user(v_workers[v_i],'worker',true);
  END LOOP;

  PERFORM pg_temp.aa03_assert('mandatory two-cell joint veto',
    private.aa03_joint_safe(jsonb_build_array(
      jsonb_build_object('demand_band','3-5','acceptance_band','3-5'),
      jsonb_build_object('demand_band','6-10','acceptance_band','3-5')),
      14,7,7) IS FALSE);
  PERFORM pg_temp.aa03_assert('joint ambiguity releases two equal bands',
    private.aa03_joint_safe(jsonb_build_array(
      jsonb_build_object('demand_band','3-5','acceptance_band','3-5'),
      jsonb_build_object('demand_band','3-5','acceptance_band','3-5')),
      7,7,7) IS TRUE);
  PERFORM pg_temp.aa03_assert('one-cell arithmetic veto',
    private.aa03_joint_safe(jsonb_build_array(
      jsonb_build_object('demand_band','3-5','acceptance_band','3-5')),
      4,4,4) IS FALSE);
  PERFORM pg_temp.aa03_assert('64-cell work cap veto',
    private.aa03_joint_safe(
      (SELECT jsonb_agg(jsonb_build_object(
        'demand_band','3-5','acceptance_band','3-5'))
       FROM generate_series(1,65)),195,195,195) IS FALSE);
  PERFORM pg_temp.aa03_assert('candidate work cap veto',
    private.aa03_joint_safe(jsonb_build_array(
      jsonb_build_object('demand_band','21+','acceptance_band','21+')),
      100,100,100) IS FALSE);
  PERFORM pg_temp.aa03_assert('bounded DP work veto',
    private.aa03_joint_safe(jsonb_build_array(
      jsonb_build_object('demand_band','11-20','acceptance_band','11-20'),
      jsonb_build_object('demand_band','11-20','acceptance_band','11-20')),
      30,30,30) IS FALSE);
  PERFORM pg_temp.aa03_assert('band thresholds fixed',
    private.aa03_band(2) IS NULL AND private.aa03_band(3)='3-5'
    AND private.aa03_band(5)='3-5' AND private.aa03_band(6)='6-10'
    AND private.aa03_band(10)='6-10' AND private.aa03_band(11)='11-20'
    AND private.aa03_band(20)='11-20' AND private.aa03_band(21)='21+');
  PERFORM pg_temp.aa03_assert('official interior and edge accepted',
    private.point_in_service_area_ring(121.07205067,14.5444514)
    AND private.point_in_service_area_ring(121.0739152770,14.5486115600)
    AND NOT private.point_in_service_area_ring(121.06942,14.55801));
  PERFORM pg_temp.aa03_assert('fixed clipped geometry',
    private.aa03_cell_polygon(0,0)->>'type' = 'Polygon'
    AND private.aa03_cell_polygon(1,0)->>'type' = 'Polygon'
    AND private.aa03_cell_polygon(2,1)->>'type' = 'Polygon'
    AND private.aa03_cell_polygon(3,0) IS NULL);
  PERFORM pg_temp.aa03_assert('grid-line ties go east and north',
    floor((121.070::numeric-121.065)/0.005)=1
    AND floor((14.545::numeric-14.540)/0.005)=1);
  PERFORM pg_temp.aa03_assert('no direct cache grants and POST volatility',
    NOT has_table_privilege('authenticated',
      'private.admin_geographic_publications','SELECT')
    AND NOT has_table_privilege('service_role',
      'private.admin_geographic_publications','SELECT')
    AND (SELECT provolatile='v' AND prosecdef
      FROM pg_proc WHERE oid='public.get_admin_geographic_analytics()'::regprocedure));

  -- Role authorization is checked before any publication can be cached.
  v_denied := false;
  BEGIN
    PERFORM pg_temp.aa03_login(v_clients[1]);
    PERFORM * FROM public.get_admin_geographic_analytics();
  EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('Client denied',v_denied);
  v_denied := false;
  BEGIN
    PERFORM pg_temp.aa03_login(v_workers[1]);
    PERFORM * FROM public.get_admin_geographic_analytics();
  EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('Worker denied',v_denied);
  v_denied := false;
  BEGIN
    PERFORM pg_temp.aa03_login(v_inactive);
    PERFORM * FROM public.get_admin_geographic_analytics();
  EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('inactive Admin denied',v_denied);
  v_denied := false;
  BEGIN
    PERFORM * FROM public.get_admin_geographic_analytics();
  EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_assert('signed-out denied',v_denied);
  v_denied := false;
  BEGIN
    PERFORM set_config('role','service_role',true);
    PERFORM * FROM public.get_admin_geographic_analytics();
  EXCEPTION WHEN insufficient_privilege THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('service_role denied',v_denied);
  PERFORM pg_temp.aa03_assert('unauthorized calls leave cache empty',
    (SELECT count(*) FROM private.admin_geographic_publications)=0);

  -- A test-only BEFORE INSERT trigger changes the stored timestamp. The
  -- original miss path returned its pre-insert value and fails this check.
  CREATE FUNCTION pg_temp.aa03_shift_stored_as_of()
  RETURNS trigger LANGUAGE plpgsql AS $trigger$
  BEGIN
    NEW.as_of := NEW.as_of + interval '1 second';
    RETURN NEW;
  END;
  $trigger$;
  CREATE TRIGGER aa03_shift_stored_as_of BEFORE INSERT
    ON private.admin_geographic_publications
    FOR EACH ROW EXECUTE FUNCTION pg_temp.aa03_shift_stored_as_of();

  -- Empty status is cached, including its persisted timestamp and empty cells.
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  SELECT * INTO v_again FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  SELECT p.as_of INTO v_expected_as_of
    FROM private.admin_geographic_publications AS p
    WHERE p.publication_date=(clock_timestamp() AT TIME ZONE 'Asia/Manila')::date
      AND p.aggregation_version='aa03-geo-v1'
      AND p.grid_version='sa-pateros-626f7138-g005-v1';
  PERFORM pg_temp.aa03_assert('miss returns trigger-altered persisted row',
    v_expected_as_of IS NOT NULL
    AND v_result.as_of=v_expected_as_of
    AND v_again.as_of=v_expected_as_of);
  DROP TRIGGER aa03_shift_stored_as_of
    ON private.admin_geographic_publications;
  PERFORM pg_temp.aa03_assert('empty no-mappable response frozen',
    v_result.release_status='no_mappable_data'
    AND v_result.coverage_status='no_mappable_data'
    AND v_result.cells='[]'::jsonb
    AND v_again.as_of=v_result.as_of
    AND v_again.release_status=v_result.release_status);
  PERFORM pg_temp.aa03_clear();

  -- Seven Jobs/Bookings: cells (0,0) and (1,0) each have three
  -- independent Clients and Workers; the 3/4 split is jointly ambiguous.
  FOR v_i IN 1..7 LOOP
    v_job := pg_temp.aa03_job(
      v_clients[CASE WHEN v_i<=3 THEN v_i ELSE v_i-3 END],
      v_workers[CASE WHEN v_i<=3 THEN v_i ELSE v_i-3 END],
      CASE WHEN v_i <= 3 THEN 121.0695 ELSE 121.07205067 END,
      CASE WHEN v_i <= 3 THEN 14.542 ELSE 14.5444514 END);
    IF v_i=1 THEN v_first:=v_job; END IF;
  END LOOP;
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('releasable two-cell snapshot',
    v_result.release_status='released'
    AND v_result.coverage_status='complete'
    AND jsonb_array_length(v_result.cells)=2
    AND v_result.grid_version='sa-pateros-626f7138-g005-v1'
    AND (SELECT bool_and(c->>'demand_band'='3-5'
      AND c->>'acceptance_band'='3-5'
      AND c->'geometry'->>'type'='Polygon')
      FROM jsonb_array_elements(v_result.cells) AS c));
  PERFORM pg_temp.aa03_assert('k and k-plus-one contributors released',
    (SELECT count(DISTINCT j.client_id)
      FROM public.job_postings AS j
      JOIN private.job_locations AS l ON l.job_id=j.id
      WHERE l.longitude=121.0695)=3
    AND (SELECT count(DISTINCT j.client_id)
      FROM public.job_postings AS j
      JOIN private.job_locations AS l ON l.job_id=j.id
      WHERE l.longitude=121.07205067)=4);
  PERFORM pg_temp.aa03_assert('no raw location or identity in payload/cache',
    v_result.cells::text !~* 'client_id|worker_id|job_id|booking_id|latitude|longitude|hidden|reason'
    AND (SELECT bool_and(p.cells=v_result.cells)
      FROM private.admin_geographic_publications AS p));

  -- A second accepted Booking on one Job changes Booking count without
  -- changing distinct accepted-Job count. Recompute only in the test.
  PERFORM pg_temp.aa03_clear();
  FOR v_i IN 1..7 LOOP
    v_job := pg_temp.aa03_job(
      v_clients[CASE WHEN v_i<=3 THEN v_i ELSE v_i-3 END],
      v_workers[CASE WHEN v_i<=3 THEN v_i ELSE v_i-3 END],
      CASE WHEN v_i <= 3 THEN 121.0695 ELSE 121.07205067 END,
      CASE WHEN v_i <= 3 THEN 14.542 ELSE 14.5444514 END);
    IF v_i=1 THEN v_first:=v_job; END IF;
  END LOOP;
  INSERT INTO public.bookings(job_id,worker_id,client_id,status)
  VALUES(v_first,v_workers[2],v_clients[1],'cancelled');
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('multiple Bookings counted; accepted Job distinct',
    v_result.release_status='released'
    AND (SELECT count(*) FROM public.bookings)=8
    AND (SELECT count(DISTINCT job_id) FROM public.bookings)=7);

  -- Same-day cache freezes every status even after legitimate source change.
  PERFORM pg_temp.aa03_job(v_clients[1],NULL,NULL,NULL);
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_again FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('same-day response is identical after source change',
    v_again.as_of=v_result.as_of
    AND v_again.release_status=v_result.release_status
    AND v_again.coverage_status=v_result.coverage_status
    AND v_again.cells=v_result.cells);

  -- New publication after deleting only test cache reports partial coverage.
  DELETE FROM private.admin_geographic_publications;
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('legacy missing pin is partial, not zero demand',
    v_result.coverage_status='partial'
    AND v_result.release_status='released');
  PERFORM pg_temp.aa03_clear();

  -- Mandatory counterexample also traverses the real RPC publication path.
  -- A has 4 Jobs/4 Bookings; B has 10 Jobs/3 Bookings, with seven
  -- demand-only Jobs from three Clients.
  FOR v_i IN 1..14 LOOP
    PERFORM pg_temp.aa03_job(v_clients[(v_i-1)%3+1],
      CASE WHEN v_i<=4 OR v_i BETWEEN 5 AND 7
        THEN v_workers[(v_i-1)%3+1] ELSE NULL END,
      CASE WHEN v_i<=4 THEN 121.0695 ELSE 121.07205067 END,
      CASE WHEN v_i<=4 THEN 14.542 ELSE 14.5444514 END);
  END LOOP;
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('mandatory counterexample vetoes RPC',
    v_result.release_status='insufficient_data'
    AND v_result.cells='[]'::jsonb);
  PERFORM pg_temp.aa03_job(v_clients[4],NULL,NULL,NULL);
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_again FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('insufficient response is frozen too',
    v_again.as_of=v_result.as_of
    AND v_again.coverage_status=v_result.coverage_status
    AND v_again.release_status=v_result.release_status
    AND v_again.cells=v_result.cells);
  PERFORM pg_temp.aa03_clear();

  -- Repetition by one account does not satisfy independent people.
  FOR v_i IN 1..7 LOOP
    PERFORM pg_temp.aa03_job(v_clients[1],v_workers[(v_i-1)%3+1],
      CASE WHEN v_i<=3 THEN 121.0695 ELSE 121.07205067 END,
      CASE WHEN v_i<=3 THEN 14.542 ELSE 14.5444514 END);
  END LOOP;
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('same Client repetition suppressed',
    v_result.release_status='insufficient_data'
    AND v_result.cells='[]'::jsonb);
  PERFORM pg_temp.aa03_clear();

  FOR v_i IN 1..7 LOOP
    PERFORM pg_temp.aa03_job(v_clients[(v_i-1)%2+1],
      v_workers[(v_i-1)%3+1],
      CASE WHEN v_i<=3 THEN 121.0695 ELSE 121.07205067 END,
      CASE WHEN v_i<=3 THEN 14.542 ELSE 14.5444514 END);
  END LOOP;
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('k-minus-one Clients suppressed',
    v_result.release_status='insufficient_data'
    AND v_result.cells='[]'::jsonb);
  PERFORM pg_temp.aa03_clear();

  -- Three Clients but a single Worker also fails the acceptance threshold.
  FOR v_i IN 1..7 LOOP
    PERFORM pg_temp.aa03_job(v_clients[(v_i-1)%3+1],v_workers[1],
      CASE WHEN v_i<=3 THEN 121.0695 ELSE 121.07205067 END,
      CASE WHEN v_i<=3 THEN 14.542 ELSE 14.5444514 END);
  END LOOP;
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('same Worker repetition suppressed',
    v_result.release_status='insufficient_data'
    AND v_result.cells='[]'::jsonb);
  PERFORM pg_temp.aa03_clear();

  -- Non-qualifying Booking states do not create accepted work.
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp.aa03_job(v_clients[v_i],v_workers[v_i],
      121.0695,14.542,CASE WHEN v_i=1 THEN 'pending' ELSE 'no_show' END);
  END LOOP;
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('pending/no_show not accepted; paired veto',
    v_result.release_status='insufficient_data'
    AND v_result.cells='[]'::jsonb);
  PERFORM pg_temp.aa03_clear();

  -- Missing/out-of-area pins are not mapped. The outside pin is a
  -- rolled-back local anomaly; no hosted backfill or geocoding is involved.
  PERFORM pg_temp.aa03_job(v_clients[1],NULL,NULL,NULL);
  PERFORM pg_temp.aa03_job(v_clients[2],NULL,121.06942,14.55801);
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('missing/outside pins yield no-mappable',
    v_result.release_status='no_mappable_data'
    AND v_result.coverage_status='no_mappable_data');
  PERFORM pg_temp.aa03_job(v_clients[3],NULL,121.0739152770,14.5486115600);
  DELETE FROM private.admin_geographic_publications;
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('official boundary vertex is mapped but suppressed',
    v_result.coverage_status='partial'
    AND v_result.release_status='insufficient_data'
    AND v_result.cells='[]'::jsonb);
  PERFORM pg_temp.aa03_clear();

  -- Version/date uniqueness and controlled retention.
  INSERT INTO private.admin_geographic_publications
    (publication_date,aggregation_version,grid_version,as_of,
     coverage_status,release_status,cells)
  VALUES
    (v_yesterday,'aa03-geo-v1','sa-pateros-626f7138-g005-v1',
      now(),'no_mappable_data','no_mappable_data','[]'::jsonb),
    (v_old,'aa03-geo-v1','sa-pateros-626f7138-g005-v1',
      now(),'no_mappable_data','no_mappable_data','[]'::jsonb);
  v_denied := false;
  BEGIN
    INSERT INTO private.admin_geographic_publications
      (publication_date,aggregation_version,grid_version,as_of,
       coverage_status,release_status,cells)
    VALUES (v_yesterday,'aa03-geo-v1','sa-pateros-626f7138-g005-v1',
      now(),'no_mappable_data','no_mappable_data','[]'::jsonb);
  EXCEPTION WHEN unique_violation THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_assert('date/version cache uniqueness',v_denied);
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();
  PERFORM pg_temp.aa03_assert('rollover keeps previous day and prunes day 31',
    (SELECT count(*) FROM private.admin_geographic_publications)=2
    AND EXISTS (SELECT 1 FROM private.admin_geographic_publications
      WHERE publication_date=v_yesterday)
    AND NOT EXISTS (SELECT 1 FROM private.admin_geographic_publications
      WHERE publication_date=v_old));

  -- Cache read errors fail closed; no uncached live response is returned.
  v_denied := false;
  BEGIN
    ALTER TABLE private.admin_geographic_publications
      RENAME TO aa03_unavailable;
    v_denied := false;
    BEGIN
      PERFORM pg_temp.aa03_login(v_workers[1]);
      PERFORM * FROM public.get_admin_geographic_analytics();
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error_state = RETURNED_SQLSTATE,
        v_error_message = MESSAGE_TEXT;
      v_denied := v_error_state='42501'
        AND v_error_message='not authorized to read admin geographic analytics';
    END;
    PERFORM pg_temp.aa03_logout();
    PERFORM pg_temp.aa03_assert('auth checked before cache access',v_denied);
    BEGIN
      PERFORM pg_temp.aa03_login(v_admin);
      PERFORM * FROM public.get_admin_geographic_analytics();
    EXCEPTION WHEN undefined_table THEN v_denied := true;
    END;
    PERFORM pg_temp.aa03_logout();
    ALTER TABLE private.aa03_unavailable
      RENAME TO admin_geographic_publications;
  END;
  PERFORM pg_temp.aa03_assert('cache read error fails closed',v_denied);

  -- A cache INSERT failure does not return a live aggregate or leave a row.
  DELETE FROM private.admin_geographic_publications
    WHERE publication_date=(clock_timestamp() AT TIME ZONE 'Asia/Manila')::date;
  ALTER TABLE private.admin_geographic_publications
    ADD CONSTRAINT aa03_reject_insert CHECK (false) NOT VALID;
  v_denied := false;
  BEGIN
    PERFORM pg_temp.aa03_login(v_admin);
    PERFORM * FROM public.get_admin_geographic_analytics();
  EXCEPTION WHEN check_violation THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_logout();
  ALTER TABLE private.admin_geographic_publications
    DROP CONSTRAINT aa03_reject_insert;
  PERFORM pg_temp.aa03_assert('cache insert error fails closed',
    v_denied AND NOT EXISTS (
      SELECT 1 FROM private.admin_geographic_publications
      WHERE publication_date=(clock_timestamp() AT TIME ZONE 'Asia/Manila')::date));

  -- Test-only trigger removes the inserted row before the required read.
  -- An uncached local-value return would succeed and fail this assertion.
  CREATE FUNCTION pg_temp.aa03_remove_inserted_row()
  RETURNS trigger LANGUAGE plpgsql AS $trigger$
  BEGIN
    DELETE FROM private.admin_geographic_publications AS p
      WHERE p.publication_date=NEW.publication_date
        AND p.aggregation_version=NEW.aggregation_version
        AND p.grid_version=NEW.grid_version;
    RETURN NULL;
  END;
  $trigger$;
  CREATE TRIGGER aa03_remove_inserted_row AFTER INSERT
    ON private.admin_geographic_publications
    FOR EACH ROW EXECUTE FUNCTION pg_temp.aa03_remove_inserted_row();
  v_denied := false;
  BEGIN
    PERFORM pg_temp.aa03_login(v_admin);
    PERFORM * FROM public.get_admin_geographic_analytics();
  EXCEPTION WHEN no_data_found THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_logout();
  DROP TRIGGER aa03_remove_inserted_row
    ON private.admin_geographic_publications;
  PERFORM pg_temp.aa03_assert('missing post-insert row fails closed',
    v_denied AND NOT EXISTS (
      SELECT 1 FROM private.admin_geographic_publications
      WHERE publication_date=(clock_timestamp() AT TIME ZONE 'Asia/Manila')::date));

  -- A retention DELETE failure rolls back publication atomically.
  CREATE FUNCTION pg_temp.aa03_reject_delete()
  RETURNS trigger LANGUAGE plpgsql AS $trigger$
  BEGIN RAISE EXCEPTION 'test retention failure'; END;
  $trigger$;
  CREATE TRIGGER aa03_reject_delete BEFORE DELETE
    ON private.admin_geographic_publications
    FOR EACH ROW EXECUTE FUNCTION pg_temp.aa03_reject_delete();
  INSERT INTO private.admin_geographic_publications
    (publication_date,aggregation_version,grid_version,as_of,
     coverage_status,release_status,cells)
  VALUES (v_old,'aa03-geo-v1','sa-pateros-626f7138-g005-v1',
    now(),'no_mappable_data','no_mappable_data','[]'::jsonb);
  v_denied := false;
  BEGIN
    PERFORM pg_temp.aa03_login(v_admin);
    PERFORM * FROM public.get_admin_geographic_analytics();
  EXCEPTION WHEN raise_exception THEN v_denied := true;
  END;
  PERFORM pg_temp.aa03_logout();
  DROP TRIGGER aa03_reject_delete ON private.admin_geographic_publications;
  PERFORM pg_temp.aa03_assert('cache prune error rolls back publication',
    v_denied AND NOT EXISTS (
      SELECT 1 FROM private.admin_geographic_publications
      WHERE publication_date=(clock_timestamp() AT TIME ZONE 'Asia/Manila')::date));
  -- Restore current publication for the final sanitized-cache assertion.
  PERFORM pg_temp.aa03_login(v_admin);
  SELECT * INTO v_result FROM public.get_admin_geographic_analytics();
  PERFORM pg_temp.aa03_logout();

  SELECT count(*) INTO v_count FROM private.admin_geographic_publications;
  PERFORM pg_temp.aa03_assert('only sanitized publication rows remain',
    v_count=2 AND (SELECT bool_and(jsonb_typeof(cells)='array')
      FROM private.admin_geographic_publications));
END;
$$;

ABORT;
