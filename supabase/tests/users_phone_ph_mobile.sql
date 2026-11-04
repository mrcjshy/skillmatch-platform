-- users.phone Philippine mobile rule — local SQL verification. Disposable fixtures; ROLLBACKs.
BEGIN;
CREATE TEMP TABLE ph_results (n int, name text, ok boolean, detail text);
CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ph_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name; ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail; END IF;
END; $$;

-- Inserts one account with the given phone; returns 'ok' or the SQLSTATE.
CREATE OR REPLACE FUNCTION pg_temp.try_phone(p_id uuid, p_phone text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000', p_id, 'authenticated', 'authenticated', p_id || '@example.test', 'x', now(), '{}', '{}', now(), now());
  BEGIN
    INSERT INTO public.users(id,email,full_name,phone,role,barangay,city,is_active)
    VALUES (p_id, p_id || '@example.test', 'Phone Rule', p_phone, 'client', 'Santa Ana', 'Pateros', true);
    RETURN 'ok';
  EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
  END;
END; $$;

SELECT pg_temp.pass(1, 'app form +639XXXXXXXXX accepted', pg_temp.try_phone('06060606-0000-4000-8000-000000000001', '+639171234567') = 'ok');
SELECT pg_temp.pass(1, 'legacy 09XXXXXXXXX accepted', pg_temp.try_phone('06060606-0000-4000-8000-000000000002', '09171234567') = 'ok');
SELECT pg_temp.pass(2, 'too short refused', pg_temp.try_phone('06060606-0000-4000-8000-000000000003', '0917123456') = '23514');
SELECT pg_temp.pass(2, 'too long refused', pg_temp.try_phone('06060606-0000-4000-8000-000000000004', '+6391712345678') = '23514');
SELECT pg_temp.pass(2, 'landline refused', pg_temp.try_phone('06060606-0000-4000-8000-000000000005', '0281234567') = '23514');
SELECT pg_temp.pass(2, 'foreign number refused', pg_temp.try_phone('06060606-0000-4000-8000-000000000006', '+14155552671') = '23514');
SELECT pg_temp.pass(2, 'spaces or letters refused', pg_temp.try_phone('06060606-0000-4000-8000-000000000007', '0917 123 4567') = '23514');
SELECT pg_temp.pass(2, 'free text refused', pg_temp.try_phone('06060606-0000-4000-8000-000000000008', 'call me') = '23514');
SELECT pg_temp.pass(3, 'existing update to an invalid number refused',
  (SELECT pg_temp.try_phone('06060606-0000-4000-8000-000000000009', '+639181234567') = 'ok')
  AND NOT EXISTS (SELECT 1 FROM public.users WHERE phone = 'x'));
DO $$ BEGIN
  BEGIN
    UPDATE public.users SET phone = '12345' WHERE id = '06060606-0000-4000-8000-000000000009';
    PERFORM pg_temp.pass(3, 'update to invalid phone is refused', false, 'update succeeded');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.pass(3, 'update to invalid phone is refused', true);
  END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM ph_results;
ROLLBACK;
