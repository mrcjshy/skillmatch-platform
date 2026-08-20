-- ============================================================
-- PHASE 0 (v3) — BACKEND SECURITY FOUNDATION
-- Piece A: private helper schema
-- Piece B: private.is_admin()
-- Piece C: private.is_active_worker()
-- ============================================================


-- ---------- A. PRIVATE SCHEMA ----------
-- Internal helper schema.
-- Keep this schema OUT of Supabase's configured exposed schemas.
-- This is not an application table and does not change the
-- locked 11-table ERD.

CREATE SCHEMA IF NOT EXISTS private;

REVOKE ALL ON SCHEMA private FROM PUBLIC;

GRANT USAGE ON SCHEMA private TO authenticated, service_role;


-- ---------- B. IS_ADMIN HELPER ----------
-- Returns true only when the authenticated caller is both:
--   1. an administrator
--   2. currently active
--
-- SECURITY DEFINER is intentional:
-- this helper must reliably inspect public.users regardless of
-- the caller's normal RLS visibility.
--
-- search_path is empty and relations are schema-qualified to
-- harden the SECURITY DEFINER function.

CREATE OR REPLACE FUNCTION private.is_admin()
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
      AND u.role = 'administrator'
      AND u.is_active = true
  );
$$;

REVOKE EXECUTE ON FUNCTION private.is_admin() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION private.is_admin()
TO authenticated, service_role;


-- ---------- C. IS_ACTIVE_WORKER HELPER ----------
-- Returns true only when the authenticated caller is both:
--   1. a worker
--   2. currently active
--
-- Used later by restrictive Worker Module write policies.

CREATE OR REPLACE FUNCTION private.is_active_worker()
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
      AND u.role = 'worker'
      AND u.is_active = true
  );
$$;

REVOKE EXECUTE ON FUNCTION private.is_active_worker() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION private.is_active_worker()
TO authenticated, service_role;