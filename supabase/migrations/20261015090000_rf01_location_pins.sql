-- ============================================================
-- RF-01 — Limited foreground location sharing (Worker–Client pins)
-- ============================================================
--
-- Authority: docs/DECISIONS.md D-002 amendment "RF-L limited foreground
-- location sharing" and R5 "RF-S" (2026-10-14).
--
-- What this adds
--   * private.booking_location_shares — at most ONE current row per
--     (booking, participant). No history. No client grants.
--   * Four authenticated RPCs (start / publish / stop / stop-all) and one
--     read RPC. Every write and read re-authorizes the caller: active
--     account, real Worker/Client of the Booking, Booking 'confirmed'.
--     The caller's users row and the Booking row are locked FOR SHARE so a
--     concurrent cancellation/deactivation cannot interleave with a write:
--     either the write commits first and the termination trigger deletes
--     the row, or the termination commits first and the write is denied.
--   * Same-transaction deletion when the Booking leaves 'confirmed' or the
--     account is deactivated, plus a 5-minute pg_cron purge of expired rows.
--   * Trigger-only ids-only Broadcast `location_pins_changed {booking_id}`
--     on the existing booking:<id>:messages topic (no new policy).
--
-- Lifetimes (kept separate on purpose)
--   * display:  counterpart returned only if received_at >= now() - 10 min;
--               "live" (45 s) vs "last shared" is presentation, client-side.
--   * session:  publish is rejected 'expired' (row deleted) after 10 min with
--               no accepted reading (started_at when nothing was published).
--   * deletion: immediate on stop/termination; expired rows by the purge job
--               (bounded by the 5-minute schedule, not exact) or on access.
--   * backups/logs: deleted rows can persist in platform backups/WAL for the
--               plan's window. Coordinates are never put in RAISE text.
--
-- share_id: returned ONLY by start, to the starting device. It is never
-- returned by any read; reads report my_share as 'yours_active' (the caller
-- presented the current id), 'active_on_other_device' or 'none'.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;


-- ---------- 1. TABLE ----------

CREATE TABLE private.booking_location_shares (
  booking_id       uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  user_id          uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  share_id         uuid NOT NULL,
  last_seq         integer NOT NULL DEFAULT 0,
  latitude         double precision,
  longitude        double precision,
  accuracy_m       real,
  captured_at      timestamptz,
  last_received_at timestamptz,
  started_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (booking_id, user_id),
  CONSTRAINT booking_location_shares_lat_chk CHECK (latitude BETWEEN -90 AND 90),
  CONSTRAINT booking_location_shares_lng_chk CHECK (longitude BETWEEN -180 AND 180),
  CONSTRAINT booking_location_shares_acc_chk CHECK (accuracy_m >= 0 AND accuracy_m <= 5000),
  CONSTRAINT booking_location_shares_reading_chk CHECK (
    (latitude IS NULL) = (longitude IS NULL)
    AND (latitude IS NULL) = (last_received_at IS NULL)
    AND (latitude IS NULL) = (accuracy_m IS NULL)
  )
);

CREATE INDEX booking_location_shares_expiry_idx
  ON private.booking_location_shares (coalesce(last_received_at, started_at));

ALTER TABLE private.booking_location_shares ENABLE ROW LEVEL SECURITY;
-- No policies: only the SECURITY DEFINER functions below touch the table.
REVOKE ALL ON TABLE private.booking_location_shares FROM PUBLIC;
REVOKE ALL ON TABLE private.booking_location_shares FROM anon;
REVOKE ALL ON TABLE private.booking_location_shares FROM authenticated;
REVOKE ALL ON TABLE private.booking_location_shares FROM service_role;

COMMENT ON TABLE private.booking_location_shares IS
  'RF-01: latest shared position per confirmed-Booking participant. No history. '
  'Written only through the RF-01 RPCs; deleted on stop, Booking termination, '
  'deactivation and expiry.';


-- ---------- 2. AUTHORIZATION HELPER ----------
-- Returns the caller's role on the Booking ('worker'|'client') or raises 42501.
-- Locks the caller's users row and the Booking row FOR SHARE (see header).

