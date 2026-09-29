-- V5-FIX local SQL verification. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE v5_outcome_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON v5_outcome_results TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.pass(
  p_n integer,
  p_name text,
  p_ok boolean,
  p_detail text DEFAULT ''
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO v5_outcome_results VALUES (p_n, p_name, p_ok, p_detail);
  IF p_ok THEN
    RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE
    RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.jwt(p_uid uuid)
RETURNS void LANGUAGE plpgsql AS $$
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
DECLARE
  v_state text := '00000';
BEGIN
  IF p_uid IS NOT NULL THEN PERFORM pg_temp.jwt(p_uid); END IF;
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  PERFORM pg_temp.clear_jwt();
  RETURN v_state;
END;
$$;

DO $$
DECLARE
  worker uuid := '15151515-0000-4000-8000-000000000001';
  client uuid := '15151515-0000-4000-8000-000000000002';
  admin uuid := '15151515-0000-4000-8000-000000000003';
BEGIN
  INSERT INTO auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) VALUES
    ('00000000-0000-0000-0000-000000000000',worker,'authenticated','authenticated','v5-worker@example.test',crypt('local-only',gen_salt('bf')),now(),'{}','{}',now(),now()),
    ('00000000-0000-0000-0000-000000000000',client,'authenticated','authenticated','v5-client@example.test',crypt('local-only',gen_salt('bf')),now(),'{}','{}',now(),now()),
    ('00000000-0000-0000-0000-000000000000',admin,'authenticated','authenticated','v5-admin@example.test',crypt('local-only',gen_salt('bf')),now(),'{}','{}',now(),now());

  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (worker,'v5-worker@example.test','V5 Worker','+639150000001','worker','Santa Ana','Pateros',true),
    (client,'v5-client@example.test','V5 Client','+639150000002','client','Santa Ana','Pateros',true),
    (admin,'v5-admin@example.test','V5 Admin','+639150000003','administrator','Santa Ana','Pateros',true);

  INSERT INTO public.worker_profiles(
    id,user_id,bio,badge_level,availability_status,is_verified,strike_count
  ) VALUES (
    '15151515-0000-4000-8000-000000000004',worker,'fixture','none','available',true,0
  );

  INSERT INTO public.job_postings(
    id,client_id,title,description,address,barangay,city,scheduled_at,status,budget,payment_method
  ) VALUES
    ('15151515-1000-4000-8000-000000000001',client,'V5 report one','fixture','Fixture Street','Santa Ana','Pateros',now()+interval '1 day','matched',500,'cod'),
    ('15151515-1000-4000-8000-000000000002',client,'V5 report two','fixture','Fixture Street','Santa Ana','Pateros',now()+interval '2 days','matched',500,'cod'),
    ('15151515-1000-4000-8000-000000000003',client,'V5 report three','fixture','Fixture Street','Santa Ana','Pateros',now()+interval '3 days','matched',500,'cod'),
    ('15151515-1000-4000-8000-000000000004',client,'V5 report inactive','fixture','Fixture Street','Santa Ana','Pateros',now()+interval '4 days','matched',500,'cod');

  INSERT INTO public.bookings(
    id,job_id,worker_id,client_id,status,payment_method,payment_status
  ) VALUES
    ('15151515-2000-4000-8000-000000000001','15151515-1000-4000-8000-000000000001',worker,client,'confirmed','cod','pending'),
    ('15151515-2000-4000-8000-000000000002','15151515-1000-4000-8000-000000000002',worker,client,'confirmed','cod','pending'),
    ('15151515-2000-4000-8000-000000000003','15151515-1000-4000-8000-000000000003',worker,client,'confirmed','cod','pending'),
    ('15151515-2000-4000-8000-000000000004','15151515-1000-4000-8000-000000000004',worker,client,'confirmed','cod','pending');
END;
$$;

DO $$
DECLARE
  worker uuid := '15151515-0000-4000-8000-000000000001';
  client uuid := '15151515-0000-4000-8000-000000000002';
  admin uuid := '15151515-0000-4000-8000-000000000003';
  report1 uuid;
  report2 uuid;
  report3 uuid;
  inactive_report uuid;
  ordinary_report uuid;
  v_state text;
