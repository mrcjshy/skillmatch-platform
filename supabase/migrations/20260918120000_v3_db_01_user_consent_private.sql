-- ============================================================
-- V3-DB-01: PRIVATE USER CONSENTS
-- ============================================================
--
-- SCOPE
-- -----
-- Records Terms + Privacy acceptance for the authenticated own user
-- in private.user_consents (not a 14th public D-001 table).
--
-- Locked versions for this gate:
--   terms_version   = 2026-09-v1
--   privacy_version = 2026-09-v1
--
-- Final legal wording is separately reviewable. This migration stores
-- version keys and timestamps only.
--
-- RPCs:
--   public.record_my_consent(p_terms_version, p_privacy_version)
--   public.get_my_consent()
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No public.user_consents.
--   * No Auth-metadata consent authority.
--   * No other-user read/write.
--   * No hosted deployment.
--   * No change to matching, bookings, verification, or job posting.
-- ============================================================


-- ---------- 1. PRIVATE TABLE ----------

CREATE TABLE private.user_consents (
  user_id                   uuid PRIMARY KEY
                            REFERENCES public.users(id) ON DELETE CASCADE,
  terms_version             text NOT NULL,
  terms_accepted_at         timestamptz NOT NULL,
  privacy_version           text NOT NULL,
  privacy_acknowledged_at   timestamptz NOT NULL,
  CONSTRAINT user_consents_terms_version_chk
    CHECK (char_length(btrim(terms_version)) >= 1
       AND char_length(terms_version) <= 64),
  CONSTRAINT user_consents_privacy_version_chk
    CHECK (char_length(btrim(privacy_version)) >= 1
       AND char_length(privacy_version) <= 64)
);

ALTER TABLE private.user_consents OWNER TO postgres;

COMMENT ON TABLE private.user_consents IS
  'V3-DB1: own-user Terms/Privacy version timestamps. Private; not a '
  'D-001 application table. Version keys only — not legal document text.';

ALTER TABLE private.user_consents ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.user_consents FROM PUBLIC;
REVOKE ALL ON TABLE private.user_consents FROM anon;
REVOKE ALL ON TABLE private.user_consents FROM authenticated;
REVOKE ALL ON TABLE private.user_consents FROM service_role;


-- ---------- 2. CURRENT VERSION GATE ----------

CREATE FUNCTION private.current_legal_terms_version()
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT '2026-09-v1'::text;
$$;

ALTER FUNCTION private.current_legal_terms_version() OWNER TO postgres;

REVOKE ALL ON FUNCTION private.current_legal_terms_version()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION private.current_legal_privacy_version()
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT '2026-09-v1'::text;
$$;

ALTER FUNCTION private.current_legal_privacy_version() OWNER TO postgres;

REVOKE ALL ON FUNCTION private.current_legal_privacy_version()
  FROM PUBLIC, anon, authenticated, service_role;


-- ---------- 3. record_my_consent ----------
--
-- Own-user only. Versions must match the locked current pair.
-- Same-version repeat is idempotent: original timestamps are kept.
-- A future version bump (after these helpers change) updates both
-- columns and stamps new acceptance times.

CREATE FUNCTION public.record_my_consent(
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

  IF v_terms IS DISTINCT FROM private.current_legal_terms_version()
     OR v_privacy IS DISTINCT FROM private.current_legal_privacy_version()
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
  'V3-DB1: record the caller''s Terms/Privacy versions. Owner is '
  'auth.uid() only. Same-version repeats keep original timestamps. '
  'Wrong versions raise 22023. Signed-out or missing users row is 42501.';

REVOKE ALL ON FUNCTION public.record_my_consent(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_my_consent(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.record_my_consent(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.record_my_consent(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.record_my_consent(text, text) TO authenticated;


-- ---------- 4. get_my_consent ----------

CREATE FUNCTION public.get_my_consent()
RETURNS TABLE (
  user_id                   uuid,
  terms_version             text,
  terms_accepted_at         timestamptz,
  privacy_version           text,
  privacy_acknowledged_at   timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to read consent'
      USING ERRCODE = '42501';
  END IF;

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

ALTER FUNCTION public.get_my_consent() OWNER TO postgres;

COMMENT ON FUNCTION public.get_my_consent() IS
  'V3-DB1: read the caller''s own consent row. Zero rows means none '
  'recorded. Signed-out callers receive 42501.';

REVOKE ALL ON FUNCTION public.get_my_consent() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_consent() FROM anon;
REVOKE ALL ON FUNCTION public.get_my_consent() FROM authenticated;
REVOKE ALL ON FUNCTION public.get_my_consent() FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_my_consent() TO authenticated;
