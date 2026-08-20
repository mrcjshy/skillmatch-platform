-- ============================================================
-- PHASE 0 — PIECE E: PROTECTED-COLUMN GUARD ON public.worker_profiles
-- ============================================================
--
-- PROBLEM
-- -------
-- The existing RLS policies on public.worker_profiles are:
--
--   "Workers can insert their own profile"          INSERT  WITH CHECK (user_id = auth.uid())
--   "Anyone authenticated can read worker profiles" SELECT  USING      (true)
--   "Workers can update their own profile"          UPDATE  USING      (user_id = auth.uid())
--
-- They constrain WHICH ROW a caller may touch, never WHICH COLUMN
-- VALUES that row may carry. Verified locally (rolled back): an
-- authenticated worker can INSERT or UPDATE its own row with
-- is_verified = true, verified_by = <any admin id>, rating_avg = 5,
-- strike_count = 0 (resetting a 3-strike suspension) and
-- badge_level = 'large'. No authority derives from worker_profiles,
-- but these five columns feed the locked matching model (D-002:
-- verification and rating weights), the 3-strike rule and the badge
-- system, and allow forged "verified by <admin>" attribution (F-002).
--
-- SOLUTION
-- --------
-- A BEFORE INSERT OR UPDATE row trigger guarding the five
-- integrity-bearing columns:
--
--   is_verified, verified_by, rating_avg, strike_count, badge_level
--
-- The trigger COMPLEMENTS RLS; it does not replace it. All three
-- existing policies are left byte-for-byte unchanged. No column,
-- default, nullability or CHECK constraint is altered (D-001).
--
-- SECURITY INVOKER is intentional and load-bearing (D-005): the
-- guard must observe the CALLER's effective role. A SECURITY
-- DEFINER guard would always see the owner (postgres) and would
-- collapse every caller into Tier 1, silently disabling the guard.
--
-- THREE-TIER AUTHORITY MODEL (same shape as Piece D)
-- --------------------------------------------------
--   Tier 1  postgres / service_role  -- trusted database execution
--           paths (migrations, seeds, server-side backend code
--           holding the secret key). Unrestricted.
--
--   Tier 2  private.is_admin()       -- an authenticated, ACTIVE
--           administrator. Unrestricted on the rows RLS already
--           permits (see scope note below).
--
--   Tier 3  everyone else            -- ordinary application users.
--           INSERT: the five columns are forced to the trusted
--                   initial state (server-owned, never client-
--                   supplied; a supplied value is overwritten, not
--                   rejected).
--           UPDATE: any real change (IS DISTINCT FROM) to any of
--                   the five columns is rejected with SQLSTATE 42501.
--
-- TRUSTED INITIAL STATE (Tier 3 INSERT)
-- -------------------------------------
--   is_verified  = false   (matches column default)
--   verified_by  = NULL    (column has no default)
--   rating_avg   = 0       (matches column default)
--   strike_count = 0       (matches column default)
--   badge_level  = 'none'  (column has NO default and is nullable;
--                           'none' is the CHECK-constraint literal
--                           for "no badge". This is trigger-enforced
--                           initial state only -- the column default
--                           is deliberately NOT added and existing
--                           NULL rows are NOT backfilled.)
--
-- SCOPE NOTES (deliberate, pre-existing, NOT fixed here)
-- ------------------------------------------------------
-- GAP-002  The INSERT policy is role/status agnostic (it checks only
--          user_id = auth.uid()): an authenticated non-worker role
--          (confirmed for both client and administrator) can create
--          its own worker_profiles row, and an inactive/suspended
--          worker can also create one. Row authorization -> RLS task.
-- GAP-003  The UPDATE policy is self-row only: a Tier 2 admin still
--          cannot UPDATE another worker's row via PostgREST; RLS
--          filters the row out before this trigger fires. Analogue
--          of GAP-001. Cross-user admin management is a separate,
--          security-reviewed task.
-- This trigger must not be read as fixing either gap. It is a
-- column-value guard, not a row-authorization mechanism.
--
-- STANDING RPC CAVEAT
-- -------------------
-- Any postgres-owned SECURITY DEFINER function that writes
-- public.worker_profiles runs this guard with current_user =
-- postgres (Tier 1) and therefore bypasses it. Future paths that
-- compute rating_avg / strike_count / badge_level must be trusted
-- Tier 1 paths or restricted, reviewed RPCs.
-- ============================================================


