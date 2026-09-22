-- LOCAL ONLY. Run after the R6 migration, using the existing BEGIN/ABORT
-- SQL-matrix convention. All users, Jobs, skills and Broadcasts roll back.
BEGIN;

CREATE TEMP TABLE r6_opportunity_results (name text, ok boolean);

CREATE FUNCTION pg_temp.check_case(p_name text, p_ok boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO r6_opportunity_results VALUES (p_name, p_ok);
  IF p_ok IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: %', p_name;
  END IF;
  RAISE NOTICE 'PASS: %', p_name;
END;
$$;

CREATE FUNCTION pg_temp.broadcast_count()
RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM realtime.messages
  WHERE topic = 'worker:opportunities' AND event = 'job_opportunities_changed';
$$;

DO $$
DECLARE
  v_function regprocedure := 'private.r6_broadcast_job_opportunities_changed()'::regprocedure;
  v_worker uuid := gen_random_uuid();
  v_inactive uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_missing uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_skill uuid := gen_random_uuid();
  v_case record;
  v_before bigint;
  v_visible bigint;
  v_denied boolean;
  v_role text;
BEGIN
  PERFORM pg_temp.check_case('SELECT-only authenticated exact-topic active-Worker policy', EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'realtime' AND tablename = 'messages'
      AND policyname = 'R6 active workers can receive opportunity broadcasts'
      AND cmd = 'SELECT' AND roles = ARRAY['authenticated']::name[]
      AND qual LIKE '%extension = %broadcast%'
      AND qual LIKE '%realtime.topic()% = %worker:opportunities%'
      AND qual LIKE '%private.is_active_worker()%'
  ));
  PERFORM pg_temp.check_case('no authenticated/public Broadcast INSERT policy', NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'realtime' AND tablename = 'messages'
      AND cmd IN ('INSERT', 'ALL')
      AND roles && ARRAY['authenticated', 'public']::name[]
  ));
  PERFORM pg_temp.check_case('both existing R5 receive policies retained', (
    SELECT count(*) = 2 FROM pg_policies
    WHERE schemaname = 'realtime' AND tablename = 'messages'
      AND policyname IN (
        'R5 authenticated can receive booking message broadcasts',
        'R5 authenticated can receive own notification broadcasts'
      ) AND cmd = 'SELECT'
  ));
  PERFORM pg_temp.check_case('private trigger is postgres-owned DEFINER with empty search_path', EXISTS (
    SELECT 1 FROM pg_proc WHERE oid = v_function
      AND prosecdef AND pg_get_userbyid(proowner) = 'postgres'
      AND proconfig @> ARRAY['search_path=""']
      AND prorettype = 'trigger'::regtype
  ));
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    PERFORM pg_temp.check_case(v_role || ' cannot execute broadcast function',
      NOT has_function_privilege(v_role, v_function, 'EXECUTE'));
  END LOOP;
  PERFORM pg_temp.check_case('both tables have AFTER STATEMENT INSERT/UPDATE/DELETE triggers', (
    SELECT count(*) = 2 FROM pg_trigger
    WHERE tgfoid = v_function AND tgtype = 28 AND tgenabled = 'O'
      AND tgrelid IN ('public.job_postings'::regclass, 'public.job_skills'::regclass)
  ));

  -- Existing trusted local fixture convention; no passwords/sessions required.
  FOR v_case IN SELECT * FROM (VALUES
    (v_worker, 'worker', true), (v_inactive, 'worker', false),
    (v_client, 'client', true), (v_admin, 'administrator', true)
  ) AS f(id, role, active) LOOP
    INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
    VALUES (v_case.id, 'authenticated', 'authenticated',
      'r6-local-' || v_case.id || '@example.test', '{}'::jsonb, '{}'::jsonb);
    INSERT INTO public.users (id, email, full_name, phone, role, barangay, city, is_active)
    VALUES (v_case.id, 'r6-local-' || v_case.id || '@example.test',
      'R6 local fixture', '09000000000', v_case.role, 'Santa Ana', 'Pateros', v_case.active);
  END LOOP;

  INSERT INTO public.skills (id, skill_name) VALUES (v_skill, 'R6 local ' || v_skill);
  v_before := pg_temp.broadcast_count();
  INSERT INTO public.job_postings (id, client_id, title, description, address, payment_method)
  VALUES (v_job, v_client, 'R6 local', 'Private test description', 'Private test address', 'cod');
  PERFORM pg_temp.check_case('Job INSERT broadcasts', pg_temp.broadcast_count() > v_before);

  v_before := pg_temp.broadcast_count();
  INSERT INTO public.job_skills (job_id, skill_id) VALUES (v_job, v_skill);
  PERFORM pg_temp.check_case('required-skill INSERT broadcasts', pg_temp.broadcast_count() > v_before);
  v_before := pg_temp.broadcast_count();
  UPDATE public.job_skills SET skill_id = v_skill WHERE job_id = v_job;
  PERFORM pg_temp.check_case('required-skill UPDATE broadcasts', pg_temp.broadcast_count() > v_before);
  v_before := pg_temp.broadcast_count();
  DELETE FROM public.job_skills WHERE job_id = v_job;
  PERFORM pg_temp.check_case('required-skill DELETE broadcasts', pg_temp.broadcast_count() > v_before);
  v_before := pg_temp.broadcast_count();
  UPDATE public.job_postings SET description = 'Changed private text' WHERE id = v_job;
  PERFORM pg_temp.check_case('Job UPDATE broadcasts', pg_temp.broadcast_count() > v_before);
  v_before := pg_temp.broadcast_count();
  DELETE FROM public.job_postings WHERE id = v_job;
  PERFORM pg_temp.check_case('Job DELETE broadcasts', pg_temp.broadcast_count() > v_before);

  PERFORM pg_temp.check_case('private Broadcast contains no business data', NOT EXISTS (
    SELECT 1 FROM realtime.messages
    WHERE topic = 'worker:opportunities' AND event = 'job_opportunities_changed'
      AND (private IS DISTINCT FROM true OR extension <> 'broadcast'
        -- realtime.send may add its own transport id; the trigger supplies {}.
        OR payload IS NULL OR payload - 'id' <> '{}'::jsonb)
  ));

  v_before := pg_temp.broadcast_count();
  BEGIN
    INSERT INTO public.job_postings (id, client_id, title, payment_method)
    VALUES (v_job, v_client, 'Rolled back', 'cod');
    RAISE EXCEPTION 'intentional local rollback';
  EXCEPTION WHEN raise_exception THEN
    NULL;
  END;
  PERFORM pg_temp.check_case('rolled-back Job retains no event or row',
    pg_temp.broadcast_count() = v_before
    AND NOT EXISTS (SELECT 1 FROM public.job_postings WHERE id = v_job));

  FOR v_case IN SELECT * FROM (VALUES
    ('active Worker', v_worker, 'worker:opportunities', true),
    ('inactive Worker', v_inactive, 'worker:opportunities', false),
    ('Client', v_client, 'worker:opportunities', false),
    ('Administrator', v_admin, 'worker:opportunities', false),
    ('missing account', v_missing, 'worker:opportunities', false),
    ('wrong topic', v_worker, 'worker:opportunities:other', false),
    ('case-sensitive topic', v_worker, 'Worker:opportunities', false)
  ) AS f(label, id, topic, allowed) LOOP
    PERFORM set_config('request.jwt.claim.sub', v_case.id::text, true);
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_case.id, 'role', 'authenticated')::text, true);
    PERFORM set_config('realtime.topic', v_case.topic, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_visible FROM realtime.messages
      WHERE topic = 'worker:opportunities' AND event = 'job_opportunities_changed';
    RESET ROLE;
    PERFORM pg_temp.check_case(v_case.label || ' receive authorization',
      (v_visible > 0) = v_case.allowed);
  END LOOP;

  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  PERFORM set_config('realtime.topic', 'worker:opportunities', true);
  v_denied := false;
  BEGIN
    SET LOCAL ROLE anon;
    SELECT count(*) INTO v_visible FROM realtime.messages
      WHERE topic = 'worker:opportunities' AND event = 'job_opportunities_changed';
    RESET ROLE;
    v_denied := v_visible = 0;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_denied := true;
  END;
  PERFORM pg_temp.check_case('anonymous receive denied', v_denied);

  PERFORM set_config('request.jwt.claim.sub', v_worker::text, true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_worker, 'role', 'authenticated')::text, true);
  v_denied := false;
  BEGIN
    SET LOCAL ROLE authenticated;
    INSERT INTO realtime.messages (topic, event, extension, private, payload)
    VALUES ('worker:opportunities', 'job_opportunities_changed', 'broadcast', true, '{}');
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_denied := true;
  END;
  PERFORM pg_temp.check_case('active Worker cannot send Broadcast', v_denied);

  PERFORM pg_temp.check_case('matching function unchanged',
    md5(pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure))
      = 'b9b686e6b0b9a87ee8618b5600b1ed62');
  PERFORM pg_temp.check_case('opportunity RPC unchanged',
    md5(pg_get_functiondef('public.list_my_job_opportunities()'::regprocedure))
      = 'a135ec4ddac213df3f3ef147f93e0fc9');
END;
$$;

SELECT count(*) AS passed, count(*) FILTER (WHERE NOT ok) AS failed
FROM r6_opportunity_results;
ABORT;
