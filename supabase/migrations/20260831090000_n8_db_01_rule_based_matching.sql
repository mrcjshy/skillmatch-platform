-- ============================================================
-- N8-DB-01: RULE-BASED MATCHING COMPUTATION
-- ============================================================
--
-- SCOPE
-- -----
-- Implements the matching computation locked by D-002 as amended
-- 2026-08-31 ("Verification Gate and Three-Factor Ranking") and the
-- boundary locked by the same date's clarification ("N8 Secure
-- Computation Boundary").
--
-- This migration adds FUNCTIONS AND THEIR ACLs ONLY. No table, no
-- column, no constraint, no policy, and no existing object is added,
-- altered, or dropped. The locked 11-table ERD (D-001) is untouched,
-- and the authenticated-wide SELECT policies on job_postings and
-- job_skills that this computation depends on are left exactly as
-- N7-SEC-01 left them.
--
-- MODEL (D-002 as amended)
-- ------------------------
-- Stage 1 -- eligibility (a hard filter, not a score):
--
--   users.role                          = 'worker'
--   users.is_active                     = true      -- active / not suspended
--   worker_profiles.availability_status = 'available'
--   worker_profiles.is_verified         = true
--   at least one required-skill overlap
--
-- Verification is a SAFETY PRECONDITION. It contributes no ranking
-- points. Neither does badge_level, nor worker_skills.proficiency_level
-- (retained for profile/explainability display only).
--
-- Stage 2 -- weighted ranking, 100 points total:
--
--   Skill    50 = matched required skills / total required skills * 50
--   Location 30 = same barangay + same city 30 | same city only 10 | else 0
--   Rating   20 = rating_avg / 5 * 20, or 12 for an unrated worker
--
-- Ranking order: total DESC, then fewer completed bookings, then
-- earlier registration.
--
-- SECURITY BOUNDARY
-- -----------------
--   private.compute_job_matches(job_id)    -- SECURITY INVOKER, not client-callable
--   public.match_workers_for_job(p_job_id) -- SECURITY DEFINER wrapper, authorizes first
--
-- The computation function holds no authorization logic and is not
-- reachable by any client role: EXECUTE is revoked from PUBLIC and
-- never granted to authenticated, anon, or service_role. All caller
-- authorization lives in the public wrapper and runs BEFORE any
-- matching row is produced.
-- ============================================================


-- ---------- 1. PRIVATE LOCATION HELPER ----------
--
-- Address-based only, per D-002: no GPS, no coordinates, no distance
-- calculation, no parsing of job_postings.address, no zone, and no
-- adjacency assumptions. Worker location comes from public.users
-- (barangay/city, both NOT NULL); job location comes from
-- public.job_postings (barangay/city, both NULLABLE).
--
-- NULL handling is load-bearing: SQL equality on two NULLs yields NULL
-- rather than true, so two absent barangays inside one matching city
-- score 10 and never 30, and an absent city on either side scores 0.
-- The guards below are written explicitly rather than relied upon
-- implicitly.
--
-- This helper is deliberately the ONLY place location scoring is
-- expressed, so that a future approved zone amendment (which would
-- require D-001 + D-002 changes first) modifies this boundary alone.
-- It is not a client-facing API.

