-- REG-01: structured registration details for Workers and Clients, and a lean Worker resume.
--
-- Owner decisions (2026-11-03): a lean resume (name parts, birth date, home address, highest
-- education, years of experience per skill, up to three past jobs); a required "complete your
-- profile" step after sign-up and before Worker ID verification (existing accounts complete it
-- once); Clients add name parts, home address and an individual/business account type;
-- Administrators see the full profile, contact details included, for verification and in the
-- directories.
--
-- Columns only: the D-001 public table count stays 13. users.barangay / users.city stay the fixed
-- deployment scope that matching reads; the person's own home address is stored separately in
-- address_* columns and never feeds matching. users.full_name stays the display name every
-- existing RPC reads; save_my_profile_details recomposes it from the name parts.
-- Writes go through two caller-scoped RPCs that validate every field. A completion marker can
-- only be set when the data it vouches for is present (CHECK constraints), so a direct self-update
-- cannot fake completion.


-- ---------- 1. COLUMNS ----------

ALTER TABLE public.users
  ADD COLUMN first_name text,
  ADD COLUMN middle_name text,
  ADD COLUMN last_name text,
  ADD COLUMN name_suffix text,
  ADD COLUMN address_street text,
  ADD COLUMN address_barangay text,
  ADD COLUMN address_city text,
  ADD COLUMN address_province text,
  ADD COLUMN client_account_type text,
  ADD COLUMN business_name text,
  ADD COLUMN birth_date date,
  ADD COLUMN profile_completed_at timestamptz;

ALTER TABLE public.users
  ADD CONSTRAINT users_first_name_len CHECK (first_name IS NULL OR char_length(first_name) BETWEEN 1 AND 60),
  ADD CONSTRAINT users_middle_name_len CHECK (middle_name IS NULL OR char_length(middle_name) BETWEEN 1 AND 60),
  ADD CONSTRAINT users_last_name_len CHECK (last_name IS NULL OR char_length(last_name) BETWEEN 1 AND 60),
  ADD CONSTRAINT users_name_suffix_len CHECK (name_suffix IS NULL OR char_length(name_suffix) BETWEEN 1 AND 10),
  ADD CONSTRAINT users_address_street_len CHECK (address_street IS NULL OR char_length(address_street) BETWEEN 1 AND 160),
  ADD CONSTRAINT users_address_barangay_len CHECK (address_barangay IS NULL OR char_length(address_barangay) BETWEEN 1 AND 80),
  ADD CONSTRAINT users_address_city_len CHECK (address_city IS NULL OR char_length(address_city) BETWEEN 1 AND 80),
  ADD CONSTRAINT users_address_province_len CHECK (address_province IS NULL OR char_length(address_province) BETWEEN 1 AND 80),
  ADD CONSTRAINT users_client_account_type_check CHECK (client_account_type IS NULL OR client_account_type IN ('individual', 'business')),
  ADD CONSTRAINT users_business_name_len CHECK (business_name IS NULL OR char_length(business_name) BETWEEN 1 AND 120),
  ADD CONSTRAINT users_business_name_needs_business CHECK (business_name IS NULL OR client_account_type = 'business'),
  ADD CONSTRAINT users_birth_date_range CHECK (birth_date IS NULL OR birth_date BETWEEN DATE '1920-01-01' AND DATE '2100-01-01'),
  ADD CONSTRAINT users_profile_completed_has_details CHECK (
    profile_completed_at IS NULL OR (
      first_name IS NOT NULL AND last_name IS NOT NULL AND address_street IS NOT NULL
      AND address_barangay IS NOT NULL AND address_city IS NOT NULL AND address_province IS NOT NULL
      AND (role <> 'client' OR client_account_type IS NOT NULL)
      AND (client_account_type IS DISTINCT FROM 'business' OR business_name IS NOT NULL)
    )
  );

-- Birth date lives on users (own-row read only), never on worker_profiles, which every
-- authenticated account can read.
ALTER TABLE public.worker_profiles
  ADD COLUMN education_level text,
  ADD COLUMN school_name text,
  ADD COLUMN work_history jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN resume_completed_at timestamptz;

ALTER TABLE public.worker_profiles
  ADD CONSTRAINT worker_profiles_education_level_check CHECK (education_level IS NULL OR education_level IN (
    'none', 'elementary', 'high_school', 'senior_high', 'vocational', 'college_undergrad', 'college_graduate', 'postgraduate'
  )),
  ADD CONSTRAINT worker_profiles_school_name_len CHECK (school_name IS NULL OR char_length(school_name) BETWEEN 1 AND 120),
  ADD CONSTRAINT worker_profiles_work_history_shape CHECK (
    jsonb_typeof(work_history) = 'array' AND jsonb_array_length(work_history) <= 3
  ),
  ADD CONSTRAINT worker_profiles_resume_completed_has_resume CHECK (
    resume_completed_at IS NULL OR education_level IS NOT NULL
  );