CREATE OR REPLACE FUNCTION private.rf01_authorize(p_booking_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_active boolean;
  v_status text;
  v_worker uuid;
  v_client uuid;
BEGIN
  IF v_uid IS NULL OR p_booking_id IS NULL THEN
    RAISE EXCEPTION 'location sharing not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT u.is_active INTO v_active
  FROM public.users AS u
  WHERE u.id = v_uid
  FOR SHARE;
  IF v_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'location sharing not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT b.status, b.worker_id, b.client_id
    INTO v_status, v_worker, v_client
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR SHARE;
  IF NOT FOUND OR v_status IS DISTINCT FROM 'confirmed'
     OR v_uid IS DISTINCT FROM v_worker AND v_uid IS DISTINCT FROM v_client THEN
    RAISE EXCEPTION 'location sharing not authorized' USING ERRCODE = '42501';
  END IF;

  RETURN CASE WHEN v_uid = v_worker THEN 'worker' ELSE 'client' END;
END;
$$;

ALTER FUNCTION private.rf01_authorize(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.rf01_authorize(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.rf01_authorize(uuid) FROM anon;
REVOKE ALL ON FUNCTION private.rf01_authorize(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION private.rf01_authorize(uuid) FROM service_role;


-- ---------- 3. START ----------

CREATE OR REPLACE FUNCTION public.start_my_booking_location_share(p_booking_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_share uuid := gen_random_uuid();
BEGIN
  PERFORM private.rf01_authorize(p_booking_id);

  -- A new start on any device replaces the previous session (latest start
  -- wins); the previous device's publishes then return 'not_current'.
  INSERT INTO private.booking_location_shares (booking_id, user_id, share_id)
  VALUES (p_booking_id, auth.uid(), v_share)
  ON CONFLICT (booking_id, user_id) DO UPDATE
    SET share_id = EXCLUDED.share_id,
        last_seq = 0,
        latitude = NULL,
        longitude = NULL,
        accuracy_m = NULL,
        captured_at = NULL,
        last_received_at = NULL,
        started_at = now();

  RETURN v_share;
END;
$$;


-- ---------- 4. PUBLISH ----------
-- Returns 'ok' | 'not_current' | 'expired' | 'stale_seq' | 'throttled'.
-- Invalid input raises 22023 without echoing values.

CREATE OR REPLACE FUNCTION public.publish_my_booking_location(
  p_booking_id  uuid,
  p_share_id    uuid,
  p_seq         integer,
  p_latitude    double precision,
  p_longitude   double precision,
  p_accuracy_m  real,
  p_captured_at timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row private.booking_location_shares%ROWTYPE;
BEGIN
  PERFORM private.rf01_authorize(p_booking_id);

  IF p_share_id IS NULL OR p_seq IS NULL OR p_seq < 1
     OR p_latitude IS NULL OR p_latitude NOT BETWEEN -90 AND 90
     OR p_longitude IS NULL OR p_longitude NOT BETWEEN -180 AND 180
     OR p_accuracy_m IS NULL OR p_accuracy_m < 0 OR p_accuracy_m > 5000
     OR p_latitude = 'NaN'::double precision OR p_longitude = 'NaN'::double precision
     OR p_captured_at IS NULL
     OR p_captured_at > now() + interval '30 seconds'
     OR p_captured_at < now() - interval '2 minutes' THEN
    RAISE EXCEPTION 'invalid location reading' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row
  FROM private.booking_location_shares AS s
  WHERE s.booking_id = p_booking_id AND s.user_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND OR v_row.share_id <> p_share_id THEN
    RETURN 'not_current';
  END IF;

  IF coalesce(v_row.last_received_at, v_row.started_at) < now() - interval '10 minutes' THEN
    DELETE FROM private.booking_location_shares AS s
    WHERE s.booking_id = p_booking_id AND s.user_id = auth.uid();
    RETURN 'expired';
  END IF;

  IF p_seq <= v_row.last_seq THEN
    RETURN 'stale_seq';
  END IF;

  IF v_row.last_received_at IS NOT NULL
     AND v_row.last_received_at > now() - interval '3 seconds' THEN
    RETURN 'throttled';
  END IF;

  UPDATE private.booking_location_shares AS s
  SET last_seq = p_seq,
      latitude = p_latitude,
      longitude = p_longitude,
      accuracy_m = p_accuracy_m,
      captured_at = p_captured_at,
      last_received_at = now()
  WHERE s.booking_id = p_booking_id AND s.user_id = auth.uid();

  RETURN 'ok';
END;
$$;


-- ---------- 5. STOP (this device session) / STOP ALL (every device) ----------
-- Deleting one's own sharing data never requires the Booking to still be
-- confirmed or the account to be active.

CREATE OR REPLACE FUNCTION public.stop_my_booking_location_share(
  p_booking_id uuid,
  p_share_id   uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'location sharing not authorized' USING ERRCODE = '42501';
  END IF;
  DELETE FROM private.booking_location_shares AS s
  WHERE s.booking_id = p_booking_id
    AND s.user_id = auth.uid()
    AND s.share_id = p_share_id;
  RETURN CASE WHEN FOUND THEN 'stopped' ELSE 'not_current' END;
END;
$$;

CREATE OR REPLACE FUNCTION public.stop_all_my_booking_location_shares(p_booking_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'location sharing not authorized' USING ERRCODE = '42501';
  END IF;
  DELETE FROM private.booking_location_shares AS s
  WHERE s.booking_id = p_booking_id AND s.user_id = auth.uid();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


-- ---------- 6. READ ----------

CREATE OR REPLACE FUNCTION public.get_booking_location_pins(
  p_booking_id uuid,
  p_share_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role      text;
  v_my_share  uuid;
  v_other     private.booking_location_shares%ROWTYPE;
  v_found     boolean;
BEGIN
  v_role := private.rf01_authorize(p_booking_id);

  -- Opportunistic cleanup for this Booking (not a deletion guarantee).
  DELETE FROM private.booking_location_shares AS s
  WHERE s.booking_id = p_booking_id
    AND coalesce(s.last_received_at, s.started_at) < now() - interval '10 minutes';

  SELECT s.share_id INTO v_my_share
  FROM private.booking_location_shares AS s
  WHERE s.booking_id = p_booking_id AND s.user_id = auth.uid();

  SELECT s.* INTO v_other
  FROM private.booking_location_shares AS s
  JOIN public.users AS u ON u.id = s.user_id AND u.is_active = true
  WHERE s.booking_id = p_booking_id
    AND s.user_id <> auth.uid()
    AND s.last_received_at IS NOT NULL
    AND s.last_received_at >= now() - interval '10 minutes';
  v_found := FOUND;

  RETURN jsonb_build_object(
    'server_now', now(),
    'lease_expires_at', now() + interval '60 seconds',
    'my_share', CASE
      WHEN v_my_share IS NULL THEN 'none'
      WHEN p_share_id IS NOT NULL AND v_my_share = p_share_id THEN 'yours_active'
      ELSE 'active_on_other_device'
    END,
    'counterpart', CASE WHEN v_found THEN jsonb_build_object(
      'role', CASE WHEN v_role = 'worker' THEN 'client' ELSE 'worker' END,
      'latitude', v_other.latitude,
      'longitude', v_other.longitude,
      'accuracy_m', v_other.accuracy_m,
      'received_at', v_other.last_received_at
    ) END
  );
END;
$$;


-- ---------- 7. RPC OWNERSHIP AND EFFECTIVE PRIVILEGES ----------
-- Revoke the default PUBLIC EXECUTE explicitly, then grant authenticated only.

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.start_my_booking_location_share(uuid)',
    'public.publish_my_booking_location(uuid, uuid, integer, double precision, double precision, real, timestamptz)',
    'public.stop_my_booking_location_share(uuid, uuid)',
    'public.stop_all_my_booking_location_shares(uuid)',
    'public.get_booking_location_pins(uuid, uuid)'
  ] LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO postgres', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
END;
$$;


-- ---------- 8. TERMINATION TRIGGERS (same transaction) ----------

CREATE OR REPLACE FUNCTION private.rf01_purge_booking_shares()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM private.booking_location_shares AS s WHERE s.booking_id = NEW.id;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION private.rf01_purge_user_shares()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM private.booking_location_shares AS s WHERE s.user_id = NEW.id;
  RETURN NULL;
END;
$$;

CREATE TRIGGER rf01_purge_booking_shares
  AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM 'confirmed')
  EXECUTE FUNCTION private.rf01_purge_booking_shares();

CREATE TRIGGER rf01_purge_user_shares
  AFTER UPDATE OF is_active ON public.users
  FOR EACH ROW
  WHEN (NEW.is_active IS DISTINCT FROM true)
  EXECUTE FUNCTION private.rf01_purge_user_shares();


-- ---------- 9. IDS-ONLY INVALIDATION ----------

CREATE OR REPLACE FUNCTION private.rf01_broadcast_pins_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_booking uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.booking_id ELSE NEW.booking_id END;
BEGIN
  PERFORM realtime.send(
    jsonb_build_object('booking_id', v_booking),
    'location_pins_changed',
    'booking:' || v_booking::text || ':messages',
    true
  );
  RETURN NULL;
END;
$$;

CREATE TRIGGER rf01_broadcast_pins_changed
  AFTER INSERT OR UPDATE OR DELETE ON private.booking_location_shares
  FOR EACH ROW
  EXECUTE FUNCTION private.rf01_broadcast_pins_changed();

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'private.rf01_purge_booking_shares()',
    'private.rf01_purge_user_shares()',
    'private.rf01_broadcast_pins_changed()'
  ] LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO postgres', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role', f);
  END LOOP;
END;
$$;


-- ---------- 10. SCHEDULED PURGE (bounded, not exact) ----------

CREATE OR REPLACE FUNCTION private.rf01_purge_expired_shares()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  DELETE FROM private.booking_location_shares AS s
  WHERE coalesce(s.last_received_at, s.started_at) < now() - interval '10 minutes';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

ALTER FUNCTION private.rf01_purge_expired_shares() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.rf01_purge_expired_shares() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.rf01_purge_expired_shares() FROM anon;
REVOKE ALL ON FUNCTION private.rf01_purge_expired_shares() FROM authenticated;
REVOKE ALL ON FUNCTION private.rf01_purge_expired_shares() FROM service_role;

SELECT cron.schedule(
  'rf01-location-share-purge',
  '*/5 * * * *',
  'SELECT private.rf01_purge_expired_shares()'
);
