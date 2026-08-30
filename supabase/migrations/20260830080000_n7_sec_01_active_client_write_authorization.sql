-- ============================================================
-- N7-SEC-01: ACTIVE-CLIENT WRITE AUTHORIZATION
-- ============================================================
--
-- PROBLEM
-- -------
-- The live-schema baseline authorizes job_postings and job_skills
-- writes by OWNERSHIP ONLY:
--
--   job_postings INSERT  WITH CHECK (client_id = auth.uid())
--   job_postings UPDATE  USING      (client_id = auth.uid())   -- no WITH CHECK
--   job_postings DELETE  USING      (client_id = auth.uid())
--   job_skills   ALL     USING      (job_id IN (own jobs))     -- no WITH CHECK
--
-- Nothing tests the authoritative application role or active status.
-- Any authenticated user -- a worker, an administrator, or a
-- deactivated account holding a still-valid session -- can insert a
-- job_postings row using its own UUID as client_id, and then manage
-- that job's job_skills through the ownership-scoped policy. The
-- UPDATE policies also lack an explicit WITH CHECK, so a permitted
-- row may be updated into a shape the policy would not have allowed
-- (for job_postings, re-pointing client_id; for job_skills, moving a
-- row to a job the caller does not own).
--
-- SOLUTION
-- --------
-- 1. Add private.is_active_client(), the client counterpart of the
--    existing private.is_active_worker() (Phase 0, Piece B).
-- 2. Replace the four write policies with role-aware equivalents that
--    require BOTH ownership AND an active authoritative client, and
--    give every UPDATE policy an explicit WITH CHECK.
--
-- SELECT policies are deliberately left byte-for-byte unchanged:
-- matching (D-002) requires workers to read open jobs and their
-- required skills. This migration hardens writes only.
--
-- The 11-table ERD, the guard triggers, and every other policy are
-- untouched. No new decision record and no new gap entry are created
-- by this migration.
-- ============================================================


-- ---------- HELPER ----------

-- Mirrors private.is_active_worker() exactly: SQL, STABLE,
-- SECURITY DEFINER with an empty search_path, schema-qualified
-- relations. SECURITY DEFINER is required so that an ordinary caller
-- can evaluate its own authoritative role without needing SELECT
-- privileges beyond the self-row RLS policy on public.users.
CREATE OR REPLACE FUNCTION private.is_active_client()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users AS u
    WHERE u.id = auth.uid()
      AND u.role = 'client'
      AND u.is_active = true
  );
$$;


COMMENT ON FUNCTION private.is_active_client() IS
  'N7-SEC-01: true when the current caller is an active authoritative '
  'client in public.users. Counterpart of private.is_active_worker(). '
  'SECURITY DEFINER with an empty search_path, following the Phase 0 '
  'Piece B convention.';


-- Public execution is revoked; only authenticated callers and trusted
-- backend paths may evaluate it. Matches the Piece B grant surface.
REVOKE ALL ON FUNCTION private.is_active_client() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION private.is_active_client()
TO authenticated, service_role;


-- ---------- job_postings WRITE POLICIES ----------

DROP POLICY IF EXISTS "Clients can insert their own jobs" ON public.job_postings;

CREATE POLICY "Active clients can insert their own jobs"
  ON public.job_postings
  FOR INSERT
  TO authenticated
  WITH CHECK (
    private.is_active_client()
    AND client_id = auth.uid()
  );


DROP POLICY IF EXISTS "Clients can update their own jobs" ON public.job_postings;

-- The explicit WITH CHECK is load-bearing: without it the resulting
-- row is unchecked, so an owner could re-point client_id to another
-- user and hand the job away.
CREATE POLICY "Active clients can update their own jobs"
  ON public.job_postings
  FOR UPDATE
  TO authenticated
  USING (
    private.is_active_client()
    AND client_id = auth.uid()
  )
  WITH CHECK (
    private.is_active_client()
    AND client_id = auth.uid()
  );


DROP POLICY IF EXISTS "Clients can delete their own jobs" ON public.job_postings;

CREATE POLICY "Active clients can delete their own jobs"
  ON public.job_postings
  FOR DELETE
  TO authenticated
  USING (
    private.is_active_client()
    AND client_id = auth.uid()
  );


-- ---------- job_skills WRITE POLICIES ----------

-- The pre-existing SELECT policy "Anyone authenticated can read job
-- skills" (FOR SELECT USING (true)) is intentionally NOT touched: it
-- is the read surface the matching slice depends on. The owner-scoped
-- FOR ALL policy is replaced by three write-only policies so that no
-- FOR ALL policy remains on this table.

DROP POLICY IF EXISTS "Clients can manage their job skills" ON public.job_skills;

CREATE POLICY "Active clients can insert their job skills"
  ON public.job_skills
  FOR INSERT
  TO authenticated
  WITH CHECK (
    private.is_active_client()
    AND job_id IN (
      SELECT public.job_postings.id
      FROM public.job_postings
      WHERE public.job_postings.client_id = auth.uid()
    )
  );


-- USING bounds which existing rows may be updated; WITH CHECK bounds
-- the resulting row, preventing a job_skills row from being moved to
-- a job the caller does not own.
CREATE POLICY "Active clients can update their job skills"
  ON public.job_skills
  FOR UPDATE
  TO authenticated
  USING (
    private.is_active_client()
    AND job_id IN (
      SELECT public.job_postings.id
      FROM public.job_postings
      WHERE public.job_postings.client_id = auth.uid()
    )
  )
  WITH CHECK (
    private.is_active_client()
    AND job_id IN (
      SELECT public.job_postings.id
      FROM public.job_postings
      WHERE public.job_postings.client_id = auth.uid()
    )
  );


CREATE POLICY "Active clients can delete their job skills"
  ON public.job_skills
  FOR DELETE
  TO authenticated
  USING (
    private.is_active_client()
    AND job_id IN (
      SELECT public.job_postings.id
      FROM public.job_postings
      WHERE public.job_postings.client_id = auth.uid()
    )
  );
