-- ============================================================
-- RF-04 — Worker-only live location (owner product correction, 2026-10-16)
-- ============================================================
--
-- SkillMatch has two location concepts:
--   1. the job destination the Client pinned when posting the job (fixed,
--      released by the existing job-location RPCs; unchanged here);
--   2. the Worker's live position, shared by the Worker's explicit choice on a
--      confirmed Booking and visible to that Booking's Client.
-- The Client's own GPS is not part of the feature.
--
-- RF-01 let either participant start/publish and returned "the other
-- participant" to each reader, so a Worker could receive a Client position and
-- an obsolete Client build could keep publishing. This migration narrows the
-- three RF-01 RPCs that write or release coordinates:
--   * start_my_booking_location_share  — the Booking's Worker only (else 42501);
--   * publish_my_booking_location      — the Booking's Worker only (else 42501);
--   * get_booking_location_pins        — counterpart is returned only to the
--     Client, and only the Worker's row; a Worker always receives null.
-- Stop / stop-all stay callable by both participants so anyone can delete
-- their own data (an old Client build can still clean up). Any Client rows
-- that exist when this is applied are deleted.
--
-- Unchanged: table, grants, termination triggers, purge job, ids-only
-- broadcast, lifetimes, share_id secrecy. No new tables. CREATE OR REPLACE
-- keeps each function's owner and EXECUTE grants from RF-01; they are
-- re-asserted below anyway.
--
-- GATED: not applied to the hosted project. Requires owner approval of the
-- privacy scope and the hosted-deployment security gate.
-- ============================================================


-- ---------- 1. START: Worker only ----------

CREATE OR REPLACE FUNCTION public.start_my_booking_location_share(p_booking_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_share uuid := gen_random_uuid();
BEGIN
  IF private.rf01_authorize(p_booking_id) IS DISTINCT FROM 'worker' THEN
    RAISE EXCEPTION 'location sharing not authorized' USING ERRCODE = '42501';
  END IF;

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


-- ---------- 2. PUBLISH: Worker only ----------

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
  IF private.rf01_authorize(p_booking_id) IS DISTINCT FROM 'worker' THEN
    RAISE EXCEPTION 'location sharing not authorized' USING ERRCODE = '42501';
  END IF;

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


-- ---------- 3. READ: the Worker's position, to the Client only ----------

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
  v_worker    private.booking_location_shares%ROWTYPE;
  v_found     boolean := false;
BEGIN
  v_role := private.rf01_authorize(p_booking_id);

  -- Opportunistic cleanup for this Booking (not a deletion guarantee).
  DELETE FROM private.booking_location_shares AS s
  WHERE s.booking_id = p_booking_id
    AND coalesce(s.last_received_at, s.started_at) < now() - interval '10 minutes';

  SELECT s.share_id INTO v_my_share
  FROM private.booking_location_shares AS s
  WHERE s.booking_id = p_booking_id AND s.user_id = auth.uid();

  IF v_role = 'client' THEN
    SELECT s.* INTO v_worker
    FROM private.booking_location_shares AS s
    JOIN public.bookings AS b ON b.id = s.booking_id AND b.worker_id = s.user_id
    JOIN public.users AS u ON u.id = s.user_id AND u.is_active = true
    WHERE s.booking_id = p_booking_id
      AND s.last_received_at IS NOT NULL
      AND s.last_received_at >= now() - interval '10 minutes';
    v_found := FOUND;
  END IF;

  RETURN jsonb_build_object(
    'server_now', now(),
    'lease_expires_at', now() + interval '60 seconds',
    'my_share', CASE
      WHEN v_my_share IS NULL THEN 'none'
      WHEN p_share_id IS NOT NULL AND v_my_share = p_share_id THEN 'yours_active'
      ELSE 'active_on_other_device'
    END,
    'counterpart', CASE WHEN v_found THEN jsonb_build_object(
      'role', 'worker',
      'latitude', v_worker.latitude,
      'longitude', v_worker.longitude,
      'accuracy_m', v_worker.accuracy_m,
      'received_at', v_worker.last_received_at
    ) END
  );
END;
$$;


-- ---------- 4. OWNERSHIP AND EFFECTIVE PRIVILEGES (unchanged from RF-01) ----------

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.start_my_booking_location_share(uuid)',
    'public.publish_my_booking_location(uuid, uuid, integer, double precision, double precision, real, timestamptz)',
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


-- ---------- 5. REMOVE EXISTING CLIENT POSITIONS ----------
-- Any Client row (written under RF-01) is deleted now; the broadcast trigger
-- tells open maps to re-read.

DELETE FROM private.booking_location_shares AS s
USING public.bookings AS b
WHERE b.id = s.booking_id
  AND s.user_id IS DISTINCT FROM b.worker_id;
