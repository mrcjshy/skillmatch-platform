-- REG-02: Client home pin and an optional Client account type.
--
-- Owner decisions (2026-11-04):
--   * Clients pin their exact home on the map at sign-up (with the device's current location
--     available). Posting a Job then offers that pin as a ready choice. The pin must be inside the
--     Santa Ana, Pateros service area, by the same boundary check as Job pins.
--   * Clients are no longer asked Individual or Business: the account type becomes optional.
--
-- Columns only (D-001 public table count stays 13). The pin lives on public.users, whose RLS
-- allows own-row reads only, and it is written only through save_my_home_location.


-- ---------- 1. HOME PIN ----------

ALTER TABLE public.users
  ADD COLUMN home_latitude double precision,
  ADD COLUMN home_longitude double precision;

ALTER TABLE public.users
  ADD CONSTRAINT users_home_pin_pair CHECK ((home_latitude IS NULL) = (home_longitude IS NULL)),
  ADD CONSTRAINT users_home_pin_range CHECK (
    home_latitude IS NULL OR (home_latitude BETWEEN -90 AND 90 AND home_longitude BETWEEN -180 AND 180)
  );

COMMENT ON COLUMN public.users.home_latitude IS
  'REG-02: the Client''s own home pin (with home_longitude), inside the Santa Ana service area. Own-row read only; written by save_my_home_location.';


CREATE FUNCTION public.save_my_home_location(p_latitude double precision, p_longitude double precision)
RETURNS TABLE (home_latitude double precision, home_longitude double precision)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_active boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT u.role::text, u.is_active IS TRUE INTO v_role, v_active
  FROM public.users AS u WHERE u.id = v_uid FOR UPDATE;
  IF NOT FOUND OR v_role <> 'client' OR NOT v_active THEN
    RAISE EXCEPTION 'not authorized to save a home location' USING ERRCODE = '42501';
  END IF;

  -- Finite coordinates inside the official Santa Ana, Pateros polygon (22023 otherwise).
  PERFORM private.assert_job_pin_in_service_area(p_latitude, p_longitude);

  UPDATE public.users AS u SET home_latitude = p_latitude, home_longitude = p_longitude WHERE u.id = v_uid;
  RETURN QUERY SELECT u.home_latitude, u.home_longitude FROM public.users AS u WHERE u.id = v_uid;
END;
$$;

COMMENT ON FUNCTION public.save_my_home_location(double precision, double precision) IS
  'REG-02: the active Client caller saves their home pin. It must be inside the Santa Ana, Pateros service area (same check as Job pins). Never touches role, is_active or the deployment scope.';

ALTER FUNCTION public.save_my_home_location(double precision, double precision) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.save_my_home_location(double precision, double precision) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_my_home_location(double precision, double precision) TO authenticated;


-- ---------- 2. OPTIONAL CLIENT ACCOUNT TYPE ----------

ALTER TABLE public.users DROP CONSTRAINT users_profile_completed_has_details;
ALTER TABLE public.users
  ADD CONSTRAINT users_profile_completed_has_details CHECK (
    profile_completed_at IS NULL OR (
      first_name IS NOT NULL AND last_name IS NOT NULL AND address_street IS NOT NULL
      AND address_barangay IS NOT NULL AND address_city IS NOT NULL AND address_province IS NOT NULL
      AND (client_account_type IS DISTINCT FROM 'business' OR business_name IS NOT NULL)
    )
  );

CREATE OR REPLACE FUNCTION public.save_my_profile_details(
  p_first_name text,
  p_middle_name text,
  p_last_name text,
  p_name_suffix text,
  p_address_street text,
  p_address_barangay text,
  p_address_city text,
  p_address_province text,
  p_client_account_type text,
  p_business_name text
)
RETURNS TABLE (full_name text, profile_completed_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_active boolean;
  v_first text;
  v_middle text;
  v_last text;
  v_suffix text;
  v_type text;
  v_business text;
  v_full text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT u.role::text, u.is_active IS TRUE INTO v_role, v_active
  FROM public.users AS u WHERE u.id = v_uid FOR UPDATE;
  IF NOT FOUND OR v_role NOT IN ('worker', 'client') OR NOT v_active THEN
    RAISE EXCEPTION 'not authorized to save profile details' USING ERRCODE = '42501';
  END IF;

  v_first := private.reg01_text(p_first_name, 60, true, 'first name');
  v_middle := private.reg01_text(p_middle_name, 60, false, 'middle name');
  v_last := private.reg01_text(p_last_name, 60, true, 'last name');
  v_suffix := private.reg01_text(p_name_suffix, 10, false, 'suffix');

  IF v_role = 'client' THEN
    -- REG-02: the account type is optional (Clients are no longer asked); a given value must be valid.
    v_type := nullif(btrim(coalesce(p_client_account_type, '')), '');
    IF v_type IS NOT NULL AND v_type NOT IN ('individual', 'business') THEN
      RAISE EXCEPTION 'account type must be individual or business' USING ERRCODE = '22023';
    END IF;
    v_business := private.reg01_text(p_business_name, 120, coalesce(v_type = 'business', false), 'business name');
    IF v_type IS DISTINCT FROM 'business' THEN v_business := NULL; END IF;
  ELSIF p_client_account_type IS NOT NULL OR p_business_name IS NOT NULL THEN
    RAISE EXCEPTION 'account type is for Clients only' USING ERRCODE = '22023';
  END IF;

  v_full := concat_ws(' ', v_first, v_middle, v_last, v_suffix);

  UPDATE public.users AS u SET
    first_name = v_first,
    middle_name = v_middle,
    last_name = v_last,
    name_suffix = v_suffix,
    full_name = v_full,
    address_street = private.reg01_text(p_address_street, 160, true, 'street address'),
    address_barangay = private.reg01_text(p_address_barangay, 80, true, 'barangay'),
    address_city = private.reg01_text(p_address_city, 80, true, 'city'),
    address_province = private.reg01_text(p_address_province, 80, true, 'province'),
    client_account_type = v_type,
    business_name = v_business,
    profile_completed_at = coalesce(u.profile_completed_at, now())
  WHERE u.id = v_uid;

  RETURN QUERY SELECT u.full_name, u.profile_completed_at FROM public.users AS u WHERE u.id = v_uid;
END;
$$;


-- ---------- 3. COMPLETION: a Client also needs the home pin ----------

CREATE OR REPLACE FUNCTION public.get_my_profile_completion()
RETURNS TABLE (profile_complete boolean, resume_complete boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    u.profile_completed_at IS NOT NULL AND (u.role <> 'client' OR u.home_latitude IS NOT NULL),
    CASE WHEN u.role = 'worker'
      THEN EXISTS (SELECT 1 FROM public.worker_profiles AS wp WHERE wp.user_id = u.id AND wp.resume_completed_at IS NOT NULL)
      ELSE true
    END
  FROM public.users AS u
  WHERE u.id = auth.uid() AND u.role IN ('worker', 'client');
$$;

COMMENT ON FUNCTION public.get_my_profile_completion() IS
  'REG-01/02: the caller''s own completion markers. A Client''s profile is complete only with a home pin (REG-02). Zero rows for anonymous callers, Administrators and missing accounts. A UX gate input only; never authorization.';

COMMENT ON FUNCTION public.save_my_profile_details(text, text, text, text, text, text, text, text, text, text) IS
  'REG-01/02: the active Worker or Client caller saves their name parts and home address. Clients may also send an optional account type (and a business name for a business). Recomposes users.full_name. Never touches the deployment-scope users.barangay/city, role or is_active. Sets profile_completed_at once.';
