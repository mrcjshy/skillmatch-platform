-- ============================================================
-- R5B-DB-01: PRIVATE DEVICE REGISTRATION + ASYNC OS-PUSH DISPATCH
-- ============================================================
--
-- SCOPE
-- -----
-- Adds Expo Android device storage and one fail-open AFTER INSERT
-- dispatch on public.notifications. Persistent notification rows
-- remain the authority. Existing R5 private Broadcast is unchanged.
--
-- This migration:
--   1. enables pg_net (required for async HTTP)
--   2. requires vault.decrypted_secrets (no plaintext secret store)
--   3. creates private.user_devices (not a 13th public table)
--   4. adds public.register_my_push_device
--   5. adds public.deactivate_my_push_device
--   6. adds public.get_notification_push_targets (service_role only)
--   7. adds private.r5b_dispatch_notification_inserted + trigger
--
-- D-001: public application table count stays 12.
-- R5: r5_broadcast_notification_inserted is not rewritten.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No public.user_devices.
--   * No hosted Vault secret creation.
--   * No producer / emit_notification / R5 edits.
--   * No receipt polling, cron, or retry queue.
-- ============================================================


-- ---------- 1. pg_net ----------

CREATE EXTENSION IF NOT EXISTS pg_net;


-- ---------- 2. Vault capability ----------
--
-- The trigger reads future secret names from vault.decrypted_secrets.
-- This gate does not insert those secrets. If Vault is missing locally,
-- fail the migration rather than invent a plaintext store.

DO $$
BEGIN
  IF to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE EXCEPTION 'STOP — VAULT CAPABILITY MISMATCH';
  END IF;
END;
$$;


-- ---------- 3. private.user_devices ----------

CREATE TABLE private.user_devices (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  expo_push_token text NOT NULL,
  platform        text NOT NULL,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_devices_expo_push_token_chk
    CHECK (char_length(expo_push_token) >= 1 AND char_length(expo_push_token) <= 512),
  CONSTRAINT user_devices_platform_chk
    CHECK (platform = 'android'),
  CONSTRAINT user_devices_expo_push_token_key
    UNIQUE (expo_push_token)
);

CREATE INDEX user_devices_active_user_id_idx
  ON private.user_devices (user_id)
  WHERE is_active = true;

ALTER TABLE private.user_devices OWNER TO postgres;

COMMENT ON TABLE private.user_devices IS
  'R5B: Expo Android push device rows. Infrastructure storage in '
  'private; not a D-001 application table. Tokens only — never '
  'FCM/EAS/Expo credentials or contact data.';

ALTER TABLE private.user_devices ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.user_devices FROM PUBLIC;
REVOKE ALL ON TABLE private.user_devices FROM anon;
REVOKE ALL ON TABLE private.user_devices FROM authenticated;
REVOKE ALL ON TABLE private.user_devices FROM service_role;


-- ---------- 4. register_my_push_device ----------

CREATE OR REPLACE FUNCTION public.register_my_push_device(p_expo_push_token text)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_token  text;
  v_id     uuid;
  v_owner  uuid;
  v_active boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to register a push device'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.users AS u
    WHERE u.id = v_caller
      AND u.is_active = true
  ) THEN
    RAISE EXCEPTION 'not authorized to register a push device'
      USING ERRCODE = '42501';
  END IF;

  v_token := btrim(coalesce(p_expo_push_token, ''));
  IF v_token = '' OR char_length(v_token) > 512 THEN
    RAISE EXCEPTION 'invalid push token'
      USING ERRCODE = '22023';
  END IF;

  SELECT d.id, d.user_id, d.is_active
    INTO v_id, v_owner, v_active
  FROM private.user_devices AS d
  WHERE d.expo_push_token = v_token
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO private.user_devices (user_id, expo_push_token, platform)
    VALUES (v_caller, v_token, 'android')
    RETURNING private.user_devices.id INTO v_id;
    RETURN v_id;
  END IF;

  IF v_owner = v_caller THEN
    UPDATE private.user_devices AS d
    SET is_active = true,
        platform = 'android',
        updated_at = now()
    WHERE d.id = v_id;
    RETURN v_id;
  END IF;

  IF v_active IS NOT TRUE THEN
    UPDATE private.user_devices AS d
    SET user_id = v_caller,
        is_active = true,
        platform = 'android',
        updated_at = now()
    WHERE d.id = v_id;
    RETURN v_id;
  END IF;

  RAISE EXCEPTION 'this push token is not available'
    USING ERRCODE = 'SM409';
END;
$$;

ALTER FUNCTION public.register_my_push_device(text) OWNER TO postgres;

COMMENT ON FUNCTION public.register_my_push_device(text) IS
  'R5B: register or refresh the caller''s Expo Android push token. '
  'Owner is auth.uid() only. Active tokens owned by another user '
  'return SM409 without naming the owner. Inactive tokens may be '
  'reassigned to the current caller.';

