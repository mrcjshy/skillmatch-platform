-- ============================================================
-- REG-03: RESUME SKILLS WITHOUT YEARS OF EXPERIENCE
-- ============================================================
--
-- Owner decision 2026-11-06: SkillMatch no longer asks Workers how many years
-- they have done each skill, and no screen shows it. Skill levels were removed
-- on 2026-11-05; years now follow.
--
-- Only public.save_my_worker_resume changes, and only its skill rules:
--   * a skill entry may leave out "years" or send null; it is then stored
--     with worker_skills.years_experience NULL;
--   * a whole number 0..60 (what installed apps still send) is accepted and
--     stored exactly as before, so those builds keep working;
--   * everything else in the function is copied unchanged from REG-01
--     (20261103150000, the version applied to hosted).
--
-- Not changed: the worker_skills.years_experience column and its 0..60 check,
-- get_admin_account_profile (its skill objects keep the keys name,
-- proficiency and years, which installed builds parse), grants, owner,
-- SECURITY DEFINER and search_path.
--
-- Rollback: re-run the REG-01 definition of save_my_worker_resume.

CREATE OR REPLACE FUNCTION public.save_my_worker_resume(
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

  -- Skills: 1..10 catalog skills. REG-03 (owner, 2026-11-06): years of experience are no longer
  -- asked, so "years" may be left out or null. An older app that still sends a whole number
  -- 0..60 is accepted as before.
  IF p_skills IS NULL OR jsonb_typeof(p_skills) <> 'array'
     OR jsonb_array_length(p_skills) < 1 OR jsonb_array_length(p_skills) > 10 THEN
    RAISE EXCEPTION 'choose one to ten skills' USING ERRCODE = '22023';
  END IF;
  FOR v_skill IN SELECT value FROM jsonb_array_elements(p_skills) LOOP
    IF jsonb_typeof(v_skill) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_skill) AS k WHERE k NOT IN ('skill_id', 'years'))
       OR coalesce(jsonb_typeof(v_skill->'skill_id'), '') <> 'string'
       OR coalesce(jsonb_typeof(v_skill->'years'), 'null') NOT IN ('number', 'null')
       OR (v_skill->>'skill_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'skill entry is invalid' USING ERRCODE = '22023';
    END IF;
    v_skill_id := (v_skill->>'skill_id')::uuid;
    v_years := (v_skill->>'years')::numeric::integer;
    IF (v_years IS NOT NULL AND ((v_skill->>'years')::numeric <> v_years OR v_years < 0 OR v_years > 60))
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

  -- Add or update the listed skills; skills not listed are left as they are. A listed skill sent
  -- without years is stored without years (NULL).
  INSERT INTO public.worker_skills AS ws (worker_id, skill_id, years_experience)
  SELECT v_profile, (e.value->>'skill_id')::uuid, (e.value->>'years')::numeric::integer
  FROM jsonb_array_elements(p_skills) AS e
  ON CONFLICT (worker_id, skill_id) DO UPDATE SET years_experience = excluded.years_experience;

  RETURN QUERY SELECT wp.id, wp.resume_completed_at FROM public.worker_profiles AS wp WHERE wp.id = v_profile;
END;
$$;

COMMENT ON FUNCTION public.save_my_worker_resume(date, text, text, jsonb, jsonb) IS
  'REG-01: the active Worker caller saves their lean resume: birth date (age 18-80, Manila date), education level and school, up to three past jobs and 1-10 catalog skills (REG-03, 2026-11-06: years of experience are optional and no longer asked; a whole number 0-60 from an older app is still accepted). Creates the caller''s worker_profiles row if missing (protected columns keep their guarded defaults). Never touches verification, rating, strikes or badge. Sets resume_completed_at once.';

ALTER FUNCTION public.save_my_worker_resume(date, text, text, jsonb, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.save_my_worker_resume(date, text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_my_worker_resume(date, text, text, jsonb, jsonb) TO authenticated;
