-- ============================================================
-- RF-03 — Remove the direct client path to public.verify_worker(uuid)
-- ============================================================
--
-- Why: V3-DB3 made approve_worker_identity(uuid) the only Administrator
-- path that verifies a Worker, because it also settles the pending ID
-- document. verify_worker(uuid) was still EXECUTE-granted to
-- authenticated (N10/N12), so an active Administrator could set
-- is_verified directly and skip the ID review. RF-A (D-009 amendment,
-- 2026-10-14) adds a second Admin surface, so the bypass is closed first.
--
-- Callers checked 2026-10-14 (repository + rollback APK source):
--   * public.approve_worker_identity(uuid) -- SECURITY DEFINER, owner
--     postgres. EXECUTE is checked against the owner, so revoking from
--     authenticated does not affect it.
--   * No mobile source, Edge Function or web caller.
--   * The rollback APK 5333ce4d was built from the same mobile source
--     (fingerprint 130b3a6636e9f9c8), which has no verify_worker call.
--   * Hosted-only callers (function bodies not in this repository) must
--     be re-checked against pg_proc before this migration is applied
--     hosted.
--
-- Unchanged: verify_worker's body, its internal is_admin/SM409 guards,
-- its notification side effect, and every other grant.
-- ============================================================

REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM service_role;