REVOKE ALL ON FUNCTION public.register_my_push_device(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.register_my_push_device(text) FROM anon;
REVOKE ALL ON FUNCTION public.register_my_push_device(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.register_my_push_device(text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.register_my_push_device(text) TO authenticated;


-- ---------- 5. deactivate_my_push_device ----------

CREATE OR REPLACE FUNCTION public.deactivate_my_push_device(p_expo_push_token text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_token  text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to deactivate a push device'
      USING ERRCODE = '42501';
  END IF;

  v_token := btrim(coalesce(p_expo_push_token, ''));
  IF v_token = '' OR char_length(v_token) > 512 THEN
    RAISE EXCEPTION 'invalid push token'
      USING ERRCODE = '22023';
  END IF;

  UPDATE private.user_devices AS d
  SET is_active = false,
      updated_at = now()
  WHERE d.expo_push_token = v_token
    AND d.user_id = v_caller;
END;
$$;

ALTER FUNCTION public.deactivate_my_push_device(text) OWNER TO postgres;

COMMENT ON FUNCTION public.deactivate_my_push_device(text) IS
  'R5B: deactivate the caller''s own Expo token row. A token owned by '
  'another user matches zero rows and is indistinguishable from absent.';

REVOKE ALL ON FUNCTION public.deactivate_my_push_device(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_my_push_device(text) FROM anon;
REVOKE ALL ON FUNCTION public.deactivate_my_push_device(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.deactivate_my_push_device(text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.deactivate_my_push_device(text) TO authenticated;


-- ---------- 6. get_notification_push_targets ----------

CREATE OR REPLACE FUNCTION public.get_notification_push_targets(p_notification_id uuid)
RETURNS TABLE (
  notification_id      uuid,
  notification_type    text,
  notification_message text,
  expo_push_token      text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT n.id,
         n.type::text,
         n.message,
         d.expo_push_token
  FROM public.notifications AS n
  JOIN private.user_devices AS d
    ON d.user_id = n.user_id
   AND d.is_active = true
  WHERE n.id = p_notification_id;
$$;

ALTER FUNCTION public.get_notification_push_targets(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.get_notification_push_targets(uuid) IS
  'R5B: service-backend reread of one notification plus its active '
  'Expo tokens. EXECUTE is service_role only. Returns no contact or '
  'profile fields.';

REVOKE ALL ON FUNCTION public.get_notification_push_targets(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_notification_push_targets(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.get_notification_push_targets(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_notification_push_targets(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_notification_push_targets(uuid) TO service_role;


-- ---------- 7. R5B AFTER INSERT dispatch ----------

CREATE OR REPLACE FUNCTION private.r5b_dispatch_notification_inserted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_endpoint text;
  v_secret   text;
BEGIN
  SELECT ds.decrypted_secret
    INTO v_endpoint
  FROM vault.decrypted_secrets AS ds
  WHERE ds.name = 'r5b_push_endpoint'
  LIMIT 1;

  SELECT ds.decrypted_secret
    INTO v_secret
  FROM vault.decrypted_secrets AS ds
  WHERE ds.name = 'r5b_push_webhook_secret'
  LIMIT 1;

  IF v_endpoint IS NULL OR btrim(v_endpoint) = ''
     OR v_secret IS NULL OR btrim(v_secret) = '' THEN
    RAISE WARNING 'R5B push dispatch skipped: vault config missing';
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM net.http_post(
      url := btrim(v_endpoint),
      body := jsonb_build_object('notification_id', NEW.id),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-skillmatch-push-secret', v_secret
      ),
      timeout_milliseconds := 5000
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'R5B push dispatch request failed';
  END;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'R5B push dispatch failed open';
  RETURN NEW;
END;
$$;

ALTER FUNCTION private.r5b_dispatch_notification_inserted() OWNER TO postgres;

COMMENT ON FUNCTION private.r5b_dispatch_notification_inserted() IS
  'R5B trigger-only: AFTER INSERT on public.notifications, asynchronously '
  'POST {notification_id} to the Vault-configured Edge Function. Missing '
  'Vault config or pg_net failure must not roll back the notification.';

REVOKE ALL ON FUNCTION private.r5b_dispatch_notification_inserted() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.r5b_dispatch_notification_inserted() FROM anon;
REVOKE ALL ON FUNCTION private.r5b_dispatch_notification_inserted() FROM authenticated;
REVOKE ALL ON FUNCTION private.r5b_dispatch_notification_inserted() FROM service_role;

CREATE TRIGGER r5b_dispatch_notification_inserted
  AFTER INSERT ON public.notifications
  FOR EACH ROW
  EXECUTE FUNCTION private.r5b_dispatch_notification_inserted();
