-- R6-8J-F5A: Worker opportunity freshness, not a new business-data surface.
-- Clients receive only an empty invalidation and reread list_my_job_opportunities().
-- No matching, acceptance, Job creation, business-table RLS, or R5 policy changes.

CREATE POLICY "R6 active workers can receive opportunity broadcasts"
  ON realtime.messages
  FOR SELECT
  TO authenticated
  USING (
    realtime.messages.extension = 'broadcast'
    AND (SELECT realtime.topic()) = 'worker:opportunities'
    AND (SELECT private.is_active_worker())
  );

-- Follow the R5 private, postgres-owned, trigger-only broadcast pattern.
-- No client EXECUTE grant and no authenticated realtime.messages INSERT policy.
CREATE FUNCTION private.r6_broadcast_job_opportunities_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM realtime.send(
    '{}'::jsonb,
    'job_opportunities_changed',
    'worker:opportunities',
    true
  );
  RETURN NULL;
END;
$$;

ALTER FUNCTION private.r6_broadcast_job_opportunities_changed() OWNER TO postgres;

COMMENT ON FUNCTION private.r6_broadcast_job_opportunities_changed() IS
  'R6 trigger-only: Job/required-skill changes invalidate the private '
  'worker:opportunities topic with job_opportunities_changed and an empty payload. '
  'Workers must reread list_my_job_opportunities; no record or ranking is broadcast.';

REVOKE ALL ON FUNCTION private.r6_broadcast_job_opportunities_changed()
  FROM PUBLIC, anon, authenticated, service_role;

-- Statement-level triggers need no NEW/OLD record and emit one signal per
-- statement, including bulk skill writes. Sends share the write transaction;
-- rollback cannot leave a committed event. Mobile coalesces multi-table bursts.
CREATE TRIGGER r6_job_postings_opportunities_changed
  AFTER INSERT OR UPDATE OR DELETE ON public.job_postings
  FOR EACH STATEMENT
  EXECUTE FUNCTION private.r6_broadcast_job_opportunities_changed();

CREATE TRIGGER r6_job_skills_opportunities_changed
  AFTER INSERT OR UPDATE OR DELETE ON public.job_skills
  FOR EACH STATEMENT
  EXECUTE FUNCTION private.r6_broadcast_job_opportunities_changed();