BEGIN
  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES
    (client,worker,'15151515-2000-4000-8000-000000000001','no-show','First no-show.') RETURNING id INTO report1;
  v_state := pg_temp.state(format(
    'SELECT public.resolve_no_show_report_with_strike(%L,%L)',
    report1,
    'First reviewed no-show.'
  ), admin);
  PERFORM pg_temp.pass(1,'first strike writes no_show_strike',
    v_state='00000'
    AND (SELECT disciplinary_outcome FROM public.reports WHERE id=report1)='no_show_strike',v_state);

  v_state := pg_temp.state(format(
    'SELECT public.resolve_no_show_report_with_strike(%L,%L)',
    report1,
    'Repeated review.'
  ), admin);
  PERFORM pg_temp.pass(2,'repeat strike is ineligible and preserves outcome',
    v_state='SM409'
    AND (SELECT disciplinary_outcome FROM public.reports WHERE id=report1)='no_show_strike'
    AND (SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=1,v_state);

  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES
    (client,worker,'15151515-2000-4000-8000-000000000002','no-show','Second no-show.') RETURNING id INTO report2;
  v_state := pg_temp.state(format(
    'SELECT public.resolve_no_show_report_with_strike(%L,%L)',
    report2,
    'Second reviewed no-show.'
  ), admin);
  PERFORM pg_temp.pass(3,'second strike writes no_show_strike',
    v_state='00000'
    AND (SELECT disciplinary_outcome FROM public.reports WHERE id=report2)='no_show_strike'
    AND (SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=2,v_state);

  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES
    (client,worker,'15151515-2000-4000-8000-000000000003','no-show','Third no-show.') RETURNING id INTO report3;
  v_state := pg_temp.state(format(
    'SELECT public.resolve_no_show_report_with_strike(%L,%L)',
    report3,
    'Third reviewed no-show.'
  ), admin);
  PERFORM pg_temp.pass(4,'actual third-strike suspension is durable',
    v_state='00000'
    AND (SELECT disciplinary_outcome FROM public.reports WHERE id=report3)='account_suspended'
    AND NOT (SELECT is_active FROM public.users WHERE id=worker),v_state);

  UPDATE public.worker_profiles SET strike_count=2 WHERE user_id=worker;
  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES
    (client,worker,'15151515-2000-4000-8000-000000000004','no-show','Inactive Worker no-show.') RETURNING id INTO inactive_report;
  v_state := pg_temp.state(format(
    'SELECT public.resolve_no_show_report_with_strike(%L,%L)',
    inactive_report,
    'Reviewed while already inactive.'
  ), admin);
  PERFORM pg_temp.pass(5,'already-inactive third strike does not claim a new suspension',
    v_state='00000'
    AND (SELECT disciplinary_outcome FROM public.reports WHERE id=inactive_report)='no_show_strike'
    AND NOT (SELECT is_active FROM public.users WHERE id=worker),v_state);

  INSERT INTO public.reports(reporter_id,category,description)
    VALUES(client,'app_issue','Ordinary review fixture.') RETURNING id INTO ordinary_report;
  PERFORM pg_temp.jwt(admin);
  PERFORM public.review_report(ordinary_report,'resolved','Resolved without discipline.');
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(6,'ordinary review remains terminal and non-disciplinary',
    EXISTS(
      SELECT 1 FROM public.reports
      WHERE id=ordinary_report
        AND status='resolved'
        AND reviewed_at IS NOT NULL
        AND disciplinary_outcome IS NULL
    ));

  v_state := pg_temp.state(format(
    'UPDATE public.reports SET disciplinary_outcome=%L WHERE id=%L',
    'no_show_strike',ordinary_report
  ), admin);
  PERFORM pg_temp.pass(7,'Administrator cannot directly alter the marker',
    v_state='42501' AND (SELECT disciplinary_outcome FROM public.reports WHERE id=ordinary_report) IS NULL,v_state);
  v_state := pg_temp.state(format(
    'UPDATE public.reports SET disciplinary_outcome=%L WHERE id=%L',
    'no_show_strike',ordinary_report
  ), worker);
  PERFORM pg_temp.pass(8,'Worker cannot directly alter the marker',v_state='42501',v_state);
  v_state := pg_temp.state(format(
    'UPDATE public.reports SET disciplinary_outcome=%L WHERE id=%L',
    'no_show_strike',ordinary_report
  ), client);
  PERFORM pg_temp.pass(9,'Client cannot directly alter the marker',v_state='42501',v_state);

  v_state := pg_temp.state(format(
    'INSERT INTO public.reports(reporter_id,category,description,disciplinary_outcome) VALUES(%L,%L,%L,%L)',
    client,'app_issue','Invalid marker fixture.','caller_selected'
  ));
  PERFORM pg_temp.pass(10,'column rejects values outside the two-value allowlist',v_state='23514',v_state);

  PERFORM pg_temp.pass(11,'discipline RPC exposes no caller outcome parameter',
    (
      SELECT pronargs=2
        AND proargnames[1:2] = ARRAY['p_report_id','p_admin_response']::text[]
        AND NOT ('disciplinary_outcome'=ANY(proargnames[1:pronargs]))
      FROM pg_proc
      WHERE oid='public.resolve_no_show_report_with_strike(uuid,text)'::regprocedure
    ));
  PERFORM pg_temp.pass(12,'client roles retain no reports UPDATE privilege',
    NOT has_table_privilege('authenticated','public.reports','UPDATE')
    AND NOT has_column_privilege('authenticated','public.reports','disciplinary_outcome','UPDATE'));
END;
$$;

DO $$
DECLARE
  failed integer;
BEGIN
  SELECT count(*) INTO failed FROM v5_outcome_results WHERE NOT ok;
  IF failed <> 0 THEN
    RAISE EXCEPTION 'V5 disciplinary outcome failed % assertions', failed;
  END IF;
  RAISE NOTICE 'V5 disciplinary outcome: % assertions passed',
    (SELECT count(*) FROM v5_outcome_results);
END;
$$;

ROLLBACK;
