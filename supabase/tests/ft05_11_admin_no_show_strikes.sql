-- FT-05 #11 local SQL verification. Disposable fixtures only.
BEGIN;

CREATE TEMP TABLE ft05_11_results (n integer, name text, ok boolean, detail text);
GRANT INSERT ON ft05_11_results TO authenticated;
CREATE OR REPLACE FUNCTION pg_temp.pass(p_n integer,p_name text,p_ok boolean,p_detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ft05_11_results VALUES(p_n,p_name,p_ok,p_detail); IF p_ok THEN RAISE NOTICE 'PASS % %',p_n,p_name; ELSE RAISE NOTICE 'FAIL % % %',p_n,p_name,p_detail; END IF; END;
$$;
CREATE OR REPLACE FUNCTION pg_temp.jwt(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM set_config('request.jwt.claims',json_build_object('sub',p_uid::text,'role','authenticated')::text,true); PERFORM set_config('request.jwt.claim.sub',p_uid::text,true); PERFORM set_config('role','authenticated',true); END;
$$;
CREATE OR REPLACE FUNCTION pg_temp.clear_jwt() RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM set_config('request.jwt.claims','',true); PERFORM set_config('request.jwt.claim.sub','',true); PERFORM set_config('role','postgres',true); RESET ROLE; END;
$$;
CREATE OR REPLACE FUNCTION pg_temp.strike_state(p_caller uuid,p_report uuid,p_response text DEFAULT 'Reviewed no-show evidence.') RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := '00000'; BEGIN PERFORM pg_temp.jwt(p_caller); BEGIN PERFORM public.resolve_no_show_report_with_strike(p_report,p_response); EXCEPTION WHEN OTHERS THEN s:=SQLSTATE; END; PERFORM pg_temp.clear_jwt(); RETURN s; END;
$$;

DO $$
DECLARE
  worker uuid := '11111111-0500-4000-8000-000000000001'; client uuid := '11111111-0500-4000-8000-000000000002'; admin uuid := '11111111-0500-4000-8000-000000000003';
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) VALUES
    ('00000000-0000-0000-0000-000000000000',worker,'authenticated','authenticated','ft0511-worker@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
    ('00000000-0000-0000-0000-000000000000',client,'authenticated','authenticated','ft0511-client@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
    ('00000000-0000-0000-0000-000000000000',admin,'authenticated','authenticated','ft0511-admin@example.test',crypt('local-only',gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}','{}',now(),now());
  INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active) VALUES
    (worker,'ft0511-worker@example.test','FT05 Worker','09110000001','worker','Santa Ana','Pateros',true),
    (client,'ft0511-client@example.test','FT05 Client','09110000002','client','Santa Ana','Pateros',true),
    (admin,'ft0511-admin@example.test','FT05 Admin','09110000003','administrator','Santa Ana','Pateros',true);
  INSERT INTO public.worker_profiles(id,user_id,bio,badge_level,availability_status,is_verified,strike_count) VALUES('11111111-0500-4000-8000-000000000004',worker,'fixture','none','available',true,0);
  INSERT INTO public.job_postings(id,client_id,title,description,address,barangay,city,scheduled_at,status,budget,payment_method) VALUES('11111111-0500-4000-8000-000000000005',client,'FT05 report fixture','fixture','Fixture Street','Santa Ana','Pateros',now()+interval '1 day','matched',500,'cod');
  INSERT INTO public.bookings(id,job_id,worker_id,client_id,status,payment_method,payment_status) VALUES('11111111-0500-4000-8000-000000000006','11111111-0500-4000-8000-000000000005',worker,client,'confirmed','cod','pending');
END;
$$;

DO $$
DECLARE
  worker uuid := '11111111-0500-4000-8000-000000000001'; client uuid := '11111111-0500-4000-8000-000000000002'; admin uuid := '11111111-0500-4000-8000-000000000003';
  report1 uuid; report2 uuid; report3 uuid; ordinary uuid; ordinary_under_review uuid; ordinary_dismiss uuid; dismissed uuid; client_target uuid; other_category uuid; count3 uuid; inactive_report uuid; s text; discipline record;
BEGIN
  PERFORM pg_temp.jwt(client);
  SELECT report_id INTO report1 FROM public.submit_my_booking_report('11111111-0500-4000-8000-000000000006','no-show','Worker did not arrive.');
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(1,'report submission causes no strike',(SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=0);

  PERFORM pg_temp.jwt(admin);
  SELECT * INTO discipline FROM public.get_report_discipline_state(report1);
  PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(2,'discipline read derives eligibility without Worker id',discipline.eligible AND discipline.current_strike_count=0 AND NOT discipline.would_suspend);
  s:=pg_temp.strike_state(client,report1); PERFORM pg_temp.pass(3,'non-Admin strike is 42501',s='42501',s);
  s:=pg_temp.strike_state(admin,'11111111-0500-4000-8000-000000000099'); PERFORM pg_temp.pass(4,'missing report is SM409',s='SM409',s);
  s:=pg_temp.strike_state(admin,report1);
  PERFORM pg_temp.pass(5,'eligible first strike increments exactly once',s='00000' AND (SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=1 AND (SELECT status FROM public.reports WHERE id=report1)='resolved',s);
  PERFORM pg_temp.pass(6,'first strike leaves active unchanged',(SELECT is_active FROM public.users WHERE id=worker));
  PERFORM pg_temp.pass(7,'first strike emits exactly one strike notification',(SELECT count(*) FROM public.notifications WHERE user_id=worker AND type='no_show_strike')=1);
  s:=pg_temp.strike_state(admin,report1); PERFORM pg_temp.pass(8,'same report repeat is SM409 without increment or notification',s='SM409' AND (SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=1 AND (SELECT count(*) FROM public.notifications WHERE user_id=worker AND type='no_show_strike')=1,s);

  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES(client,worker,'11111111-0500-4000-8000-000000000006','no-show','Second no-show.') RETURNING id INTO report2;
  s:=pg_temp.strike_state(admin,report2); PERFORM pg_temp.pass(9,'second distinct report serially increments to two',s='00000' AND (SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=2 AND (SELECT is_active FROM public.users WHERE id=worker),s);
  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES(client,worker,'11111111-0500-4000-8000-000000000006','no-show','Third no-show.') RETURNING id INTO report3;
  s:=pg_temp.strike_state(admin,report3);
  PERFORM pg_temp.pass(10,'third strike flips active true to false',s='00000' AND (SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=3 AND NOT (SELECT is_active FROM public.users WHERE id=worker),s);
  PERFORM pg_temp.pass(11,'three strikes emit three strike notifications',(SELECT count(*) FROM public.notifications WHERE user_id=worker AND type='no_show_strike')=3);
  PERFORM pg_temp.pass(12,'threshold crossing emits one suspension notification',(SELECT count(*) FROM public.notifications WHERE user_id=worker AND type='account_suspended')=1);

  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES(client,worker,'11111111-0500-4000-8000-000000000006','no-show','Already maximum.') RETURNING id INTO count3;
  s:=pg_temp.strike_state(admin,count3); PERFORM pg_temp.pass(13,'count three refuses further strike',s='SM409' AND (SELECT status FROM public.reports WHERE id=count3)='submitted',s);
  UPDATE public.reports SET status='dismissed',admin_response='Test cleanup.',reviewed_by=admin,reviewed_at=now() WHERE id=count3;

  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES(client,worker,'11111111-0500-4000-8000-000000000006','behavior','Other category.') RETURNING id INTO other_category;
  s:=pg_temp.strike_state(admin,other_category); PERFORM pg_temp.pass(14,'non-no-show is SM409',s='SM409',s);
  UPDATE public.reports SET status='dismissed',admin_response='Test cleanup.',reviewed_by=admin,reviewed_at=now() WHERE id=other_category;
  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES(worker,client,'11111111-0500-4000-8000-000000000006','no-show','Client target.') RETURNING id INTO client_target;
  s:=pg_temp.strike_state(admin,client_target); PERFORM pg_temp.pass(15,'Client target is SM409',s='SM409',s);

  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description,status,admin_response,reviewed_by,reviewed_at) VALUES(client,worker,'11111111-0500-4000-8000-000000000006','no-show','Dismissed.','dismissed','Dismissed normally.',admin,now()) RETURNING id INTO dismissed;
  s:=pg_temp.strike_state(admin,dismissed); PERFORM pg_temp.pass(16,'dismissed report is SM409',s='SM409',s);

  UPDATE public.worker_profiles SET strike_count=0 WHERE user_id=worker; UPDATE public.users SET is_active=true WHERE id=worker;
  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES(client,worker,'11111111-0500-4000-8000-000000000006','no-show','Ordinary resolution.') RETURNING id INTO ordinary;
  PERFORM pg_temp.jwt(admin); PERFORM public.review_report(ordinary,'resolved','Resolved without discipline.'); PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(17,'ordinary Resolve causes no hidden strike or discipline notification',(SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=0 AND NOT EXISTS(SELECT 1 FROM public.notifications WHERE user_id=worker AND type='no_show_strike' AND created_at >= (SELECT reviewed_at FROM public.reports WHERE id=ordinary)));

  INSERT INTO public.reports(reporter_id,category,description) VALUES(client,'app_issue','Ordinary under-review fixture.') RETURNING id INTO ordinary_under_review;
  PERFORM pg_temp.jwt(admin); PERFORM public.review_report(ordinary_under_review,'under_review',NULL); PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(18,'ordinary Under Review causes no strike',(SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=0);
  INSERT INTO public.reports(reporter_id,category,description) VALUES(client,'app_issue','Ordinary dismiss fixture.') RETURNING id INTO ordinary_dismiss;
  PERFORM pg_temp.jwt(admin); PERFORM public.review_report(ordinary_dismiss,'dismissed','Dismissed without discipline.'); PERFORM pg_temp.clear_jwt();
  PERFORM pg_temp.pass(19,'ordinary Dismiss causes no strike',(SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=0);

  UPDATE public.worker_profiles SET strike_count=2 WHERE user_id=worker; UPDATE public.users SET is_active=false WHERE id=worker;
  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES(client,worker,'11111111-0500-4000-8000-000000000006','no-show','Inactive threshold.') RETURNING id INTO inactive_report;
  s:=pg_temp.strike_state(admin,inactive_report);
  PERFORM pg_temp.pass(20,'already-inactive 2 to 3 emits one strike and no suspension notice',s='00000' AND (SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=3 AND NOT (SELECT is_active FROM public.users WHERE id=worker) AND (SELECT count(*) FROM public.notifications WHERE user_id=worker AND type='no_show_strike')=4 AND (SELECT count(*) FROM public.notifications WHERE user_id=worker AND type='account_suspended')=1,s);
END;
$$;

DO $$
DECLARE worker uuid := '11111111-0500-4000-8000-000000000001'; client uuid := '11111111-0500-4000-8000-000000000002'; admin uuid := '11111111-0500-4000-8000-000000000003'; failure_report uuid; s text;
BEGIN
  UPDATE public.worker_profiles SET strike_count=2 WHERE user_id=worker; UPDATE public.users SET is_active=true WHERE id=worker;
  INSERT INTO public.reports(reporter_id,reported_user_id,booking_id,category,description) VALUES(client,worker,'11111111-0500-4000-8000-000000000006','no-show','Atomic failure.') RETURNING id INTO failure_report;
  CREATE OR REPLACE FUNCTION private.emit_notification(p_user_id uuid,p_type text,p_message text) RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $fail$ BEGIN RAISE EXCEPTION 'FT05 forced notification failure'; END; $fail$;
  s:=pg_temp.strike_state(admin,failure_report);
  PERFORM pg_temp.pass(21,'notification failure propagates',s<>'00000',s);
  PERFORM pg_temp.pass(22,'notification failure rolls back report strike and threshold suspension',(SELECT status FROM public.reports WHERE id=failure_report)='submitted' AND (SELECT strike_count FROM public.worker_profiles WHERE user_id=worker)=2 AND (SELECT is_active FROM public.users WHERE id=worker));
  PERFORM pg_temp.pass(23,'discipline never mutates Booking Job or payment state',EXISTS(
    SELECT 1 FROM public.bookings b
    JOIN public.job_postings j ON j.id=b.job_id
    WHERE b.id='11111111-0500-4000-8000-000000000006'
      AND b.status='confirmed' AND b.payment_method='cod' AND b.payment_status='pending'
      AND j.status='matched' AND j.payment_method='cod'
  ));
END;
$$;

DO $$ DECLARE failed integer; BEGIN SELECT count(*) INTO failed FROM ft05_11_results WHERE NOT ok; IF failed<>0 THEN RAISE EXCEPTION 'FT-05 #11 failed % assertions',failed; END IF; RAISE NOTICE 'FT-05 #11: % assertions passed',(SELECT count(*) FROM ft05_11_results); END; $$;
ROLLBACK;
