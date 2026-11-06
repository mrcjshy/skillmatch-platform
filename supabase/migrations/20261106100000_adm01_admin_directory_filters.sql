-- ============================================================
-- ADM-01: ADMIN DIRECTORY STATUS FILTER AND WORKER STRIKES
-- ============================================================
--
-- SCOPE
-- -----
-- Owner request 2026-11-06: in the Administrator Workers and Clients
-- directories (web console and app), filter by account status, and show
-- each Worker's no-show strikes (0 to 3) in the list.
--
--   p_status 'all'      every account (the v1 behavior)
--            'active'   users.is_active is true
--            'inactive' users.is_active is not true: banned (MOD-01) or
--                       suspended at three strikes (FT-05), the same state
--
-- Installed web and app builds parse the v1 directory rows against an
-- exact key set, so the v1 functions are left untouched and new builds
-- call these _v2 functions. Authorization, argument validation, search,
-- ordering and paging are identical to v1. strike_count is null for a
-- Worker account that has no worker_profiles row yet.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No table, column, constraint, RLS or grant change on user data.
--   * No change to get_admin_worker_directory or get_admin_client_directory.
--   * No contact details in the list (they stay on the detail read).
-- ============================================================


CREATE OR REPLACE FUNCTION public.get_admin_worker_directory_v2(
  p_search text DEFAULT NULL,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20,
  p_status text DEFAULT 'all'
)
RETURNS TABLE(total_count bigint, page integer, page_size integer, items jsonb)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
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
     OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 50
     OR p_status IS NULL OR p_status NOT IN ('all', 'active', 'inactive') THEN
    RAISE EXCEPTION 'invalid directory arguments' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH matches AS (
    SELECT u.id, u.full_name, u.is_active IS TRUE AS is_active, u.created_at,
           wp.id IS NOT NULL AS has_profile,
           wp.is_verified, wp.availability_status::text AS availability_status,
           CASE WHEN wp.id IS NULL THEN NULL ELSE coalesce(wp.strike_count, 0) END AS strike_count
      FROM public.users AS u
      LEFT JOIN public.worker_profiles AS wp ON wp.user_id = u.id
     WHERE u.role = 'worker'
       AND (v_search = '' OR strpos(lower(u.full_name), lower(v_search)) > 0)
       AND (p_status = 'all' OR (p_status = 'active') = (u.is_active IS TRUE))
  ), selected AS (
    SELECT * FROM matches
     ORDER BY created_at DESC NULLS LAST, id DESC
     LIMIT p_page_size OFFSET (p_page::bigint - 1) * p_page_size
  )
  SELECT (SELECT count(*) FROM matches), p_page, p_page_size,
         coalesce((SELECT jsonb_agg(jsonb_build_object(
           'user_id', id, 'full_name', full_name, 'is_active', is_active,
           'created_at', created_at, 'has_profile', has_profile,
           'is_verified', is_verified, 'availability_status', availability_status,
           'strike_count', strike_count
         ) ORDER BY created_at DESC NULLS LAST, id DESC) FROM selected), '[]'::jsonb);
END;
$$;


CREATE OR REPLACE FUNCTION public.get_admin_client_directory_v2(
  p_search text DEFAULT NULL,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20,
  p_status text DEFAULT 'all'
)
RETURNS TABLE(total_count bigint, page integer, page_size integer, items jsonb)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_search text;
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to read admin directory' USING ERRCODE = '42501';
  END IF;
  -- Match the ECMAScript trim() boundary set used by the clients.
  v_search := btrim(coalesce(p_search, ''), U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF');
  IF char_length(v_search) > 100 OR p_page IS NULL OR p_page < 1
     OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 50
     OR p_status IS NULL OR p_status NOT IN ('all', 'active', 'inactive') THEN
    RAISE EXCEPTION 'invalid directory arguments' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH matches AS (
    SELECT u.id, u.full_name, u.is_active IS TRUE AS is_active, u.created_at
      FROM public.users AS u
     WHERE u.role = 'client'
       AND (v_search = '' OR strpos(lower(u.full_name), lower(v_search)) > 0)
       AND (p_status = 'all' OR (p_status = 'active') = (u.is_active IS TRUE))
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


ALTER FUNCTION public.get_admin_worker_directory_v2(text, integer, integer, text) OWNER TO postgres;
ALTER FUNCTION public.get_admin_client_directory_v2(text, integer, integer, text) OWNER TO postgres;

COMMENT ON FUNCTION public.get_admin_worker_directory_v2(text, integer, integer, text) IS
  'ADM-01: v1 Worker directory plus p_status (all/active/inactive) and '
  'strike_count (null without a Worker profile). Active Administrators only (42501). '
  'Invalid arguments 22023. v1 is unchanged for installed builds.';
COMMENT ON FUNCTION public.get_admin_client_directory_v2(text, integer, integer, text) IS
  'ADM-01: v1 Client directory plus p_status (all/active/inactive). Active '
  'Administrators only (42501). Invalid arguments 22023. v1 is unchanged for installed builds.';

REVOKE ALL ON FUNCTION public.get_admin_worker_directory_v2(text, integer, integer, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_client_directory_v2(text, integer, integer, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_admin_worker_directory_v2(text, integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_client_directory_v2(text, integer, integer, text) TO authenticated;
