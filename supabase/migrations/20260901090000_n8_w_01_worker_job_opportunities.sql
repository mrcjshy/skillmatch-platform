-- ============================================================
-- N8-W-01: WORKER JOB OPPORTUNITY READ API
-- ============================================================
--
-- SCOPE
-- -----
-- The Worker-facing counterpart of N8-DB. N8-DB gave the owning
-- Client a ranked candidate list (public.match_workers_for_job);
-- this piece gives an authenticated Worker the jobs they have
-- themselves matched into. It closes the read half of the D-003
-- flow:
--
--   Client posts a job
--   -> the system ranks eligible Workers      (N8-DB, unchanged)
--   -> the matched Worker reads the opportunity  (THIS PIECE)
--   -> the Worker chooses whether to accept      (N9, out of scope)
--   -> the first valid acceptance wins           (N9, out of scope)
--
-- The Client still never selects a Worker, and this function
-- introduces no acceptance, booking, or notification behavior.
--
-- This migration adds ONE FUNCTION AND ITS ACL. No table, column,
-- constraint, policy, trigger, or index, and no existing object is
-- altered. In particular private.compute_job_matches(uuid),
-- private.location_points(...), public.match_workers_for_job(uuid),
-- private.is_active_worker() and private.is_active_client() are all
-- left exactly as they are, including their ACLs.
--
-- NO SECOND ALGORITHM
-- -------------------
-- Every eligibility decision and every score in this function comes
-- from private.compute_job_matches(job_id). Nothing here recomputes
-- required-skill overlap, verification, availability, location
-- points, rating points, new-worker state, completed-booking count,
-- or the total. D-002's 50/30/20 model has exactly one
-- implementation in this database and this function is a consumer of
-- it, not a copy.
--
-- WHY THERE IS NO is_verified / availability_status TEST BELOW
-- -----------------------------------------------------------
-- Deliberate, and load-bearing. Those two conditions are Stage 1
-- eligibility, which lives inside the authoritative scorer. A Worker
-- who is unverified, busy, or offline simply never appears in any
-- job's computed matches, so this function returns ZERO ROWS for
-- them without testing either column. Re-testing them here would
-- duplicate Stage 1 and create a second place where eligibility
-- could drift from D-002.
--
-- That yields a deliberate two-level split:
--
--   caller gate      -> may this account use the API at all?
--                       (role = worker AND is_active)
--   scorer eligibility -> does this Worker match anything right now?
--                       (verified AND available AND skill overlap)
--
-- So a suspended Worker gets 42501, while a merely busy or
-- not-yet-verified Worker gets an empty list. An empty list is a
-- normal state, not an error.
-- ============================================================


