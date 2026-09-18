-- ============================================================
-- V3-BE-5: NARROW worker_profiles.availability_status TO TWO STATES
-- ============================================================
--
-- SCOPE
-- -----
-- Replace worker_profiles_availability_status_check so the stored
-- value may be only:
--
--   available | busy
--
-- Hosted census (2026-09-18, then V3-4E disposable profile):
--   offline = 0. No row rewrite is required or performed.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No UPDATE of any worker_profiles row.
--   * No change to DEFAULT 'available'.
--   * No change to matching functions.
--   * No change to verify_worker / is_verified.
--   * No change to Piece E protected-column guard.
-- ============================================================


ALTER TABLE public.worker_profiles
  DROP CONSTRAINT worker_profiles_availability_status_check;

ALTER TABLE public.worker_profiles
  ADD CONSTRAINT worker_profiles_availability_status_check
  CHECK ((availability_status)::text = ANY (
    (ARRAY[
      'available'::character varying,
      'busy'::character varying
    ])::text[]
  ));

COMMENT ON CONSTRAINT worker_profiles_availability_status_check
  ON public.worker_profiles IS
  'V3-BE5: stored availability is available or busy. DEFAULT remains available.';
