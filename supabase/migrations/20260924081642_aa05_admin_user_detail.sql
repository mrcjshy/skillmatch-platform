-- AA-05: one read-only, role-scoped Admin account detail. No table grants change.
CREATE FUNCTION public.get_admin_user_detail(p_user_id text, p_expected_role text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
  v_detail jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to read admin user detail' USING ERRCODE = '42501';
  END IF;

  IF p_expected_role IS NULL OR p_expected_role NOT IN ('worker', 'client')
     OR p_user_id IS NULL
     OR p_user_id !~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' THEN
    RAISE EXCEPTION 'invalid admin user detail arguments' USING ERRCODE = '22023';
  END IF;
  v_user_id := p_user_id::uuid;

  IF p_expected_role = 'worker' THEN
    SELECT jsonb_build_object(
      'user_id', u.id, 'full_name', u.full_name,
      'is_active', u.is_active IS TRUE, 'created_at', u.created_at,
      'has_profile', wp.id IS NOT NULL, 'is_verified', wp.is_verified,
      'availability_status', wp.availability_status::text,
      'completed_bookings_count', (
        SELECT count(*) FROM public.bookings AS b
         WHERE b.worker_id = u.id AND b.status = 'completed'
      )
    ) INTO v_detail
    FROM public.users AS u
    LEFT JOIN public.worker_profiles AS wp ON wp.user_id = u.id
    WHERE u.id = v_user_id AND u.role = 'worker';
  ELSE
    SELECT jsonb_build_object(
      'user_id', u.id, 'full_name', u.full_name,
      'is_active', u.is_active IS TRUE, 'created_at', u.created_at,
      'posted_jobs_count', (
        SELECT count(*) FROM public.job_postings AS j WHERE j.client_id = u.id
      )
    ) INTO v_detail
    FROM public.users AS u
    WHERE u.id = v_user_id AND u.role = 'client';
  END IF;
  RETURN v_detail;
END;
$$;

ALTER FUNCTION public.get_admin_user_detail(text, text) OWNER TO postgres;
COMMENT ON FUNCTION public.get_admin_user_detail(text, text) IS
  'AA-05: active-Admin-only Worker or Client account detail and retained-row counts; no writes.';
REVOKE ALL ON FUNCTION public.get_admin_user_detail(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_admin_user_detail(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.get_admin_user_detail(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_admin_user_detail(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_admin_user_detail(text, text) TO authenticated;
