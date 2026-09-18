-- ============================================================
-- V3-DB-05: get_my_consent REQUIRES A public.users ROW
-- ============================================================
--
-- SCOPE
-- -----
-- CREATE OR REPLACE public.get_my_consent() so an authenticated
-- caller with auth.uid() but no public.users row receives 42501,
-- matching public.record_my_consent.
--
-- AccountProvider relies on an authoritative application-user
-- row. An empty result is reserved for "users row exists, no
-- consent recorded".
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No change to private.user_consents.
--   * No change to record_my_consent.
--   * No change to matching, bookings, or is_verified.
--   * No hosted deployment.
-- ============================================================


CREATE OR REPLACE FUNCTION public.get_my_consent()
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.users AS u
    WHERE u.id = v_caller
  ) THEN
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
  'V3-DB5: read the caller''s own consent row. Zero rows means none '
  'recorded. Signed-out or missing public.users row is 42501.';

REVOKE ALL ON FUNCTION public.get_my_consent() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_consent() FROM anon;
REVOKE ALL ON FUNCTION public.get_my_consent() FROM authenticated;
REVOKE ALL ON FUNCTION public.get_my_consent() FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_my_consent() TO authenticated;
