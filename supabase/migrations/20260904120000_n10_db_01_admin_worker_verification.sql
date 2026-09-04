-- ============================================================
-- N10-DB-01: ADMINISTRATOR WORKER VERIFICATION
-- ============================================================
--
-- SCOPE
-- -----
-- Adds the two read/write halves of the Administrator verification
-- surface:
--
--   public.list_unverified_workers()          -- the pending queue
--   public.verify_worker(p_worker_user_id)    -- the verifying act
--
-- This migration adds TWO FUNCTIONS and nothing else. It creates no
-- table, no column, no index, no trigger and no policy, so the locked
-- 11-table ERD (D-001) is untouched. It does NOT alter the Phase 0
-- guard triggers, the matching engine, or any existing function:
-- private.compute_job_matches(), private.location_points(),
-- public.list_my_job_opportunities(), public.match_workers_for_job()
-- and public.accept_job_opportunity() are all left exactly as they
-- are, including their ACLs.
--
-- WHY BOTH HALVES MUST BE RPCs
-- ----------------------------
-- Neither operation is reachable through ordinary PostgREST table
-- access, and that is by design rather than by oversight:
--
--   public.users        SELECT  allow_read_own_profile
--                               USING (auth.uid() = id)
--
-- is SELF-ROW ONLY, so an Administrator cannot read any other
-- account's name, contact or role. worker_profiles is readable
-- authenticated-wide, but a verification queue without the person's
-- identity is useless, and that identity lives in public.users.
-- Hence a SECURITY DEFINER read.
--
--   public.worker_profiles  UPDATE  "Workers can update their own
--                                   profile" USING (user_id = auth.uid())
--
-- is likewise SELF-ROW ONLY. This is docs/SECURITY.md GAP-003: "a
-- Tier 2 admin still cannot UPDATE another worker's row via
-- PostgREST; RLS filters the row out before this trigger fires.
-- Cross-user admin management is a separate, security-reviewed task."
-- This migration IS that task, and it closes the gap the way the gap
-- itself prescribes -- with a narrow reviewed RPC, NOT by widening
-- the self-row UPDATE policy. The policy is left byte-for-byte
-- unchanged, so no Worker gains any new reach over any other row.
--
-- RELATIONSHIP TO THE PHASE 0 PIECE E GUARD -- NOT MODIFIED
-- ---------------------------------------------------------
-- trg_guard_worker_profiles_protected_columns protects exactly the
-- five columns is_verified, verified_by, rating_avg, strike_count and
-- badge_level. verify_worker() writes two of them, so the interaction
-- is load-bearing and was established BEFORE this migration was
-- written:
--
--   Tier 1  current_user IN ('postgres','service_role') -> RETURN NEW
--
-- A postgres-owned SECURITY DEFINER function runs with current_user =
-- postgres, so it satisfies Tier 1 and the guard admits the write.
-- Piece E anticipates this explicitly in its STANDING RPC CAVEAT:
-- "Any postgres-owned SECURITY DEFINER function that writes
-- public.worker_profiles runs this guard with current_user = postgres
-- (Tier 1) and therefore bypasses it. Future paths ... must be
-- trusted Tier 1 paths or restricted, reviewed RPCs."
--
-- This function is that restricted, reviewed RPC. The guard is not
-- weakened, disabled, dropped or edited in any way, and it continues
-- to reject every Tier 3 self-verification attempt with 42501. The
-- Tier 2 (private.is_admin()) branch of the guard is also untouched
-- and is deliberately NOT relied upon here -- authorization is
-- re-established inside the RPC itself rather than inherited from a
-- trigger whose job is column protection, not caller authorization.
--
-- WHAT IS DELIBERATELY NOT DONE
-- -----------------------------
--   * No un-verify / revoke path. Removing verification has different
--     consequences (it silently removes a Worker from matching and
--     could strand an accepted Booking) and needs its own decision.
--   * rating_avg, strike_count, badge_level and availability_status
--     are never written here. Verification is not a rating, a badge,
--     or an availability change.
--   * No notification is created. Notifications remain a separate
--     module, exactly as in N9.
--   * No Administrator provisioning. D-006 keeps that on trusted
--     backend/database paths only.
-- ============================================================