-- ---------- GUARD FUNCTION ----------

CREATE OR REPLACE FUNCTION public.guard_worker_profiles_protected_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_is_admin boolean := false;
BEGIN
  ----------------------------------------------------------------
  -- TIER 1 — trusted database execution paths
  --
  -- current_user (not session_user) is correct here: PostgREST
  -- authenticates as `authenticator` and then SET ROLE's to the
  -- role named in the JWT, so current_user is the effective role.
  ----------------------------------------------------------------
  IF current_user IN ('postgres', 'service_role') THEN
    RETURN NEW;
  END IF;

  ----------------------------------------------------------------
  -- TIER 2 — active administrator
  --
  -- Guarded by an explicit auth.uid() IS NOT NULL test rather than
  -- a short-circuited AND: `anon` has neither USAGE on schema
  -- private nor EXECUTE on private.is_admin() (Piece A/B), so an
  -- unauthenticated caller reaching that call would raise a
  -- confusing permission error instead of the intended RLS denial.
  ----------------------------------------------------------------
  IF auth.uid() IS NOT NULL THEN
    v_is_admin := private.is_admin();
  END IF;

  IF v_is_admin THEN
    RETURN NEW;
  END IF;

  ----------------------------------------------------------------
  -- TIER 3 — ordinary application users
  ----------------------------------------------------------------
  IF TG_OP = 'INSERT' THEN

    -- Server-owned columns: force the trusted initial state.
    -- Overwritten rather than rejected so that a client echoing a
    -- full row object still registers successfully.
    NEW.is_verified  := false;
    NEW.verified_by  := NULL;
    NEW.rating_avg   := 0;
    NEW.strike_count := 0;
    NEW.badge_level  := 'none';

    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN

    IF NEW.is_verified IS DISTINCT FROM OLD.is_verified THEN
      RAISE EXCEPTION
        'Changing your own verification status is not permitted.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.verified_by IS DISTINCT FROM OLD.verified_by THEN
      RAISE EXCEPTION
        'Changing your own verifier is not permitted.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.rating_avg IS DISTINCT FROM OLD.rating_avg THEN
      RAISE EXCEPTION
        'Changing your own rating average is not permitted.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.strike_count IS DISTINCT FROM OLD.strike_count THEN
      RAISE EXCEPTION
        'Changing your own strike count is not permitted.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.badge_level IS DISTINCT FROM OLD.badge_level THEN
      RAISE EXCEPTION
        'Changing your own badge level is not permitted.'
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;

  END IF;

  RETURN NEW;
END;
$$;


COMMENT ON FUNCTION public.guard_worker_profiles_protected_columns() IS
  'Piece E: BEFORE INSERT/UPDATE guard protecting public.worker_profiles '
  'is_verified, verified_by, rating_avg, strike_count and badge_level from '
  'self-assignment. Tier 3 INSERT forces false/NULL/0/0/''none''; Tier 3 '
  'UPDATE rejects any change (42501). SECURITY INVOKER by design so that '
  'current_user reflects the caller. Complements, and does not replace, the '
  'existing self-row RLS policies.';


-- ---------- EXECUTE PRIVILEGES ----------
--
-- A trigger function needs no client-callable EXECUTE surface: the
-- EXECUTE privilege is checked only when the trigger is CREATED (by
-- postgres, the owner), never when it fires. Functions created in
-- schema public receive EXECUTE for PUBLIC (PostgreSQL default) and
-- explicit grants to anon / authenticated / service_role via this
-- project's ALTER DEFAULT PRIVILEGES. Revoke all of them explicitly
-- (a PUBLIC revoke alone does not remove the explicit grantees --
-- see the deferred Piece D anon-EXECUTE finding in docs/SECURITY.md).
-- The owner (postgres) keeps its implicit privileges.

REVOKE ALL ON FUNCTION public.guard_worker_profiles_protected_columns()
FROM PUBLIC, anon, authenticated, service_role;


-- ---------- TRIGGER ----------

DROP TRIGGER IF EXISTS trg_guard_worker_profiles_protected_columns
  ON public.worker_profiles;

CREATE TRIGGER trg_guard_worker_profiles_protected_columns
  BEFORE INSERT OR UPDATE ON public.worker_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_worker_profiles_protected_columns();
