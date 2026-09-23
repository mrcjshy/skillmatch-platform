-- AA-01B: read-only Administrator aggregate dashboard contract.
-- One current, all-time snapshot of retained application rows. No source
-- table, policy, index, or business row is changed by this migration.

CREATE FUNCTION public.get_admin_analytics_summary()
RETURNS TABLE (
  as_of                         timestamptz,
  total_workers                 bigint,
  verified_workers              bigint,
  pending_worker_verifications  bigint,
  total_clients                 bigint,
  jobs_by_status                jsonb,
  bookings_by_status            jsonb,
  completed_bookings            bigint,
  payments_by_method_status     jsonb,
  reports_by_status             jsonb,
  reports_needing_attention     bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to read admin analytics'
      USING ERRCODE = '42501';
  END IF;

  -- Every scalar subquery counts its own base entity. In particular, no
  -- skills, images, messages, or submissions are joined into the Worker,
  -- Job, Booking, or Report totals. The ID-review count deliberately mirrors
  -- list_workers_pending_id_review(), not list_unverified_workers().
  RETURN QUERY
  SELECT
    statement_timestamp(),
    (SELECT count(*) FROM public.users AS u WHERE u.role = 'worker'),
    (SELECT count(*)
       FROM public.users AS u
       JOIN public.worker_profiles AS wp ON wp.user_id = u.id
      WHERE u.role = 'worker' AND wp.is_verified IS TRUE),
    (SELECT count(DISTINCT u.id)
       FROM private.worker_id_documents AS d
       JOIN public.worker_profiles AS wp ON wp.id = d.worker_profile_id
       JOIN public.users AS u ON u.id = d.user_id
      WHERE d.status = 'pending' AND u.role = 'worker'),
    (SELECT count(*) FROM public.users AS u WHERE u.role = 'client'),
    (SELECT jsonb_build_object(
       'open',      count(*) FILTER (WHERE j.status = 'open'),
       'matched',   count(*) FILTER (WHERE j.status = 'matched'),
       'completed', count(*) FILTER (WHERE j.status = 'completed'),
       'cancelled', count(*) FILTER (WHERE j.status = 'cancelled'),
       'unset',     count(*) FILTER (WHERE j.status IS NULL)
     ) FROM public.job_postings AS j),
    (SELECT jsonb_build_object(
       'pending',   count(*) FILTER (WHERE b.status = 'pending'),
       'confirmed', count(*) FILTER (WHERE b.status = 'confirmed'),
       'completed', count(*) FILTER (WHERE b.status = 'completed'),
       'cancelled', count(*) FILTER (WHERE b.status = 'cancelled'),
       'no_show',   count(*) FILTER (WHERE b.status = 'no_show')
     ) FROM public.bookings AS b),
    (SELECT count(*) FROM public.bookings AS b WHERE b.status = 'completed'),
    (
      WITH payment_counts AS (
        SELECT
          coalesce(b.payment_method::text, 'unset') AS method_key,
          coalesce(b.payment_status::text, 'unset') AS status_key,
          count(*) AS n
        FROM public.bookings AS b
        GROUP BY 1, 2
      )
      SELECT jsonb_object_agg(m.method_key, (
        SELECT jsonb_object_agg(s.status_key, coalesce(pc.n, 0))
        FROM (VALUES ('pending'), ('paid'), ('refunded'), ('unset'))
             AS s(status_key)
        LEFT JOIN payment_counts AS pc
          ON pc.method_key = m.method_key
         AND pc.status_key = s.status_key
      ))
      FROM (VALUES ('gcash'), ('maya'), ('qrph'), ('cod'), ('unset'))
           AS m(method_key)
    ),
    (SELECT jsonb_build_object(
       'submitted',    count(*) FILTER (WHERE r.status = 'submitted'),
       'under_review', count(*) FILTER (WHERE r.status = 'under_review'),
       'resolved',     count(*) FILTER (WHERE r.status = 'resolved'),
       'dismissed',    count(*) FILTER (WHERE r.status = 'dismissed')
     ) FROM public.reports AS r),
    (SELECT count(*) FROM public.reports AS r
      WHERE r.status IN ('submitted', 'under_review'));
END;
$$;

ALTER FUNCTION public.get_admin_analytics_summary() OWNER TO postgres;

COMMENT ON FUNCTION public.get_admin_analytics_summary() IS
  'AA-01B: one aggregate-only current snapshot for active Administrators. '
  'No parameters, private fields, business writes, or broad table access. '
  'Pending verifications mirror the pending-ID review queue; payment counts '
  'use Booking state, including legacy NULL buckets.';

REVOKE ALL ON FUNCTION public.get_admin_analytics_summary() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_admin_analytics_summary() FROM anon;
REVOKE ALL ON FUNCTION public.get_admin_analytics_summary() FROM authenticated;
REVOKE ALL ON FUNCTION public.get_admin_analytics_summary() FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_admin_analytics_summary() TO authenticated;
