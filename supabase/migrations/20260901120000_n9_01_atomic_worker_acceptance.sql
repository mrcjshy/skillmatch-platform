-- ============================================================
-- N9-01: ATOMIC WORKER ACCEPTANCE
-- ============================================================
--
-- SCOPE
-- -----
-- Closes the write half of the D-003 flow:
--
--   Client posts a job
--   -> the system ranks eligible Workers        (N8-DB, unchanged)
--   -> a matched Worker reads the opportunity   (N8-W,  unchanged)
--   -> the Worker accepts                       (THIS PIECE)
--   -> the FIRST valid acceptance wins, atomically
--   -> exactly one confirmed Booking exists and the Job becomes matched
--
-- The Client never chooses a Worker, never assigns worker_id, and after
-- N9 cannot fabricate a Booking at all.
--
-- This migration adds ONE FUNCTION and REWORKS FOUR POLICIES. It creates
-- no table, no column, no index, and no trigger, so the locked 11-table
-- ERD (D-001) is untouched. The matching engine is not modified:
-- private.compute_job_matches(), private.location_points(),
-- public.list_my_job_opportunities() and public.match_workers_for_job()
-- are all left exactly as they are, including their ACLs.
--
-- WHY THE LEGACY BOOKING POLICIES MUST GO
-- ---------------------------------------
-- The live-schema baseline shipped two policies that predate D-003 and
-- directly contradict it:
--
--   INSERT "System can insert bookings"
--     WITH CHECK (client_id = auth.uid())
--
-- Despite the name this is not a system policy. It constrains only
-- client_id, so ANY authenticated Client could insert a Booking naming
-- ANY worker_id, for any job, at any time -- Client-selection of a
-- Worker, and a complete bypass of the atomic claim below.
--
--   UPDATE "Workers and clients can update their own bookings"
--     USING (worker_id = auth.uid() OR client_id = auth.uid())
--     -- and NO WITH CHECK
--
-- Without a WITH CHECK the resulting row is unconstrained (the same
-- defect N7-SEC-01 fixed on job_postings), so either participant could
-- re-point worker_id to somebody else after the fact. A first-wins
-- claim that can be edited afterwards is not an invariant.
--
-- Both are dropped with NO replacement. With no INSERT and no UPDATE
-- policy, RLS denies every direct write from anon and authenticated,
-- and the only way a Booking can come into existence is the controlled
-- SECURITY DEFINER RPC below. The participant SELECT policy is
-- deliberately preserved unchanged.
--
-- WHY THE JOB POLICIES ARE NARROWED TO open-ONLY
-- ----------------------------------------------
-- Two further paths could unwind an acceptance through ordinary Client
-- DML, so both are closed here:
--
--   1. status revert. The Client UPDATE policy had no column
--      restriction, so an owning Client could set a matched Job back to
--      'open' and invite a second Booking. USING (status = 'open')
--      blocks leaving any non-open state; WITH CHECK (status = 'open')
--      blocks entering one. Editing an open job's title/budget/skills
--      still works, so N7 job posting is unaffected.
--
--   2. cascade delete. bookings.job_id references job_postings(id)
--      ON DELETE CASCADE. Deleting a matched Job would therefore
--      silently delete its confirmed Booking. N9 does NOT change the
--      foreign key; it removes the Client's authorization to reach it,
--      by allowing direct DELETE only while the Job is still open.
--
-- NO UNIQUE INDEX ON bookings.job_id
-- ----------------------------------
-- Deliberately omitted. Cancellation/rematching semantics are not
-- locked, and a plain UNIQUE(job_id) would permanently forbid a second
-- Booking per Job, breaking any future cancel-then-rematch. First-wins
-- here rests on the Job row lock plus the Job status transition plus
-- the open-only direct UPDATE/DELETE plus the absence of any direct
-- Booking INSERT/UPDATE. Uniqueness stays deferred defence-in-depth.
-- ============================================================


-- ---------- 1. ACCEPTANCE RPC ----------
--
-- SECURITY DEFINER is required: the function writes a Booking row the
-- caller does not own and transitions a Job owned by the Client. RLS on
-- public.bookings is enabled but NOT forced, so the postgres owner
-- bypasses it -- which is exactly why every direct client-role write
-- path is being removed above. VOLATILE is required because it writes.
--
-- There is no Worker-ID parameter. The Worker is always auth.uid(), so
-- there is no value a caller could substitute to accept on behalf of
-- someone else.