ALTER TABLE public.worker_skills
  ADD COLUMN years_experience smallint;

ALTER TABLE public.worker_skills
  ADD CONSTRAINT worker_skills_years_experience_range CHECK (years_experience IS NULL OR years_experience BETWEEN 0 AND 60);

COMMENT ON COLUMN public.users.address_barangay IS
  'REG-01: the person''s own home barangay. Not users.barangay, which is the fixed deployment scope matching reads.';
COMMENT ON COLUMN public.users.profile_completed_at IS
  'REG-01: set by save_my_profile_details; implies the name parts and home address (and Client account type) are present.';
COMMENT ON COLUMN public.worker_profiles.work_history IS
  'REG-01: up to three past jobs, each {employer, role, start_year, end_year|null}, validated by save_my_worker_resume.';
COMMENT ON COLUMN public.worker_profiles.resume_completed_at IS
  'REG-01: set by save_my_worker_resume; implies education is present (the birth date is on users).';


-- ---------- 2. HELPERS ----------

-- Trimmed text or NULL; raises 22023 when longer than p_max.
CREATE FUNCTION private.reg01_text(p_value text, p_max integer, p_required boolean, p_field text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v text := nullif(btrim(regexp_replace(coalesce(p_value, ''), '\s+', ' ', 'g')), '');
BEGIN
  IF v IS NULL AND p_required THEN
    RAISE EXCEPTION '% is required', p_field USING ERRCODE = '22023';
  END IF;
  IF v IS NOT NULL AND char_length(v) > p_max THEN
    RAISE EXCEPTION '% is too long', p_field USING ERRCODE = '22023';
  END IF;
  RETURN v;
END;
$$;

ALTER FUNCTION private.reg01_text(text, integer, boolean, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.reg01_text(text, integer, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.reg01_text(text, integer, boolean, text) FROM anon;
REVOKE ALL ON FUNCTION private.reg01_text(text, integer, boolean, text) FROM authenticated;
REVOKE ALL ON FUNCTION private.reg01_text(text, integer, boolean, text) FROM service_role;


-- ---------- 3. SAVE MY PROFILE DETAILS (Worker and Client) ----------

CREATE FUNCTION public.save_my_profile_details(
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
    v_type := nullif(btrim(coalesce(p_client_account_type, '')), '');
    IF v_type IS NULL OR v_type NOT IN ('individual', 'business') THEN
      RAISE EXCEPTION 'account type must be individual or business' USING ERRCODE = '22023';
    END IF;
    v_business := private.reg01_text(p_business_name, 120, v_type = 'business', 'business name');
    IF v_type = 'individual' THEN v_business := NULL; END IF;
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

COMMENT ON FUNCTION public.save_my_profile_details(text, text, text, text, text, text, text, text, text, text) IS
  'REG-01: the active Worker or Client caller saves their name parts and home address (Clients also account type and business name). Recomposes users.full_name. Never touches the deployment-scope users.barangay/city, role or is_active. Sets profile_completed_at once.';

ALTER FUNCTION public.save_my_profile_details(text, text, text, text, text, text, text, text, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.save_my_profile_details(text, text, text, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_my_profile_details(text, text, text, text, text, text, text, text, text, text) TO authenticated;


-- ---------- 4. SAVE MY WORKER RESUME ----------

CREATE FUNCTION public.save_my_worker_resume(
  p_birth_date date,
  p_education_level text,
  p_school_name text,
  p_work_history jsonb,
  p_skills jsonb
)
RETURNS TABLE (worker_profile_id uuid, resume_completed_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_active boolean;
  v_profile uuid;
  v_age integer;
  v_job jsonb;
  v_jobs jsonb := '[]'::jsonb;
  v_employer text;
  v_job_role text;
  v_start integer;
  v_end integer;
  v_this_year integer := extract(year FROM (now() AT TIME ZONE 'Asia/Manila'))::integer;
  v_skill jsonb;
  v_skill_id uuid;
  v_years integer;
  v_seen uuid[] := '{}';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Lock order matches FT-05 and MOD-01: worker profile, then user.
  SELECT wp.id INTO v_profile FROM public.worker_profiles AS wp WHERE wp.user_id = v_uid FOR UPDATE;
  SELECT u.role::text, u.is_active IS TRUE INTO v_role, v_active
  FROM public.users AS u WHERE u.id = v_uid FOR UPDATE;
  IF NOT FOUND OR v_role <> 'worker' OR NOT v_active THEN
    RAISE EXCEPTION 'not authorized to save a Worker resume' USING ERRCODE = '42501';
  END IF;

  IF p_birth_date IS NULL THEN
    RAISE EXCEPTION 'birth date is required' USING ERRCODE = '22023';
  END IF;
  v_age := extract(year FROM age((now() AT TIME ZONE 'Asia/Manila')::date, p_birth_date))::integer;
  IF v_age < 18 OR v_age > 80 THEN
    RAISE EXCEPTION 'Workers must be 18 to 80 years old' USING ERRCODE = '22023';
  END IF;

  IF p_education_level IS NULL OR p_education_level NOT IN (
    'none', 'elementary', 'high_school', 'senior_high', 'vocational', 'college_undergrad', 'college_graduate', 'postgraduate'
  ) THEN
    RAISE EXCEPTION 'education level is invalid' USING ERRCODE = '22023';
  END IF;

  -- Work history: 0..3 jobs, each employer 1..120, role 1..80, start year, end year or NULL (present).
  IF p_work_history IS NULL OR jsonb_typeof(p_work_history) <> 'array' OR jsonb_array_length(p_work_history) > 3 THEN
    RAISE EXCEPTION 'work history must list at most three jobs' USING ERRCODE = '22023';
  END IF;
  FOR v_job IN SELECT value FROM jsonb_array_elements(p_work_history) LOOP
    IF jsonb_typeof(v_job) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_job) AS k WHERE k NOT IN ('employer', 'role', 'start_year', 'end_year'))
       OR coalesce(jsonb_typeof(v_job->'start_year'), '') <> 'number'
       OR (v_job ? 'end_year' AND jsonb_typeof(v_job->'end_year') NOT IN ('number', 'null')) THEN
      RAISE EXCEPTION 'work history entry is invalid' USING ERRCODE = '22023';
    END IF;
    v_employer := private.reg01_text(v_job->>'employer', 120, true, 'employer');
    v_job_role := private.reg01_text(v_job->>'role', 80, true, 'job title');
    v_start := (v_job->>'start_year')::numeric::integer;
    v_end := CASE WHEN jsonb_typeof(v_job->'end_year') = 'number' THEN (v_job->>'end_year')::numeric::integer END;
    IF (v_job->>'start_year')::numeric <> v_start OR v_start < 1960 OR v_start > v_this_year
       OR (v_end IS NOT NULL AND ((v_job->>'end_year')::numeric <> v_end OR v_end < v_start OR v_end > v_this_year)) THEN
      RAISE EXCEPTION 'work history years are invalid' USING ERRCODE = '22023';
    END IF;
    v_jobs := v_jobs || jsonb_build_array(jsonb_build_object(
      'employer', v_employer, 'role', v_job_role, 'start_year', v_start, 'end_year', to_jsonb(v_end)));
  END LOOP;

  -- Skills: 1..10 catalog skills, each with 0..60 years of experience.
  IF p_skills IS NULL OR jsonb_typeof(p_skills) <> 'array'
     OR jsonb_array_length(p_skills) < 1 OR jsonb_array_length(p_skills) > 10 THEN
    RAISE EXCEPTION 'choose one to ten skills' USING ERRCODE = '22023';
  END IF;
  FOR v_skill IN SELECT value FROM jsonb_array_elements(p_skills) LOOP
    IF jsonb_typeof(v_skill) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_skill) AS k WHERE k NOT IN ('skill_id', 'years'))
       OR coalesce(jsonb_typeof(v_skill->'skill_id'), '') <> 'string' OR coalesce(jsonb_typeof(v_skill->'years'), '') <> 'number'
       OR (v_skill->>'skill_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'skill entry is invalid' USING ERRCODE = '22023';
    END IF;
    v_skill_id := (v_skill->>'skill_id')::uuid;
    v_years := (v_skill->>'years')::numeric::integer;
    IF (v_skill->>'years')::numeric <> v_years OR v_years < 0 OR v_years > 60
       OR v_skill_id = ANY (v_seen)
       OR NOT EXISTS (SELECT 1 FROM public.skills AS s WHERE s.id = v_skill_id) THEN
      RAISE EXCEPTION 'skill entry is invalid' USING ERRCODE = '22023';
    END IF;
    v_seen := v_seen || v_skill_id;
  END LOOP;

  IF v_profile IS NULL THEN
    -- Same defaults the Piece E guard forces on a self-insert.
    INSERT INTO public.worker_profiles (user_id, badge_level) VALUES (v_uid, 'none') RETURNING id INTO v_profile;
  END IF;

  UPDATE public.users AS u SET birth_date = p_birth_date WHERE u.id = v_uid;

  UPDATE public.worker_profiles AS wp SET
    education_level = p_education_level,
    school_name = private.reg01_text(p_school_name, 120, false, 'school'),
    work_history = v_jobs,
    resume_completed_at = coalesce(wp.resume_completed_at, now())
  WHERE wp.id = v_profile;

  -- Add or update the listed skills; skills not listed are left as they are.
  INSERT INTO public.worker_skills AS ws (worker_id, skill_id, years_experience)
  SELECT v_profile, (e.value->>'skill_id')::uuid, (e.value->>'years')::numeric::integer
  FROM jsonb_array_elements(p_skills) AS e
  ON CONFLICT (worker_id, skill_id) DO UPDATE SET years_experience = excluded.years_experience;

  RETURN QUERY SELECT wp.id, wp.resume_completed_at FROM public.worker_profiles AS wp WHERE wp.id = v_profile;
END;
$$;

COMMENT ON FUNCTION public.save_my_worker_resume(date, text, text, jsonb, jsonb) IS
  'REG-01: the active Worker caller saves their lean resume: birth date (age 18-80, Manila date), education level and school, up to three past jobs and 1-10 catalog skills with years of experience. Creates the caller''s worker_profiles row if missing (protected columns keep their guarded defaults). Never touches verification, rating, strikes or badge. Sets resume_completed_at once.';

ALTER FUNCTION public.save_my_worker_resume(date, text, text, jsonb, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.save_my_worker_resume(date, text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_my_worker_resume(date, text, text, jsonb, jsonb) TO authenticated;


-- ---------- 5. ADMINISTRATOR READ: FULL PROFILE ----------

CREATE FUNCTION public.get_admin_account_profile(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_profile public.worker_profiles%ROWTYPE;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to read account profiles' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_user FROM public.users AS u WHERE u.id = p_user_id;
  IF NOT FOUND OR v_user.role NOT IN ('worker', 'client') THEN
    RAISE EXCEPTION 'this account is not available' USING ERRCODE = 'SM409';
  END IF;

  v_result := jsonb_build_object(
    'user_id', v_user.id,
    'role', v_user.role,
    'full_name', v_user.full_name,
    'first_name', v_user.first_name,
    'middle_name', v_user.middle_name,
    'last_name', v_user.last_name,
    'name_suffix', v_user.name_suffix,
    'email', v_user.email,
    'phone', v_user.phone,
    'address_street', v_user.address_street,
    'address_barangay', v_user.address_barangay,
    'address_city', v_user.address_city,
    'address_province', v_user.address_province,
    'client_account_type', v_user.client_account_type,
    'business_name', v_user.business_name,
    'profile_completed_at', v_user.profile_completed_at
  );

  IF v_user.role = 'worker' THEN
    SELECT * INTO v_profile FROM public.worker_profiles AS wp WHERE wp.user_id = v_user.id;
    v_result := v_result || jsonb_build_object(
      'birth_date', v_user.birth_date,
      'education_level', v_profile.education_level,
      'school_name', v_profile.school_name,
      'work_history', coalesce(v_profile.work_history, '[]'::jsonb),
      'resume_completed_at', v_profile.resume_completed_at,
      'skills', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'name', s.skill_name, 'proficiency', ws.proficiency_level, 'years', ws.years_experience)
          ORDER BY s.skill_name)
        FROM public.worker_skills AS ws
        JOIN public.skills AS s ON s.id = ws.skill_id
        WHERE v_profile.id IS NOT NULL AND ws.worker_id = v_profile.id
      ), '[]'::jsonb)
    );
  END IF;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_admin_account_profile(uuid) IS
  'REG-01: active-Administrator-only read of one Worker or Client profile for verification and directory review, contact details included (owner decision 2026-11-03, amending the AA-05 no-contact rule for this RPC only). Workers add the lean resume: birth date, education, work history and skills with years. Administrator or missing accounts are SM409. No writes.';

ALTER FUNCTION public.get_admin_account_profile(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_admin_account_profile(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_admin_account_profile(uuid) TO authenticated;


-- ---------- 6. OWN COMPLETION (the app's profile-step gate) ----------

CREATE FUNCTION public.get_my_profile_completion()
RETURNS TABLE (profile_complete boolean, resume_complete boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    u.profile_completed_at IS NOT NULL,
    CASE WHEN u.role = 'worker'
      THEN EXISTS (SELECT 1 FROM public.worker_profiles AS wp WHERE wp.user_id = u.id AND wp.resume_completed_at IS NOT NULL)
      ELSE true
    END
  FROM public.users AS u
  WHERE u.id = auth.uid() AND u.role IN ('worker', 'client');
$$;

COMMENT ON FUNCTION public.get_my_profile_completion() IS
  'REG-01: the caller''s own two completion markers (Clients have no resume, so resume_complete is true). Zero rows for anonymous callers, Administrators and missing accounts. A UX gate input only; never authorization.';

ALTER FUNCTION public.get_my_profile_completion() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_my_profile_completion() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_profile_completion() TO authenticated;
