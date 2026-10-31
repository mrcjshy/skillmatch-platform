-- RF-03 local SQL verification: effective EXECUTE privileges on verify_worker
-- and its only caller. Catalog-only; no fixtures. Behavioral coverage of the
-- approve path and the direct-call denial lives in v3_db_03_worker_id_review.sql
-- (#14, #17, #17b, #18). Run after db reset; ROLLBACKs.

BEGIN;

CREATE TEMP TABLE rf03_results (n int, name text, ok boolean, detail text);

CREATE OR REPLACE FUNCTION pg_temp.pass(p_n int, p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO rf03_results VALUES (p_n, p_name, coalesce(p_ok, false), p_detail);
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS % %', p_n, p_name;
  ELSE RAISE NOTICE 'FAIL % % %', p_n, p_name, p_detail;
  END IF;
END;
$$;

DO $$
DECLARE r text;
BEGIN
  -- 1-4 effective privilege, including inherited PUBLIC
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    PERFORM pg_temp.pass(1, r || ' cannot EXECUTE verify_worker',
      NOT has_function_privilege(r, 'public.verify_worker(uuid)', 'EXECUTE'));
  END LOOP;
  PERFORM pg_temp.pass(4, 'no PUBLIC EXECUTE entry in proacl',
    NOT EXISTS (
      SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      WHERE p.oid = 'public.verify_worker(uuid)'::regprocedure
        AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'));

  -- 5-6 the only caller still works for Administrators
  PERFORM pg_temp.pass(5, 'authenticated can EXECUTE approve_worker_identity',
    has_function_privilege('authenticated', 'public.approve_worker_identity(uuid)', 'EXECUTE'));
  PERFORM pg_temp.pass(6, 'approve_worker_identity is SECURITY DEFINER owned by postgres',
    EXISTS (SELECT 1 FROM pg_proc p JOIN pg_roles o ON o.oid = p.proowner
            WHERE p.oid = 'public.approve_worker_identity(uuid)'::regprocedure
              AND p.prosecdef AND o.rolname = 'postgres'));

  -- 7 no other function in the database calls verify_worker (source scan)
  PERFORM pg_temp.pass(7, 'approve_worker_identity is the only caller',
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND p.oid <> 'public.verify_worker(uuid)'::regprocedure
       AND p.prosrc ILIKE '%public.verify_worker(%') = 1);
END;
$$;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM rf03_results;

ROLLBACK;