CREATE OR REPLACE FUNCTION public.list_my_job_opportunities()
RETURNS TABLE (
  job_id          uuid,
  title           character varying,
  description     text,
  barangay        character varying,
  city            character varying,
  budget          numeric,
  scheduled_at    timestamp with time zone,
  skill_points    numeric,
  location_points numeric,
  rating_points   numeric,
  total_points    numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  ----------------------------------------------------------------
  -- CALLER GATE
  --
  -- Account-level authorization only: there must be a session, and
  -- it must belong to an active authoritative Worker. This rejects
  -- anon, Clients, Administrators, and deactivated or suspended
  -- Workers holding a still-valid session.
  --
  -- The message and SQLSTATE are identical for every denial, and
  -- neither depends on whether a worker_profiles row exists, so a
  -- rejected caller learns nothing about any Worker profile.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized for worker opportunities'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- OPPORTUNITIES
  --
  -- Only 'open' jobs are considered. 'matched', 'completed' and
  -- 'cancelled' jobs are not opportunities and are excluded here --
  -- this is the one filter N8-W owns, and it is a job-lifecycle
  -- filter, not a Worker-eligibility one.
  --
  -- The LATERAL runs the authoritative scorer per open job and keeps
  -- only the caller's own row. Because compute_job_matches emits a
  -- row only for a Worker who passed Stage 1, membership in this
  -- result IS the eligibility answer -- there is nothing further to
  -- check.
  --
  -- compute_job_matches is SECURITY INVOKER and carries no
  -- authorization logic of its own; it is reachable here only
  -- because this wrapper is SECURITY DEFINER and has already
  -- authorized the caller. Executing inside this wrapper it inherits
  -- the definer's privileges, which is what lets it see the
  -- candidate set despite the self-row-only SELECT policy on
  -- public.users.
  --
  -- PROJECTION. Job facts plus the caller's OWN score components,
  -- and nothing else. There is deliberately NO join to the Client's
  -- public.users row anywhere in this function, which makes the
  -- D-003 privacy boundary structural rather than a matter of
  -- careful column selection: client_id, Client name, email, phone
  -- and address are not merely omitted, they are unreachable from
  -- this query. Client contact details are released only after a
  -- confirmed booking.
  --
  -- Also absent by design: worker_id (the rows belong to auth.uid()
  -- implicitly), rank, competitor rows, competitor identities,
  -- competitor scores, the number of competing Workers, and
  -- completed_booking_count. The Worker sees their own standing, not
  -- the field they are standing in -- this is an opportunity list,
  -- not a competitor-inspection surface.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT
    jp.id,
    jp.title,
    jp.description,
    jp.barangay,
    jp.city,
    jp.budget,
    jp.scheduled_at,
    m.skill_points,
    m.location_points,
    m.rating_points,
    m.total_points
  FROM public.job_postings AS jp
  CROSS JOIN LATERAL private.compute_job_matches(jp.id) AS m
  WHERE jp.status = 'open'
    AND m.worker_id = v_caller
  ----------------------------------------------------------------
  -- PRESENTATION ORDERING ONLY.
  --
  -- This orders one Worker's own opportunities for display. It is
  -- NOT a D-002 scoring factor, it does not touch the scorer, and it
  -- does not replace the within-job ranking of Workers against each
  -- other (which remains total DESC, fewer completed bookings,
  -- earlier registration, inside compute_job_matches). scheduled_at
  -- and job_id are tiebreakers for presentation and must never be
  -- described as matching criteria. Nothing here is persisted.
  --
  -- NULLS LAST is explicit: scheduled_at is nullable, and an
  -- unscheduled job should sort after scheduled ones rather than
  -- ahead of them under the default DESC/ASC null placement.
  ----------------------------------------------------------------
  ORDER BY
    m.total_points DESC,
    jp.scheduled_at ASC NULLS LAST,
    jp.id ASC;
END;
$$;


COMMENT ON FUNCTION public.list_my_job_opportunities() IS
  'N8-W-01: authenticated Worker read API for matched job '
  'opportunities. Takes no parameter -- the caller is always '
  'auth.uid(), so there is no Worker id that could be substituted to '
  'inspect someone else. Requires an active authoritative Worker '
  '(42501 otherwise); an active but unverified, busy, or offline '
  'Worker receives zero rows rather than an error, because Stage 1 '
  'eligibility lives in private.compute_job_matches(), which this '
  'function reuses as the single source of truth for D-002 '
  'eligibility and 50/30/20 scoring. Returns open jobs only, with '
  'the caller''s own score components -- no Client identity or '
  'contact data, no competitor rows, no rank. Implements no '
  'acceptance or booking behavior (D-003 / N9).';


-- Schema public carries ALTER DEFAULT PRIVILEGES granting EXECUTE on
-- every new function to anon, authenticated, and service_role by
-- name. Those are explicit grantees, so REVOKE ... FROM PUBLIC does
-- not remove them -- the same behavior recorded as GAP-004 in
-- docs/SECURITY.md and handled the same way in N8-DB-01. Each role is
-- therefore revoked explicitly before the intended grant is made.
--
-- service_role stays revoked: this API is defined entirely in terms
-- of auth.uid(), which a service_role caller does not have, so it
-- could never return anything meaningful. Trusted backend paths
-- should use private.compute_job_matches() as a Tier 1 database path
-- instead.

REVOKE ALL ON FUNCTION public.list_my_job_opportunities() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_my_job_opportunities() FROM anon;

REVOKE ALL ON FUNCTION public.list_my_job_opportunities() FROM authenticated;

REVOKE ALL ON FUNCTION public.list_my_job_opportunities() FROM service_role;

GRANT EXECUTE ON FUNCTION public.list_my_job_opportunities() TO authenticated;
