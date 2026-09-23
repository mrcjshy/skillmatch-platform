-- AA-04: read-only, role-separated Admin directories. No table grants change.
CREATE FUNCTION public.get_admin_worker_directory(
  p_search text DEFAULT NULL, p_page integer DEFAULT 1, p_page_size integer DEFAULT 20
)
RETURNS TABLE (total_count bigint, page integer, page_size integer, items jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_search text;
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to read admin directory' USING ERRCODE = '42501';
  END IF;
  -- ECMAScript trim(): TAB..CR, space, NBSP, OGHAM, U+2000..200A,
  -- line/paragraph separators, narrow NBSP, medium space, ideographic space, BOM.
  v_search := btrim(coalesce(p_search, ''), U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF');
  IF char_length(v_search) > 100 OR p_page IS NULL OR p_page < 1
     OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'invalid directory arguments' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH matches AS (
    SELECT u.id, u.full_name, u.is_active IS TRUE AS is_active, u.created_at,
           wp.id IS NOT NULL AS has_profile,
           wp.is_verified, wp.availability_status::text AS availability_status
      FROM public.users AS u
      LEFT JOIN public.worker_profiles AS wp ON wp.user_id = u.id
     WHERE u.role = 'worker'
       AND (v_search = '' OR strpos(lower(u.full_name), lower(v_search)) > 0)
  ), selected AS (
    SELECT * FROM matches
     ORDER BY created_at DESC NULLS LAST, id DESC
     LIMIT p_page_size OFFSET (p_page::bigint - 1) * p_page_size
  )
  SELECT (SELECT count(*) FROM matches), p_page, p_page_size,
         coalesce((SELECT jsonb_agg(jsonb_build_object(
           'user_id', id, 'full_name', full_name, 'is_active', is_active,
           'created_at', created_at, 'has_profile', has_profile,
           'is_verified', is_verified, 'availability_status', availability_status
         ) ORDER BY created_at DESC NULLS LAST, id DESC) FROM selected), '[]'::jsonb);
END;
$$;
ALTER FUNCTION public.get_admin_worker_directory(text, integer, integer) OWNER TO postgres;
COMMENT ON FUNCTION public.get_admin_worker_directory(text, integer, integer) IS
  'AA-04: active-Admin-only Worker account summary, literal name search, bounded pages, deterministic newest-first order.';
REVOKE ALL ON FUNCTION public.get_admin_worker_directory(text, integer, integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_admin_worker_directory(text, integer, integer) TO authenticated;

CREATE FUNCTION public.get_admin_client_directory(
  p_search text DEFAULT NULL, p_page integer DEFAULT 1, p_page_size integer DEFAULT 20
)
RETURNS TABLE (total_count bigint, page integer, page_size integer, items jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_search text;
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to read admin directory' USING ERRCODE = '42501';
  END IF;
  -- Match the ECMAScript trim() boundary set used by Mobile above.
  v_search := btrim(coalesce(p_search, ''), U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF');
  IF char_length(v_search) > 100 OR p_page IS NULL OR p_page < 1
     OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'invalid directory arguments' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH matches AS (
    SELECT u.id, u.full_name, u.is_active IS TRUE AS is_active, u.created_at
      FROM public.users AS u
     WHERE u.role = 'client'
       AND (v_search = '' OR strpos(lower(u.full_name), lower(v_search)) > 0)
  ), selected AS (
    SELECT * FROM matches
     ORDER BY created_at DESC NULLS LAST, id DESC
     LIMIT p_page_size OFFSET (p_page::bigint - 1) * p_page_size
  )
  SELECT (SELECT count(*) FROM matches), p_page, p_page_size,
         coalesce((SELECT jsonb_agg(jsonb_build_object(
           'user_id', id, 'full_name', full_name, 'is_active', is_active,
           'created_at', created_at
         ) ORDER BY created_at DESC NULLS LAST, id DESC) FROM selected), '[]'::jsonb);
END;
$$;
ALTER FUNCTION public.get_admin_client_directory(text, integer, integer) OWNER TO postgres;
COMMENT ON FUNCTION public.get_admin_client_directory(text, integer, integer) IS
  'AA-04: active-Admin-only Client account summary, literal name search, bounded pages, deterministic newest-first order.';
REVOKE ALL ON FUNCTION public.get_admin_client_directory(text, integer, integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_admin_client_directory(text, integer, integer) TO authenticated;