-- ---------- 1. PENDING VERIFICATION QUEUE ----------
--
-- plpgsql rather than sql because the caller gate must RAISE. Zero
-- rows means "nothing pending", never "not allowed": the two answers
-- are kept distinguishable, matching the N8-W convention where an
-- authorization failure is an error and an empty result is a success.
--
-- STABLE (reads only). SECURITY DEFINER is required to read
-- public.users at all, per the self-row SELECT policy above.

CREATE OR REPLACE FUNCTION public.list_unverified_workers()
RETURNS TABLE (
  user_id             uuid,
  full_name           text,
  phone               text,
  barangay            text,
  city                text,
  availability_status text,
  skills              text[],
  registered_at       timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  ----------------------------------------------------------------
  -- CALLER AUTHORIZATION
  --
  -- private.is_admin() is the single source of administrator
  -- authority (role = 'administrator' AND is_active). Every denial
  -- -- signed out, Worker, Client, or a deactivated Administrator --
  -- raises the SAME error, so a rejected caller learns nothing about
  -- which predicate failed or about any Worker.
  --
  -- The explicit auth.uid() IS NULL test comes first for the same
  -- reason Piece E orders it that way: `anon` holds neither USAGE on
  -- schema private nor EXECUTE on private.is_admin(), so reaching
  -- that call unauthenticated would raise a confusing permission
  -- error instead of the intended denial.
  ----------------------------------------------------------------
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to list unverified workers'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- THE QUEUE
  --
  -- is_verified is nullable (verified: is_nullable = YES, attnotnull =
  -- f) with DEFAULT false, so "unverified" is written as
  -- IS DISTINCT FROM true rather than = false. This is a decided
  -- contract point, not an accident:
  --
  --   * The Piece E guard forces is_verified := false on every Tier 3
  --     INSERT, so ordinary registration can never produce NULL, and
  --     no NULL exists in the deployed data today.
  --   * A Tier 1 / Tier 2 path CAN still persist an explicit NULL,
  --     because the guard returns NEW untouched for those callers.
  --   * Under `= false` such a row would be silently invisible in this
  --     queue -- an unverified Worker no Administrator could ever find
  --     -- while verify_worker() below (which rejects only
  --     is_verified IS TRUE) would still happily verify it. The two
  --     halves of the feature would disagree about who is pending.
  --
  -- IS DISTINCT FROM true keeps both halves on ONE definition of
  -- pending. No NOT NULL constraint and no default change is made
  -- here; tightening the column is a separate schema decision.
  --
  -- The role = 'worker' filter is load-bearing, not cosmetic:
  -- GAP-002 records that the worker_profiles INSERT policy is
  -- role-agnostic, so a Client or Administrator can create a
  -- worker_profiles row for themselves. Such a row must never be
  -- presented to an Administrator as a Worker awaiting verification.
  --
  -- Inactive accounts are listed rather than hidden. Hiding them would
  -- silently strand a suspended Worker's application, the same failure
  -- mode the NULL handling above avoids. is_active is deliberately NOT
  -- projected: this surface answers "who is waiting to be verified",
  -- and account status belongs to account administration.
  --
  -- skills is a deterministic text[] -- ordered by name, with id as the
  -- tie-break so two identically named skills cannot reorder between
  -- calls. A Worker with no skills yet is a real pending application
  -- and is listed with an EMPTY ARRAY rather than dropped: the LEFT
  -- correlated aggregate returns NULL for them, which COALESCE turns
  -- into '{}'. Using a plain JOIN here would have silently hidden
  -- them.
  --
  -- Oldest application first: this is a queue, and the ordering is
  -- part of the contract so the client never has to re-sort.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT
    u.id,
    u.full_name,
    u.phone,
    u.barangay,
    u.city,
    wp.availability_status::text,
    COALESCE(
      (
        SELECT array_agg(sk.skill_name::text ORDER BY sk.skill_name, sk.id)
        FROM public.worker_skills AS ws
        JOIN public.skills AS sk
          ON sk.id = ws.skill_id
        WHERE ws.worker_id = wp.id
      ),
      '{}'::text[]
    ),
    wp.created_at
  FROM public.worker_profiles AS wp
  JOIN public.users AS u
    ON u.id = wp.user_id
  WHERE u.role = 'worker'
    AND wp.is_verified IS DISTINCT FROM true
  ORDER BY wp.created_at ASC, wp.id ASC;
END;
$$;


COMMENT ON FUNCTION public.list_unverified_workers() IS
  'N10-DB-01: Administrator queue of Workers awaiting verification. '
  'Requires an active administrator (private.is_admin()); every other '
  'caller receives 42501 "not authorized to list unverified workers". '
  'SECURITY DEFINER because public.users SELECT is self-row only, so '
  'the identity behind a pending profile is otherwise unreadable. '
  'Lists role = worker profiles whose is_verified IS DISTINCT FROM '
  'true (the column is nullable, so NULL counts as unverified and '
  'matches the verify_worker guard), oldest application first. '
  'Returns exactly user_id, full_name, phone, barangay, city, '
  'availability_status, skills and registered_at; skills is a '
  'deterministic text[] that is empty rather than absent for a Worker '
  'with no skills. Inactive accounts are listed but is_active is not '
  'projected. Zero rows means nothing is pending, never a denial.';


-- Role-by-role revocation is required: schema public grants EXECUTE on
-- every new function to anon, authenticated and service_role by name,
-- so REVOKE ... FROM PUBLIC alone would leave them in place
-- (docs/SECURITY.md GAP-004). service_role stays revoked because it
-- has no auth.uid() and could never pass the caller gate.

REVOKE ALL ON FUNCTION public.list_unverified_workers() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_unverified_workers() FROM anon;

REVOKE ALL ON FUNCTION public.list_unverified_workers() FROM authenticated;

REVOKE ALL ON FUNCTION public.list_unverified_workers() FROM service_role;

GRANT EXECUTE ON FUNCTION public.list_unverified_workers() TO authenticated;


-- ---------- 2. THE VERIFYING ACT ----------
--
-- VOLATILE (writes). SECURITY DEFINER for two independent reasons:
-- the self-row UPDATE policy would filter the target row out
-- (GAP-003), and the Piece E guard admits the protected-column write
-- only on a Tier 1 path.
--
-- The parameter is the WORKER'S ACCOUNT ID (public.users.id), never
-- the worker_profiles.id. N8-OBS-02 recorded that this project uses
-- worker_id for both meanings in different tables, so the parameter
-- is named p_worker_user_id and the projection column worker_user_id
-- to leave no room for the ambiguity. worker_profiles.user_id carries
-- a UNIQUE constraint, so exactly one profile can match.
--
-- There is no p_verified_by parameter: the verifier is always
-- auth.uid(), so no caller can attribute a verification to another
-- Administrator. That is the same defence F-002/Piece E added against
-- forged "verified by <admin>" attribution, preserved here.

CREATE OR REPLACE FUNCTION public.verify_worker(p_worker_user_id uuid)
RETURNS TABLE (
  user_id     uuid,
  is_verified boolean,
  verified_by uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_profile_id  uuid;
  v_is_verified boolean;
  v_role        text;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION -- BEFORE the target is touched or even
  --    probed, so an unauthorized caller cannot use timing or error
  --    shape to discover whether an account exists.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to verify workers'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. LOCK THE TARGET PROFILE -- BEFORE evaluating its state
  --
  -- Same ordering as N9's acceptance claim, for the same reason:
  -- under READ COMMITTED a blocked SELECT ... FOR UPDATE re-reads the
  -- newest committed version once the lock is granted, so if two
  -- Administrators verify the same Worker concurrently the loser sees
  -- is_verified = true and stops. Exactly one verified_by attribution
  -- can therefore win, instead of the last writer silently
  -- overwriting the first.
  --
  -- FOR UPDATE OF wp is deliberate: only the profile row is the
  -- contended resource. Locking the joined public.users row as well
  -- would needlessly block unrelated account activity.
  ----------------------------------------------------------------
  SELECT wp.id, wp.is_verified, u.role
    INTO v_profile_id, v_is_verified, v_role
  FROM public.worker_profiles AS wp
  JOIN public.users AS u
    ON u.id = wp.user_id
  WHERE wp.user_id = p_worker_user_id
  FOR UPDATE OF wp;

  ----------------------------------------------------------------
  -- 3. THE TARGET MUST BE A WORKER AWAITING VERIFICATION
  --
  -- Four situations produce ONE indistinguishable error, on purpose:
  --
  --   a. no such account / no worker_profiles row  (NOT FOUND)
  --   b. the account exists but is not a Worker    (GAP-002 rows)
  --   c. the Worker is already verified
  --   d. a concurrent Administrator just verified it (step 2's
  --      re-read makes this collapse into c)
  --
  -- Giving (a) and (c) different answers would turn this RPC into an
  -- account-existence oracle for anyone who reaches admin, and would
  -- leak which arbitrary uuids correspond to real accounts. Callers
  -- that need to know what is pending call list_unverified_workers().
  --
  -- Already-verified is therefore NOT treated as success. Verifying
  -- is not idempotent here precisely because a silent second success
  -- would overwrite the original verified_by attribution.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_role IS DISTINCT FROM 'worker'
     OR v_is_verified IS TRUE
  THEN
    RAISE EXCEPTION 'this worker is not available for verification'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. THE WRITE
  --
  -- Exactly two columns. rating_avg, strike_count, badge_level,
  -- availability_status and bio are never touched: verification is
  -- not a rating, a badge, a suspension change or an availability
  -- change, and the Piece E guard exists to keep those independent.
  --
  -- verified_by comes from auth.uid() -- a trusted source -- and
  -- never from caller input.
  ----------------------------------------------------------------
  UPDATE public.worker_profiles AS wp
  SET is_verified = true,
      verified_by = v_caller
  WHERE wp.id = v_profile_id;

  ----------------------------------------------------------------
  -- 5. RETURN THE MINIMUM PROJECTION
  --
  -- Read back from the persisted row rather than echoing the
  -- constants written above, so the caller receives observed state.
  -- Exactly three fields: the account acted on and the two columns
  -- that moved. No contact detail, no profile id and no unrelated
  -- profile column -- the caller already had to be an Administrator
  -- to get here, and this is a confirmation, not a second read
  -- surface.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT wp.user_id, wp.is_verified, wp.verified_by
  FROM public.worker_profiles AS wp
  WHERE wp.id = v_profile_id;
END;
$$;


COMMENT ON FUNCTION public.verify_worker(uuid) IS
  'N10-DB-01: Administrator verification of one Worker. Takes the '
  'WORKER ACCOUNT id (public.users.id), never worker_profiles.id. '
  'Requires an active administrator (private.is_admin()); every other '
  'caller receives 42501 "not authorized to verify workers". Locks '
  'the profile row FOR UPDATE before '
  'checking state, so concurrent verifications resolve first-wins and '
  'only one verified_by attribution can be recorded. A nonexistent '
  'account, a non-Worker account and an already-verified Worker all '
  'return the SAME SM409, so the function is not an account-existence '
  'oracle. Sets is_verified = true and verified_by = auth.uid() and '
  'nothing else -- rating_avg, strike_count, badge_level and '
  'availability_status are never written. Returns exactly user_id, '
  'is_verified and verified_by. Creates no notification. '
  'Runs as a Tier 1 path through the Piece E protected-column guard, '
  'which this migration does not modify.';


REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.verify_worker(uuid) TO authenticated;