CREATE OR REPLACE FUNCTION public.accept_job_opportunity(p_job_id uuid)
RETURNS TABLE (
  booking_id     uuid,
  job_id         uuid,
  booking_status text,
  job_status     text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_job_status text;
  v_client_id  uuid;
  v_booking_id uuid;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (account level)
  --
  -- private.is_active_worker() answers "may this account use the
  -- acceptance API at all?" -- role = 'worker' AND is_active. Every
  -- denial (signed out, Client, Administrator, suspended Worker) raises
  -- the SAME error, so a rejected caller cannot tell which predicate
  -- failed and learns nothing about any Job.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized to accept opportunities'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. LOCK THE TARGET JOB -- BEFORE any eligibility work
  --
  -- The Job row is the contended resource: one Job, therefore one
  -- winner. FOR UPDATE takes a row-level exclusive lock, so a second
  -- concurrent acceptance blocks here rather than racing ahead.
  --
  -- Order matters. Locking first means the status guard immediately
  -- below does all the work: under READ COMMITTED a blocked
  -- SELECT ... FOR UPDATE re-reads the NEWEST COMMITTED version of the
  -- row once the lock is granted, so the loser sees 'matched' -- the
  -- value the winner just committed -- and stops before writing
  -- anything. Evaluating eligibility first would let both callers pass
  -- and would need a second re-check anyway.
  ----------------------------------------------------------------
  SELECT jp.status::text, jp.client_id
    INTO v_job_status, v_client_id
  FROM public.job_postings AS jp
  WHERE jp.id = p_job_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 3. THE JOB MUST STILL BE OPEN
  --
  -- A Job that does not exist and a Job that is no longer open produce
  -- an IDENTICAL error, on purpose: a Worker must not be able to probe
  -- which Job ids exist, nor learn the state of Jobs they were never
  -- matched to. NOT FOUND covers the nonexistent case because the
  -- SELECT ... INTO above leaves FOUND false.
  ----------------------------------------------------------------
  IF NOT FOUND OR v_job_status IS DISTINCT FROM 'open' THEN
    RAISE EXCEPTION 'this opportunity is no longer available'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. ACCEPTANCE-TIME ELIGIBILITY -- via the authoritative scorer
  --
  -- Nothing about eligibility is recomputed here. One call to
  -- private.compute_job_matches() re-establishes ALL of D-002 Stage 1
  -- at acceptance time: role = 'worker', is_active, availability =
  -- 'available', is_verified, and required-skill overlap. That
  -- satisfies the recorded D-002 requirement to re-check is_active and
  -- is_verified at acceptance, and exceeds it -- availability and skill
  -- overlap are re-checked too.
  --
  -- Membership in the scorer's result IS the eligibility answer, so
  -- there is nothing further to test. This failure is deliberately
  -- distinct from the authorization failure in step 1: the caller is a
  -- legitimate Worker, they simply no longer match this Job.
  ----------------------------------------------------------------
  PERFORM 1
  FROM private.compute_job_matches(p_job_id) AS m
  WHERE m.worker_id = v_caller;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'you are no longer eligible for this opportunity'
      USING ERRCODE = 'SM403';
  END IF;

  ----------------------------------------------------------------
  -- 5. ATOMIC WRITES
  --
  -- Both writes run inside this function's single transaction. There is
  -- deliberately NO exception handler around them: any failure must
  -- propagate and abort the whole statement, so a Booking can never
  -- survive with the Job still open, and the Job can never end up
  -- matched without its winning Booking. Swallowing an error here would
  -- destroy exactly the invariant this function exists to provide.
  --
  -- Participant ids come from trusted sources only -- worker_id from
  -- auth.uid(), client_id from the LOCKED Job row -- never from caller
  -- input. status is written explicitly as 'confirmed' rather than
  -- inheriting the column default 'pending': under D-003 the Worker's
  -- acceptance IS the confirmation, there is no further party to
  -- approve it, and D-003 releases Worker contact details to the Client
  -- only after confirmation.
  --
  -- No payment state is invented. payment_status is omitted so its
  -- existing default 'pending' applies (meaning "not yet paid");
  -- payment_method, paymongo_ref and completed_at stay NULL.
  ----------------------------------------------------------------
  INSERT INTO public.bookings (job_id, worker_id, client_id, status)
  VALUES (p_job_id, v_caller, v_client_id, 'confirmed')
  RETURNING public.bookings.id INTO v_booking_id;

  UPDATE public.job_postings AS jp
  SET status = 'matched'
  WHERE jp.id = p_job_id;

  ----------------------------------------------------------------
  -- 6. RETURN THE MINIMUM PROJECTION
  --
  -- Read back from the persisted rows rather than echoing the constants
  -- written above, so the caller receives observed state.
  --
  -- No Client identity or contact data, no competitor Workers, no
  -- competitor scores, no candidate count, no rank. Client contact
  -- release after a confirmed Booking belongs to the confirmed-booking
  -- read surface, not to this function.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT b.id, b.job_id, b.status::text, jp.status::text
  FROM public.bookings AS b
  JOIN public.job_postings AS jp ON jp.id = b.job_id
  WHERE b.id = v_booking_id;
END;
$$;


COMMENT ON FUNCTION public.accept_job_opportunity(uuid) IS
  'N9-01: atomic Worker acceptance of a matched open Job (D-003). '
  'Takes only p_job_id -- the Worker is always auth.uid(), so no id can '
  'be substituted to accept for someone else. Requires an active '
  'authoritative Worker (42501), locks the Job row FOR UPDATE before '
  'checking anything else so the first valid acceptance wins, requires '
  'the Job to still be open (SM409, indistinguishable from a '
  'nonexistent Job), and re-checks D-002 Stage 1 eligibility by reusing '
  'private.compute_job_matches() (SM403). Creates exactly one '
  'confirmed Booking and transitions the Job to matched in one '
  'transaction. Returns booking_id, job_id, booking_status, job_status '
  'and nothing else. Creates no notification, message or payment state.';


-- Role-by-role revocation is required: schema public grants EXECUTE on
-- every new function to anon, authenticated and service_role by name,
-- so REVOKE ... FROM PUBLIC alone would leave them in place
-- (docs/SECURITY.md GAP-004). service_role stays revoked because it has
-- no auth.uid() and could never pass the caller gate.

REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.accept_job_opportunity(uuid) TO authenticated;


-- ---------- 2. REMOVE THE LEGACY DIRECT BOOKING WRITE SURFACE ----------
--
-- Dropped with no replacement. After this, public.bookings has zero
-- INSERT policies and zero UPDATE policies, so RLS denies every direct
-- write by anon and authenticated. Booking creation is reachable only
-- through public.accept_job_opportunity(); future cancellation,
-- completion, no-show and payment transitions will each need their own
-- controlled RPC rather than open row access.

DROP POLICY IF EXISTS "System can insert bookings" ON public.bookings;

DROP POLICY IF EXISTS "Workers and clients can update their own bookings" ON public.bookings;

-- "Workers and clients can view their own bookings" is intentionally
-- left untouched: both participants must still be able to read the
-- Booking that acceptance created.


-- ---------- 3. NARROW CLIENT JOB WRITES TO open-ONLY ----------

DROP POLICY IF EXISTS "Active clients can update their own jobs" ON public.job_postings;

-- USING gates the row being updated, WITH CHECK gates the resulting
-- row, and both require status = 'open'. Together they deny every
-- lifecycle transition through ordinary Client DML in both directions:
-- open -> matched/cancelled/completed is blocked by WITH CHECK, and
-- matched/cancelled/completed -> open is blocked by USING. Ordinary
-- edits to a still-open Job (title, description, budget, schedule,
-- location) remain permitted, so N7 job posting is unaffected. The
-- acceptance RPC performs the open -> matched transition as a trusted
-- SECURITY DEFINER path.
CREATE POLICY "Active clients can update their own open jobs"
  ON public.job_postings
  FOR UPDATE
  TO authenticated
  USING (
    private.is_active_client()
    AND client_id = auth.uid()
    AND status = 'open'
  )
  WITH CHECK (
    private.is_active_client()
    AND client_id = auth.uid()
    AND status = 'open'
  );


DROP POLICY IF EXISTS "Active clients can delete their own jobs" ON public.job_postings;

-- Load-bearing for booking preservation. bookings.job_id references
-- job_postings(id) ON DELETE CASCADE, so deleting a matched Job would
-- take its confirmed Booking with it. N9 does not alter that foreign
-- key -- it removes the authorization needed to reach it, by permitting
-- direct DELETE only while the Job is still open. A Client may still
-- withdraw a Job nobody has accepted.
CREATE POLICY "Active clients can delete their own open jobs"
  ON public.job_postings
  FOR DELETE
  TO authenticated
  USING (
    private.is_active_client()
    AND client_id = auth.uid()
    AND status = 'open'
  );
