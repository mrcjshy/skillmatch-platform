-- ============================================================
-- R5-DB-01: PRIVATE BROADCAST FRESHNESS TRANSPORT
-- ============================================================
--
-- SCOPE
-- -----
-- Adds receive-only private Broadcast authorization and three
-- database-triggered invalidation events. Persistent business
-- writes stay on public.messages, public.notifications,
-- public.bookings, existing RPCs, and existing RLS.
--
-- This migration:
--   1. adds two FOR SELECT TO authenticated policies on
--      realtime.messages (booking topic + own-user topic)
--   2. adds three private SECURITY DEFINER trigger functions
--      that call realtime.send(..., true)
--   3. adds AFTER INSERT / AFTER UPDATE OF status triggers
--
-- D-001: table count stays 12. No new application table, column,
-- or public RPC. No public RLS policy is created, dropped, or
-- rewritten. supabase_realtime publication is not altered.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No authenticated realtime.messages INSERT policy.
--   * No postgres_changes / realtime.broadcast_changes.
--   * No publication of public.messages / notifications / bookings.
--   * No message-to-notification fan-out.
--   * No messages.is_read maintenance, Presence, or R5B push.
--   * No hosted Realtime settings change.
--
-- TDD SEAMS (public behavior; hosted apply is a later gate)
-- --------------------------------------------------------
--   * confirmed Worker/Client can receive booking:<id>:messages
--   * unrelated / wrong-booking / terminal / malformed / anon deny
--   * own user:<uid>:notifications receive; other-user / anon deny
--   * no client Broadcast-send INSERT authority
--   * message INSERT emits message_inserted with ids only
--   * trusted notification INSERT emits notification_inserted
--   * confirmed -> non-confirmed emits booking_status_changed
--   * confirmed-preserving UPDATE emits nothing
--   * rolled-back business write commits no Broadcast row
-- ============================================================


-- ---------- 1. BOOKING TOPIC RECEIVE ----------
--
-- Exact canonical comparison, not a topic-text UUID cast.
-- A malformed or non-canonical topic simply matches no Booking
-- and returns zero rows. Terminal Bookings are not authorized.

CREATE POLICY "R5 authenticated can receive booking message broadcasts"
  ON realtime.messages
  FOR SELECT
  TO authenticated
  USING (
    realtime.messages.extension = 'broadcast'
    AND EXISTS (
      SELECT 1
      FROM public.bookings AS b
      WHERE (SELECT realtime.topic())
            = ('booking:' || b.id::text || ':messages')
        AND b.status = 'confirmed'
        AND (
          b.worker_id = (SELECT auth.uid())
          OR b.client_id = (SELECT auth.uid())
        )
    )
  );


-- ---------- 2. NOTIFICATION TOPIC RECEIVE ----------

CREATE POLICY "R5 authenticated can receive own notification broadcasts"
  ON realtime.messages
  FOR SELECT
  TO authenticated
  USING (
    realtime.messages.extension = 'broadcast'
    AND (SELECT realtime.topic())
        = ('user:' || (SELECT auth.uid())::text || ':notifications')
  );


-- ---------- 3. MESSAGE INSERTED ----------

CREATE OR REPLACE FUNCTION private.r5_broadcast_message_inserted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM realtime.send(
    jsonb_build_object(
      'booking_id', NEW.booking_id,
      'message_id', NEW.id
    ),
    'message_inserted',
    'booking:' || NEW.booking_id::text || ':messages',
    true
  );
  RETURN NULL;
END;
$$;


ALTER FUNCTION private.r5_broadcast_message_inserted() OWNER TO postgres;

COMMENT ON FUNCTION private.r5_broadcast_message_inserted() IS
  'R5 trigger-only: AFTER INSERT on public.messages, emit private '
  'message_inserted invalidation on booking:<booking_id>:messages. '
  'Payload is booking_id + message_id only.';

REVOKE ALL ON FUNCTION private.r5_broadcast_message_inserted() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.r5_broadcast_message_inserted() FROM anon;
REVOKE ALL ON FUNCTION private.r5_broadcast_message_inserted() FROM authenticated;
REVOKE ALL ON FUNCTION private.r5_broadcast_message_inserted() FROM service_role;


CREATE TRIGGER r5_broadcast_message_inserted
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION private.r5_broadcast_message_inserted();


-- ---------- 4. NOTIFICATION INSERTED ----------

CREATE OR REPLACE FUNCTION private.r5_broadcast_notification_inserted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM realtime.send(
    jsonb_build_object(
      'notification_id', NEW.id
    ),
    'notification_inserted',
    'user:' || NEW.user_id::text || ':notifications',
    true
  );
  RETURN NULL;
END;
$$;


ALTER FUNCTION private.r5_broadcast_notification_inserted() OWNER TO postgres;

COMMENT ON FUNCTION private.r5_broadcast_notification_inserted() IS
  'R5 trigger-only: AFTER INSERT on public.notifications, emit private '
  'notification_inserted invalidation on user:<user_id>:notifications. '
  'Payload is notification_id only.';

REVOKE ALL ON FUNCTION private.r5_broadcast_notification_inserted() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.r5_broadcast_notification_inserted() FROM anon;
REVOKE ALL ON FUNCTION private.r5_broadcast_notification_inserted() FROM authenticated;
REVOKE ALL ON FUNCTION private.r5_broadcast_notification_inserted() FROM service_role;


CREATE TRIGGER r5_broadcast_notification_inserted
  AFTER INSERT ON public.notifications
  FOR EACH ROW
  EXECUTE FUNCTION private.r5_broadcast_notification_inserted();


-- ---------- 5. BOOKING LEAVES CONFIRMED ----------

CREATE OR REPLACE FUNCTION private.r5_broadcast_booking_status_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM realtime.send(
    jsonb_build_object(
      'booking_id', NEW.id
    ),
    'booking_status_changed',
    'booking:' || NEW.id::text || ':messages',
    true
  );
  RETURN NULL;
END;
$$;


ALTER FUNCTION private.r5_broadcast_booking_status_changed() OWNER TO postgres;

COMMENT ON FUNCTION private.r5_broadcast_booking_status_changed() IS
  'R5 trigger-only: AFTER UPDATE OF status on public.bookings when '
  'status leaves confirmed, emit private booking_status_changed on '
  'booking:<booking_id>:messages. Payload is booking_id only.';

REVOKE ALL ON FUNCTION private.r5_broadcast_booking_status_changed() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.r5_broadcast_booking_status_changed() FROM anon;
REVOKE ALL ON FUNCTION private.r5_broadcast_booking_status_changed() FROM authenticated;
REVOKE ALL ON FUNCTION private.r5_broadcast_booking_status_changed() FROM service_role;


CREATE TRIGGER r5_broadcast_booking_status_changed
  AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW
  WHEN (
    OLD.status = 'confirmed'
    AND NEW.status IS DISTINCT FROM OLD.status
  )
  EXECUTE FUNCTION private.r5_broadcast_booking_status_changed();
