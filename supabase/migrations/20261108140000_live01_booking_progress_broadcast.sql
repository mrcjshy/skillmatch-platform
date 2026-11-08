-- ============================================================
-- LIVE-01: BOOKING PROGRESS BROADCAST
-- ============================================================
--
-- SCOPE
-- -----
-- Owner request 2026-11-08: the Worker and the Client must see each
-- other's steps live, without pull-to-refresh. Before this migration the
-- Worker's arrival and "Mark as Completed" swipes, the Client's Cash
-- choice and a QR Ph settlement changed public.bookings without any
-- Broadcast or notification, so the other participant's Booking Details
-- stayed stale until a manual refresh.
--
-- This migration adds one trigger-only function and one trigger:
--   AFTER UPDATE OF worker_arrived_at, worker_service_completed_at,
--   payment_method, payment_status, paymongo_ref ON public.bookings,
--   while the Booking is (and stays) confirmed and one of those values
--   really changed, emit the private Broadcast booking_progress_changed
--   on the existing booking:<booking_id>:messages topic.
--
-- The payload is the booking id only (realtime.send may add its own
-- transport id). Clients treat it as an invalidation signal and re-read
-- through the existing participant RPCs, exactly like R5's
-- booking_status_changed.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No realtime.messages policy change: the R5 booking-topic SELECT
--     policy already limits receipt to the confirmed Booking's
--     participants. No authenticated INSERT (send) authority.
--   * No table, column, constraint, RLS, grant or public RPC change.
--     D-001: the public table count stays 13.
--   * No notification row, push or email.
--   * The R5 booking_status_changed trigger is unchanged; a Booking that
--     leaves confirmed is announced by it, not by this trigger.
--
-- ROLLBACK
-- --------
--   DROP TRIGGER IF EXISTS live01_broadcast_booking_progress_changed ON public.bookings;
--   DROP FUNCTION IF EXISTS private.live01_broadcast_booking_progress_changed();
-- ============================================================

CREATE OR REPLACE FUNCTION private.live01_broadcast_booking_progress_changed()
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
    'booking_progress_changed',
    'booking:' || NEW.id::text || ':messages',
    true
  );
  RETURN NULL;
END;
$$;

ALTER FUNCTION private.live01_broadcast_booking_progress_changed() OWNER TO postgres;

COMMENT ON FUNCTION private.live01_broadcast_booking_progress_changed() IS
  'LIVE-01 trigger-only: AFTER UPDATE of the Worker progress or payment columns on a '
  'Booking that stays confirmed, emit private booking_progress_changed on '
  'booking:<booking_id>:messages. Payload is booking_id only.';

REVOKE ALL ON FUNCTION private.live01_broadcast_booking_progress_changed() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.live01_broadcast_booking_progress_changed() FROM anon;
REVOKE ALL ON FUNCTION private.live01_broadcast_booking_progress_changed() FROM authenticated;
REVOKE ALL ON FUNCTION private.live01_broadcast_booking_progress_changed() FROM service_role;

DROP TRIGGER IF EXISTS live01_broadcast_booking_progress_changed ON public.bookings;

CREATE TRIGGER live01_broadcast_booking_progress_changed
  AFTER UPDATE OF worker_arrived_at, worker_service_completed_at, payment_method, payment_status, paymongo_ref
  ON public.bookings
  FOR EACH ROW
  WHEN (
    OLD.status = 'confirmed'
    AND NEW.status = 'confirmed'
    AND (
         OLD.worker_arrived_at IS DISTINCT FROM NEW.worker_arrived_at
      OR OLD.worker_service_completed_at IS DISTINCT FROM NEW.worker_service_completed_at
      OR OLD.payment_method IS DISTINCT FROM NEW.payment_method
      OR OLD.payment_status IS DISTINCT FROM NEW.payment_status
      OR OLD.paymongo_ref IS DISTINCT FROM NEW.paymongo_ref
    )
  )
  EXECUTE FUNCTION private.live01_broadcast_booking_progress_changed();
