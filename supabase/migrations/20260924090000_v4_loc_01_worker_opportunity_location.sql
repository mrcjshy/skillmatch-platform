-- V4-LOC-01: a separate pre-accept location surface. No table grants or matching changes.
CREATE FUNCTION public.get_my_opportunity_location(p_job_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_job_id uuid;
  v_location jsonb;
BEGIN
  -- Authorization precedes argument validation, including for malformed ids.
  IF auth.uid() IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized for opportunity location' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.worker_profiles AS wp
    WHERE wp.user_id = auth.uid() AND wp.is_verified IS TRUE
  ) THEN
    RAISE EXCEPTION 'not authorized for opportunity location' USING ERRCODE = '42501';
  END IF;
  IF p_job_id IS NULL OR
     p_job_id !~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' THEN
    RAISE EXCEPTION 'invalid opportunity location arguments' USING ERRCODE = '22023';
  END IF;
  v_job_id := p_job_id::uuid;

  -- Consume the existing opportunity API unchanged: one eligibility authority.
  -- One statement snapshot covers eligibility and the protected projection.
  SELECT jsonb_build_object(
    'latitude', jl.latitude, 'longitude', jl.longitude,
    'address', jp.address, 'barangay', jp.barangay, 'city', jp.city
  ) INTO v_location
  FROM public.list_my_job_opportunities() AS opportunity
  JOIN private.job_locations AS jl ON jl.job_id = opportunity.job_id
  JOIN public.job_postings AS jp ON jp.id = opportunity.job_id
  WHERE opportunity.job_id = v_job_id;

  -- Missing Job, pin, opportunity, and eligibility share SQL NULL. Legacy nullable
  -- addresses remain JSON null; this read never fabricates or backfills an address.
  RETURN v_location;
END;
$$;

ALTER FUNCTION public.get_my_opportunity_location(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_my_opportunity_location(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_opportunity_location(text) TO authenticated;
COMMENT ON FUNCTION public.get_my_opportunity_location(text) IS
  'V4-LOC-01: exact location for the caller''s currently eligible opportunity only; no contact data, writes, or direct table access.';
