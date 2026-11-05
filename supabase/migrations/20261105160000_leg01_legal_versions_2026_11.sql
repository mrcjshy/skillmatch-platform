-- ============================================================
-- LEG-01: TERMS AND PRIVACY 2026-11-v1 WITH TRANSITION WINDOW
-- ============================================================
--
-- SCOPE
-- -----
-- Owner request 2026-11-05: final Terms and Conditions and Privacy Policy
-- written from the live system (video calls, Worker live location, Admin
-- reading of a reported booking's chat, strikes and bans, emails, REG-01/02
-- data, 18+ for every user, retention periods, Filipino translation).
-- Both versions move to 2026-11-v1, effective 2026-11-11.
--
-- Installed builds still send ('2026-09-v1', '2026-10-v1'). During the
-- transition window record_my_consent accepts those versions too, so those
-- builds keep recording consent for the text they show, while new builds
-- record ('2026-11-v1', '2026-11-v1'). A new build treats any older stored
-- version as not current and asks again. Stored rows are never rewritten.
--
-- Deploy order: the skillmatch-ai function that accepts privacy 2026-11-v1,
-- then this migration, then any build that sends 2026-11-v1. A later
-- migration retires the old versions by replacing only the two
-- private.is_accepted_* functions.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No table, column, constraint, RLS or grant change on user data.
--   * No change to private.user_consents rows or to get_my_consent.
--   * record_my_consent keeps its signature, owner, grants and behavior,
--     except that Terms are checked against an accepted set.
-- ============================================================


-- ---------- 1. CURRENT VERSIONS ----------

CREATE OR REPLACE FUNCTION private.current_legal_terms_version()
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT '2026-11-v1'::text;
$$;

CREATE OR REPLACE FUNCTION private.current_legal_privacy_version()
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT '2026-11-v1'::text;
$$;


-- ---------- 2. ACCEPTED VERSIONS (TRANSITION) ----------

CREATE OR REPLACE FUNCTION private.is_accepted_legal_terms_version(p_version text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT p_version IS NOT NULL
     AND (p_version = private.current_legal_terms_version()
          OR p_version = '2026-09-v1');
$$;

CREATE OR REPLACE FUNCTION private.is_accepted_legal_privacy_version(p_version text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT p_version IS NOT NULL
     AND (p_version = private.current_legal_privacy_version()
          OR p_version = '2026-10-v1'
          OR p_version = '2026-09-v1');
$$;

ALTER FUNCTION private.current_legal_terms_version() OWNER TO postgres;
ALTER FUNCTION private.current_legal_privacy_version() OWNER TO postgres;
ALTER FUNCTION private.is_accepted_legal_terms_version(text) OWNER TO postgres;
ALTER FUNCTION private.is_accepted_legal_privacy_version(text) OWNER TO postgres;

REVOKE ALL ON FUNCTION private.current_legal_terms_version()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.current_legal_privacy_version()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.is_accepted_legal_terms_version(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.is_accepted_legal_privacy_version(text)
  FROM PUBLIC, anon, authenticated, service_role;


-- ---------- 3. record_my_consent ----------
--
-- Identical to CAI-01 except the Terms check uses the accepted set.

CREATE OR REPLACE FUNCTION public.record_my_consent(
  p_terms_version text,
  p_privacy_version text
)
RETURNS TABLE (
  user_id                   uuid,
  terms_version             text,
  terms_accepted_at         timestamptz,
  privacy_version           text,
  privacy_acknowledged_at   timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller   uuid := auth.uid();
  v_terms    text;
  v_privacy  text;
  v_now      timestamptz := clock_timestamp();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to record consent'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.users AS u
    WHERE u.id = v_caller
  ) THEN
    RAISE EXCEPTION 'not authorized to record consent'
      USING ERRCODE = '42501';
  END IF;

  v_terms := btrim(coalesce(p_terms_version, ''));
  v_privacy := btrim(coalesce(p_privacy_version, ''));

  IF NOT private.is_accepted_legal_terms_version(v_terms)
     OR NOT private.is_accepted_legal_privacy_version(v_privacy)
  THEN
    RAISE EXCEPTION 'invalid consent version'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO private.user_consents (
    user_id,
    terms_version,
    terms_accepted_at,
    privacy_version,
    privacy_acknowledged_at
  ) VALUES (
    v_caller,
    v_terms,
    v_now,
    v_privacy,
    v_now
  )
  ON CONFLICT (user_id) DO UPDATE
    SET terms_version = EXCLUDED.terms_version,
        privacy_version = EXCLUDED.privacy_version,
        terms_accepted_at = CASE
          WHEN private.user_consents.terms_version IS DISTINCT FROM EXCLUDED.terms_version
            THEN EXCLUDED.terms_accepted_at
          ELSE private.user_consents.terms_accepted_at
        END,
        privacy_acknowledged_at = CASE
          WHEN private.user_consents.privacy_version IS DISTINCT FROM EXCLUDED.privacy_version
            THEN EXCLUDED.privacy_acknowledged_at
          ELSE private.user_consents.privacy_acknowledged_at
        END
  WHERE private.user_consents.user_id = v_caller;

  RETURN QUERY
  SELECT
    c.user_id,
    c.terms_version,
    c.terms_accepted_at,
    c.privacy_version,
    c.privacy_acknowledged_at
  FROM private.user_consents AS c
  WHERE c.user_id = v_caller;
END;
$$;

ALTER FUNCTION public.record_my_consent(text, text) OWNER TO postgres;

COMMENT ON FUNCTION public.record_my_consent(text, text) IS
  'LEG-01: record the caller''s Terms/Privacy versions. Owner is '
  'auth.uid() only. Same-version repeats keep original timestamps. '
  'Accepts the current 2026-11-v1 versions and, until retired, Terms '
  '2026-09-v1 and Privacy 2026-10-v1 / 2026-09-v1. Wrong versions raise '
  '22023. Signed-out or missing users row is 42501.';

REVOKE ALL ON FUNCTION public.record_my_consent(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_my_consent(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.record_my_consent(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.record_my_consent(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.record_my_consent(text, text) TO authenticated;
