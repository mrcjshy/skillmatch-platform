-- ============================================================
-- PHASE 0 — PIECE D: PROTECTED-COLUMN GUARD ON public.users
-- ============================================================
--
-- PROBLEM
-- -------
-- The existing RLS policies on public.users are:
--
--   allow_insert_own_profile  INSERT  WITH CHECK (auth.uid() = id)
--   allow_read_own_profile    SELECT  USING      (auth.uid() = id)
--   allow_update_own_profile  UPDATE  USING      (auth.uid() = id)
--                                     WITH CHECK (auth.uid() = id)
--
-- They constrain WHICH ROW a caller may touch, but never WHICH
-- COLUMN VALUES that row may carry. Because private.is_admin()
-- (Piece B) derives authority from public.users.role, any
-- registrant could self-assign role='administrator' -- or
-- re-activate a deactivated account via is_active -- and thereby
-- mint their own admin privileges.
--
-- SOLUTION
-- --------
-- A BEFORE INSERT OR UPDATE row trigger that guards the two
-- privilege-bearing columns: role and is_active.
--
-- The trigger COMPLEMENTS RLS; it does not replace it. All three
-- existing policies are left byte-for-byte unchanged.
--
-- SECURITY INVOKER is intentional and load-bearing: the guard
-- must observe the CALLER's effective role. A SECURITY DEFINER
-- guard would always see the owner (postgres) and would collapse
-- every caller into Tier 1, silently disabling the guard.
--
-- THREE-TIER AUTHORITY MODEL
-- --------------------------
--   Tier 1  postgres / service_role  -- trusted database execution
--           paths (migrations, seeds, server-side backend code
--           holding the secret key). Unrestricted.
--
--   Tier 2  private.is_admin()       -- an authenticated, ACTIVE
--           administrator. Unrestricted on the rows RLS already
--           permits (see scope note below).
--
--   Tier 3  everyone else            -- ordinary application users.
--           role and is_active become non-self-assignable.
--
-- SCOPE NOTE (deliberate, pre-existing)
-- -------------------------------------
-- allow_update_own_profile is SELF-ROW ONLY. A Tier 2 admin
-- therefore still cannot UPDATE another user's row: RLS filters
-- the row out before this trigger can ever fire. Cross-user
-- administrator management is a separate, pre-existing
-- authorization gap and is explicitly OUT OF SCOPE for Piece D.
-- This migration does not widen the UPDATE policy.
-- ============================================================


-- ---------- GUARD FUNCTION ----------

CREATE OR REPLACE FUNCTION public.guard_users_protected_columns()
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
  -- a short-circuited AND: `anon` is granted neither USAGE on
  -- schema private nor EXECUTE on private.is_admin() (Piece A), so
  -- an unauthenticated caller reaching that call would raise a
  -- confusing permission error instead of the intended RLS denial.
  -- Nested IF makes the skip explicit rather than relying on
  -- unspecified boolean evaluation order.
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

    -- Self-registration may never mint an administrator.
    IF NEW.role = 'administrator' THEN
      RAISE EXCEPTION
        'Self-registration as administrator is not permitted.'
        USING ERRCODE = '42501';
    END IF;

    -- Positive allow-list. The users_role_check CHECK constraint
    -- already bounds the domain; this keeps the guard correct on
    -- its own terms if that domain is ever widened.
    IF NEW.role IS NULL OR NEW.role NOT IN ('worker', 'client') THEN
      RAISE EXCEPTION
        'Registration role must be either worker or client.'
        USING ERRCODE = '42501';
    END IF;

    -- is_active is server-owned, never client-supplied. Forced
    -- rather than rejected so that a client sending is_active=false
    -- (or NULL) still registers successfully -- it is simply
    -- overridden.
    NEW.is_active := true;

    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN

    IF NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION
        'Changing your own role is not permitted.'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
      RAISE EXCEPTION
        'Changing your own active status is not permitted.'
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;

  END IF;

  RETURN NEW;
END;
$$;


COMMENT ON FUNCTION public.guard_users_protected_columns() IS
  'Piece D: BEFORE INSERT/UPDATE guard protecting public.users.role and '
  'public.users.is_active from self-assignment. SECURITY INVOKER by design '
  'so that current_user reflects the caller. Complements, and does not '
  'replace, the existing self-row RLS policies.';


-- Trigger functions are not permission-checked at fire time, but an
-- explicit grant keeps the privilege surface legible and matches the
-- Piece A/B/C convention.
REVOKE ALL ON FUNCTION public.guard_users_protected_columns() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.guard_users_protected_columns()
TO authenticated, service_role;


-- ---------- TRIGGER ----------

DROP TRIGGER IF EXISTS trg_guard_users_protected_columns ON public.users;

CREATE TRIGGER trg_guard_users_protected_columns
  BEFORE INSERT OR UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_users_protected_columns();
