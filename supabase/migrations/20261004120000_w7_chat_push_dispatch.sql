-- ============================================================
-- W7: BOOKING CHAT PUSH — REUSE THE R5B DISPATCH PATH
-- ============================================================
--
-- SCOPE
-- -----
-- Owner decision 2026-10-04 (docs/DECISIONS.md, "W7 — Booking-scoped
-- chat push"). A newly inserted valid booking message may trigger a
-- privacy-preserving Android push to the OTHER booking participant.
--
-- This migration:
--   1. adds public.get_message_push_targets (service_role only)
--   2. adds private.w7_dispatch_message_inserted + AFTER INSERT trigger
--      on public.messages
--
-- REUSED, NOT DUPLICATED
-- ----------------------
--   * pg_net + the existing Vault secrets r5b_push_endpoint /
--     r5b_push_webhook_secret, so the existing push-notification Edge
--     Function is the only push transport.
--   * private.user_devices as the only token store.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No table, column, constraint, policy or grant change on any
--     business table. public table count stays 13.
--   * No public.notifications row per chat message (no second inbox
--     record). Message-to-notification fan-out is not introduced.
--   * No message content leaves the database: the webhook body is the
--     message id only, and the target projection has no content column.
--   * No change to messages RLS (confirmed-only send/read), R5
--     Broadcast, or the R5B notification dispatch.
-- ============================================================


-- ---------- 1. get_message_push_targets ----------
--
-- The recipient is derived from the authoritative Booking row: the
-- participant who is not the sender. A sender that is neither participant
-- (impossible under RLS) resolves to no recipient. The Booking must still
-- be confirmed when the push is resolved, matching the live chat boundary.

CREATE OR REPLACE FUNCTION public.get_message_push_targets(p_message_id uuid)
RETURNS TABLE (
  message_id      uuid,
  booking_id      uuid,
  expo_push_token text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT m.id,
         m.booking_id,
         d.expo_push_token
  FROM public.messages AS m
  JOIN public.bookings AS b
    ON b.id = m.booking_id
   AND b.status = 'confirmed'
  JOIN public.users AS r
    ON r.id = CASE
                WHEN m.sender_id = b.worker_id THEN b.client_id
                WHEN m.sender_id = b.client_id THEN b.worker_id
              END
   AND r.is_active = true
  JOIN private.user_devices AS d
    ON d.user_id = r.id
   AND d.is_active = true
  WHERE m.id = p_message_id
    AND r.id <> m.sender_id;
$$;

ALTER FUNCTION public.get_message_push_targets(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.get_message_push_targets(uuid) IS
  'W7: service-backend reread of one booking message: the opposite active '
  'participant''s active Expo tokens while the Booking is confirmed. Never '
  'the sender. Returns ids and tokens only — no message content, contact '
  'or profile fields. EXECUTE is service_role only.';

REVOKE ALL ON FUNCTION public.get_message_push_targets(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_message_push_targets(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.get_message_push_targets(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_message_push_targets(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_message_push_targets(uuid) TO service_role;


-- ---------- 2. AFTER INSERT dispatch on public.messages ----------

CREATE OR REPLACE FUNCTION private.w7_dispatch_message_inserted()
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
    RAISE WARNING 'W7 chat push dispatch skipped: vault config missing';
    RETURN NULL;
  END IF;

  BEGIN
    PERFORM net.http_post(
      url := btrim(v_endpoint),
      body := jsonb_build_object('message_id', NEW.id),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-skillmatch-push-secret', v_secret
      ),
      timeout_milliseconds := 5000
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'W7 chat push dispatch request failed';
  END;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'W7 chat push dispatch failed open';
  RETURN NULL;
END;
$$;

ALTER FUNCTION private.w7_dispatch_message_inserted() OWNER TO postgres;

COMMENT ON FUNCTION private.w7_dispatch_message_inserted() IS
  'W7 trigger-only: AFTER INSERT on public.messages, asynchronously POST '
  '{message_id} to the R5B Vault-configured push Edge Function. Missing '
  'Vault config or pg_net failure must not roll back the message.';

REVOKE ALL ON FUNCTION private.w7_dispatch_message_inserted() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.w7_dispatch_message_inserted() FROM anon;
REVOKE ALL ON FUNCTION private.w7_dispatch_message_inserted() FROM authenticated;
REVOKE ALL ON FUNCTION private.w7_dispatch_message_inserted() FROM service_role;

CREATE TRIGGER w7_dispatch_message_inserted
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION private.w7_dispatch_message_inserted();
