-- ============================================================
-- PHO-01: MATCHED WORKERS SEE AN OPEN JOB'S PHOTOS BEFORE ACCEPTING
-- ============================================================
--
-- Owner decision 2026-11-06: a Worker deciding whether to accept a Job must be
-- able to see the photos the Client attached. Until now only the owning Client
-- and the Worker on the confirmed booking could read them (V4-9).
--
-- Adds one Storage SELECT policy on the private 'job-photos' bucket. A Worker
-- may read <client_id>/<job_id>/<1|2|3> only while that Job is open, its time
-- has not passed, the folder's client is the Job's own Client, and the Worker
-- passes Stage 1 for it (private.compute_job_matches), the same rule that lets
-- them see and accept the opportunity. Nothing else changes: no write access,
-- the V4-9 policies stay as they are, and once the Job is booked only the
-- booked Worker keeps access.
--
-- Rollback: DROP POLICY "Matched workers can select open job photos" ON
-- storage.objects; DROP FUNCTION private.can_view_opportunity_job_photo(text);

CREATE FUNCTION private.can_view_opportunity_job_photo(p_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT cardinality(storage.foldername(p_name)) = 2
    AND storage.filename(p_name) IN ('1', '2', '3')
    AND EXISTS (
      SELECT 1
      FROM public.job_postings AS jp
      CROSS JOIN LATERAL private.compute_job_matches(jp.id) AS m
      WHERE jp.client_id::text = (storage.foldername(p_name))[1]
        AND jp.id::text = (storage.foldername(p_name))[2]
        AND jp.status = 'open'
        AND (jp.scheduled_at IS NULL OR jp.scheduled_at > now())
        AND m.worker_id = (SELECT auth.uid())
    );
$$;

COMMENT ON FUNCTION private.can_view_opportunity_job_photo(text) IS
  'PHO-01: true when the caller passes Stage 1 for the open, not-yet-past Job whose photo folder <client_id>/<job_id> holds this slot 1-3 object. Used only by the job-photos Storage SELECT policy.';

ALTER FUNCTION private.can_view_opportunity_job_photo(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.can_view_opportunity_job_photo(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.can_view_opportunity_job_photo(text) TO authenticated;

CREATE POLICY "Matched workers can select open job photos"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'job-photos'
    AND private.is_active_worker()
    AND private.can_view_opportunity_job_photo(name)
  );