CREATE OR REPLACE FUNCTION private.location_points(
  worker_barangay text,
  worker_city     text,
  job_barangay    text,
  job_city        text
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT CASE
    -- No usable city on either side: no location evidence at all.
    WHEN worker_city IS NULL OR job_city IS NULL
      THEN 0
    -- Different city: no location credit.
    WHEN worker_city <> job_city
      THEN 0
    -- Same city AND both barangays present and equal.
    WHEN worker_barangay IS NOT NULL
     AND job_barangay IS NOT NULL
     AND worker_barangay = job_barangay
      THEN 30
    -- Same city only (includes the case where either barangay is NULL).
    ELSE 10
  END;
$$;


COMMENT ON FUNCTION private.location_points(text, text, text, text) IS
  'N8-DB-01: address-based location score for D-002 Stage 2. '
  'Same barangay + same city = 30; same city only = 10; otherwise 0. '
  'NULL-safe: a NULL on either side never scores as a match. '
  'No GPS, no coordinates, no distance, no address parsing, no zone. '
  'Isolated so a future approved zone amendment changes only this '
  'boundary. Not client-callable.';


REVOKE ALL ON FUNCTION private.location_points(text, text, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION private.location_points(text, text, text, text) FROM authenticated;

REVOKE ALL ON FUNCTION private.location_points(text, text, text, text) FROM anon;


-- ---------- 2. PRIVATE MATCHING COMPUTATION ----------
--
-- SECURITY INVOKER is deliberate and required by the locked boundary:
-- this function carries NO authorization logic, so it must never run
-- with elevated rights of its own. It is reached only through the
-- SECURITY DEFINER wrapper below, which has already authorized the
-- caller; executing inside that wrapper it inherits the wrapper's
-- effective privileges and can therefore see the candidate set despite
-- the self-row-only SELECT policy on public.users.
--
-- The parameter is referenced as compute_job_matches.job_id throughout:
-- public.job_skills exposes a job_id column that would otherwise make a
-- bare job_id ambiguous inside a SQL function body.
--
-- Join chain note (verified against the baseline schema, not assumed):
--   public.worker_skills.worker_id -> public.worker_profiles.id
--   public.bookings.worker_id      -> public.users.id
--   public.ratings.rated_user      -> public.users.id
-- worker_skills is keyed by PROFILE id while bookings and ratings are
-- keyed by USER id, so the chain must pass through worker_profiles.

CREATE OR REPLACE FUNCTION private.compute_job_matches(job_id uuid)
RETURNS TABLE (
  rank                    integer,
  worker_id               uuid,
  skill_points            numeric,
  location_points         numeric,
  rating_points           numeric,
  total_points            numeric,
  is_new_worker           boolean,
  completed_booking_count integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH job AS (
    SELECT
      jp.barangay AS job_barangay,
      jp.city     AS job_city
    FROM public.job_postings AS jp
    WHERE jp.id = compute_job_matches.job_id
  ),
  required AS (
    -- Each required skill counted once. job_skills is PK
    -- (job_id, skill_id), so DISTINCT is defensive, not corrective.
    SELECT COUNT(DISTINCT js.skill_id) AS required_count
    FROM public.job_skills AS js
    WHERE js.job_id = compute_job_matches.job_id
  ),
  eligible AS (
    -- STAGE 1. Every condition here is a hard exclusion. An unverified,
    -- inactive, busy, offline, or zero-overlap worker is removed from
    -- the candidate set entirely -- never merely scored lower.
    SELECT
      u.id          AS worker_user_id,
      u.barangay    AS worker_barangay,
      u.city        AS worker_city,
      u.created_at  AS worker_created_at,
      wp.rating_avg AS worker_rating_avg,
      COUNT(DISTINCT js.skill_id) AS matched_count
    FROM public.users AS u
    JOIN public.worker_profiles AS wp
      ON wp.user_id = u.id
    JOIN public.worker_skills AS ws
      ON ws.worker_id = wp.id
    JOIN public.job_skills AS js
      ON js.skill_id = ws.skill_id
     AND js.job_id = compute_job_matches.job_id
    WHERE u.role = 'worker'
      AND u.is_active = true
      AND wp.availability_status = 'available'
      AND wp.is_verified = true
    GROUP BY u.id, u.barangay, u.city, u.created_at, wp.rating_avg
  ),
  scored AS (
    SELECT
      e.worker_user_id,
      e.worker_created_at,
      e.worker_rating_avg,
      -- SKILL /50. Extra worker skills cannot inflate matched_count,
      -- because the join is bounded by this job's required skills.
      -- Proficiency level is not read here at all.
      -- NULLIF guards division by zero for a job with no required
      -- skills; such a job also yields no eligible workers, since
      -- eligibility requires at least one overlap.
      (e.matched_count::numeric / NULLIF(r.required_count, 0)::numeric) * 50
        AS skill_pts,
      -- LOCATION /30.
      private.location_points(
        e.worker_barangay,
        e.worker_city,
        j.job_barangay,
        j.job_city
      )::numeric AS location_pts,
      -- RATING /20 -- newness is decided by the EXISTENCE of received
      -- rating rows, NOT by the value of rating_avg. rating_avg is
      -- nullable with DEFAULT 0, so 0 is the ordinary initial value of
      -- a brand-new profile and must never be read as evidence either
      -- way.
      EXISTS (
        SELECT 1
        FROM public.ratings AS rt
        WHERE rt.rated_user = e.worker_user_id
      ) AS has_ratings,
      (
        SELECT COUNT(*)
        FROM public.bookings AS b
        WHERE b.worker_id = e.worker_user_id
          AND b.status = 'completed'
      )::integer AS completed_count
    FROM eligible AS e
    CROSS JOIN job AS j
    CROSS JOIN required AS r
  ),
  finalized AS (
    SELECT
      s.worker_user_id,
      s.worker_created_at,
      s.skill_pts,
      s.location_pts,
      s.completed_count,
      CASE
        WHEN s.has_ratings
          THEN (COALESCE(s.worker_rating_avg::numeric, 3.0) / 5) * 20
        -- Unrated: the neutral 3.0 is COMPUTATION-ONLY and yields
        -- exactly 12/20. Nothing is written back to worker_profiles,
        -- no rating row is fabricated, and is_new_worker below is what
        -- N8-UI uses to render the "New - no ratings yet" label. The
        -- worker must never be presented as actually holding a 3-star
        -- rating.
        ELSE (3.0::numeric / 5) * 20
      END AS rating_pts,
      (NOT s.has_ratings) AS new_worker
    FROM scored AS s
  )
  -- Output columns are matched positionally: the RETURNS TABLE names
  -- are in scope as OUT parameters, so aliasing to them here would be
  -- ambiguous.
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY
        (f.skill_pts + f.location_pts + f.rating_pts) DESC,
        f.completed_count ASC,
        f.worker_created_at ASC,
        f.worker_user_id ASC
    )::integer,
    f.worker_user_id,
    f.skill_pts,
    f.location_pts,
    f.rating_pts,
    (f.skill_pts + f.location_pts + f.rating_pts),
    f.new_worker,
    f.completed_count
  FROM finalized AS f
  -- Tiebreak order, per D-002 as amended: weighted total DESC, then
  -- fewer completed bookings, then earlier registration.
  -- worker_user_id is the final implementation-order fallback only --
  -- it makes output deterministic when every locked ranking value ties.
  -- It is not a livelihood scoring factor and must not be presented as
  -- one.
  ORDER BY
    (f.skill_pts + f.location_pts + f.rating_pts) DESC,
    f.completed_count ASC,
    f.worker_created_at ASC,
    f.worker_user_id ASC;
$$;


COMMENT ON FUNCTION private.compute_job_matches(uuid) IS
  'N8-DB-01: D-002 (as amended 2026-08-31) two-stage matching. '
  'Stage 1 eligibility: role=worker, is_active, availability=available, '
  'is_verified, and at least one required-skill overlap. Stage 2: '
  'Skill 50 / Location 30 / Rating 20. Verification, badge_level, and '
  'proficiency contribute no points. SECURITY INVOKER and holds no '
  'authorization logic: callers are authorized by '
  'public.match_workers_for_job() before this function runs. Not '
  'client-callable -- EXECUTE is revoked from PUBLIC and granted to no '
  'client role.';


-- The locked boundary: no client-facing EXECUTE on the computation.
REVOKE ALL ON FUNCTION private.compute_job_matches(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION private.compute_job_matches(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION private.compute_job_matches(uuid) FROM anon;


-- ---------- 3. PUBLIC AUTHENTICATED WRAPPER ----------
--
-- SECURITY DEFINER with an empty search_path, following the Phase 0
-- Piece B / N7-SEC-01 convention. Every relation and function is
-- schema-qualified.
--
-- Authorization runs to completion BEFORE any matching data is
-- produced. All four denial conditions -- no session, non-client or
-- inactive caller, job owned by another client, and job that does not
-- exist -- raise the SAME error with the SAME SQLSTATE. A caller
-- therefore cannot distinguish another client's job from a nonexistent
-- one, so the wrapper does not leak job existence, while still failing
-- deterministically enough to verify as a matrix.
--
-- Deliberately NOT implemented here: any client-side worker selection.
-- D-003 remains authoritative -- the system ranks eligible workers and
-- notifies them, a worker chooses to accept, and the first valid
-- acceptance wins. This function only computes and returns the ranking;
-- N9 acceptance (including the re-check of is_active and is_verified at
-- acceptance time) is out of scope for N8-DB.

CREATE OR REPLACE FUNCTION public.match_workers_for_job(p_job_id uuid)
RETURNS TABLE (
  rank                    integer,
  worker_id               uuid,
  skill_points            numeric,
  location_points         numeric,
  rating_points           numeric,
  total_points            numeric,
  is_new_worker           boolean,
  completed_booking_count integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller   uuid := auth.uid();
  v_owns_job boolean;
BEGIN
  -- 1. There must be a session.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized for this job'
      USING ERRCODE = '42501';
  END IF;

  -- 2. The caller must be an active authoritative client. This rejects
  --    workers, administrators, and deactivated/suspended clients
  --    holding a still-valid session.
  IF NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized for this job'
      USING ERRCODE = '42501';
  END IF;

  -- 3. The job must exist AND belong to the caller. Both failures are
  --    collapsed into one indistinguishable outcome on purpose.
  SELECT EXISTS (
    SELECT 1
    FROM public.job_postings AS jp
    WHERE jp.id = p_job_id
      AND jp.client_id = v_caller
  )
  INTO v_owns_job;

  IF NOT v_owns_job THEN
    RAISE EXCEPTION 'not authorized for this job'
      USING ERRCODE = '42501';
  END IF;

  -- Minimum projection required for matching and explainability.
  -- Deliberately excluded: email, phone, residential address, full
  -- name, client information, verified_by, strike_count, badge_level,
  -- availability_status, rating_avg, proficiency, and every other
  -- users/worker_profiles field. Worker contact information must not
  -- be exposed before a confirmed booking (D-003).
  RETURN QUERY
  SELECT
    c.rank,
    c.worker_id,
    c.skill_points,
    c.location_points,
    c.rating_points,
    c.total_points,
    c.is_new_worker,
    c.completed_booking_count
  FROM private.compute_job_matches(p_job_id) AS c;
END;
$$;


COMMENT ON FUNCTION public.match_workers_for_job(uuid) IS
  'N8-DB-01: authenticated entry point for D-002 matching. Requires an '
  'active authoritative client who owns the requested job; every denial '
  '(no session, wrong role, inactive, another client job, nonexistent '
  'job) raises the same 42501 so job existence is not leaked. '
  'SECURITY DEFINER with an empty search_path. Returns only the minimum '
  'ranking/explainability projection -- no contact details, no verifier '
  'identity, no private account fields. Does not implement client '
  'selection of a worker: D-003 worker-choice booking is unchanged and '
  'N9 acceptance is out of scope.';


-- Schema public carries ALTER DEFAULT PRIVILEGES that grant EXECUTE on
-- every new function to anon, authenticated, and service_role. Those
-- are explicit role grants, so REVOKE ... FROM PUBLIC does NOT remove
-- them -- anon would otherwise retain EXECUTE on this RPC. Each role is
-- therefore revoked by name first and the intended surface is then
-- granted deliberately, rather than inherited.
--
-- The resulting EXECUTE surface is exactly:
--
--   postgres       EXECUTE   (owner)
--   authenticated  EXECUTE
--   PUBLIC         none
--   anon           none
--   service_role   none
--
-- anon is revoked because an unauthenticated caller has no auth.uid()
-- and no job of its own, so it can never satisfy the authorization
-- checks above.
--
-- service_role is revoked too, and that is a deliberate narrowing
-- rather than an oversight. The private helpers (private.is_admin(),
-- private.is_active_worker(), private.is_active_client()) do grant
-- service_role, but those are predicates consumed by RLS policies on
-- behalf of whichever role is acting. This function is different: it
-- is the CLIENT-FACING matching entry point, and its whole contract is
-- that the caller is an authenticated client who owns the job. A
-- service_role caller has no auth.uid() at all, so it could never pass
-- the ownership check anyway -- granting it EXECUTE would only widen
-- the reachable surface without enabling any legitimate call. Trusted
-- backend paths that ever need matching results should invoke
-- private.compute_job_matches() as a Tier 1 database path, not through
-- this wrapper.
--
-- Schema private carries no default privileges, which is why the two
-- private functions above need no equivalent role-by-role revoke.

REVOKE ALL ON FUNCTION public.match_workers_for_job(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.match_workers_for_job(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.match_workers_for_job(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.match_workers_for_job(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.match_workers_for_job(uuid) TO authenticated;
