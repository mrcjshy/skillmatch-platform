-- LOCAL ONLY. Run after migrations with ON_ERROR_STOP. Never target hosted.
BEGIN;
CREATE FUNCTION pg_temp.ft06_assert(ok boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', label; END IF;
  RAISE NOTICE 'PASS: %', label;
END $$;

SELECT pg_temp.ft06_assert(count(*) = 3, 'three eligibility invalidation triggers')
FROM pg_trigger WHERE tgname IN ('ft06_users_eligibility_changed',
  'ft06_worker_profiles_eligibility_changed','ft06_worker_skills_eligibility_changed')
AND tgfoid = 'private.r6_broadcast_job_opportunities_changed()'::regprocedure
AND tgenabled = 'O' AND (tgtype & 1) = 0;

SELECT pg_temp.ft06_assert(prosecdef AND proconfig @> ARRAY['search_path=""']
  AND proowner = 'postgres'::regrole, 'existing trigger-only trusted boundary')
FROM pg_proc WHERE oid='private.r6_broadcast_job_opportunities_changed()'::regprocedure;
SELECT pg_temp.ft06_assert(NOT has_function_privilege('authenticated',
  'private.r6_broadcast_job_opportunities_changed()', 'EXECUTE'), 'no client trigger execute');
SELECT pg_temp.ft06_assert(NOT has_table_privilege('authenticated',
  'private.job_locations','SELECT'), 'private locations remain private');

CREATE TEMP TABLE ft06_events_before AS
SELECT count(*) AS n FROM realtime.messages
WHERE topic='worker:opportunities' AND event='job_opportunities_changed';
-- Statement triggers exercise emission without altering any business row.
UPDATE public.users SET is_active=is_active WHERE false;
UPDATE public.worker_profiles SET is_verified=is_verified WHERE false;
DELETE FROM public.worker_skills WHERE false;
SELECT pg_temp.ft06_assert(count(*)=(SELECT n+3 FROM ft06_events_before),
  'each eligibility statement emits only an invalidation')
FROM realtime.messages WHERE topic='worker:opportunities' AND event='job_opportunities_changed';
SELECT pg_temp.ft06_assert(NOT EXISTS (
  SELECT 1 FROM realtime.messages WHERE topic='worker:opportunities'
    AND event='job_opportunities_changed' AND (payload - 'id') <> '{}'::jsonb
), 'no coordinates, address, contact, or business record in invalidation payload');

-- realtime.send may attach its own generated transport id, never a business id.
SELECT pg_temp.ft06_assert(md5(pg_get_functiondef('private.compute_job_matches(uuid)'::regprocedure))
  = 'b9b686e6b0b9a87ee8618b5600b1ed62', 'matching unchanged');
ROLLBACK;
