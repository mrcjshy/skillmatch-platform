-- FT-06: extend the existing payload-free opportunity invalidation boundary.
-- Authorization/ranking remain in the existing RPCs. No table, grant, policy,
-- exact-location payload, matching function, or geofence definition changes.

CREATE TRIGGER ft06_users_eligibility_changed
  AFTER UPDATE OF is_active, role, barangay, city ON public.users
  FOR EACH STATEMENT
  EXECUTE FUNCTION private.r6_broadcast_job_opportunities_changed();

CREATE TRIGGER ft06_worker_profiles_eligibility_changed
  AFTER INSERT OR UPDATE OR DELETE ON public.worker_profiles
  FOR EACH STATEMENT
  EXECUTE FUNCTION private.r6_broadcast_job_opportunities_changed();

CREATE TRIGGER ft06_worker_skills_eligibility_changed
  AFTER INSERT OR UPDATE OR DELETE ON public.worker_skills
  FOR EACH STATEMENT
  EXECUTE FUNCTION private.r6_broadcast_job_opportunities_changed();

-- Existing Job and Job-skill triggers cover opportunity lifecycle/requirements.
-- Statement triggers deliberately coalesce bulk changes and disclose no row ID.
