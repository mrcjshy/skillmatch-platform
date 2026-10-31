-- ============================================================
-- RF-02 — Booking-scoped video call state (D-011, 2026-10-14)
-- ============================================================
--
-- Call state is authoritative here; the media provider (LiveKit, candidate)
-- carries audio/video only. Provider webhooks and queued pg_net requests
-- are HINTS, never proof that a provider action happened.
--
-- One identity per call: call_id, and room_name derived from it. A call
-- row is created BEFORE any provider request, so a lost or ambiguous
-- provider response can always be reconciled by room name.
--
-- Two authorization families, deliberately separate:
--   * participant operations (rf02_start, rf02_act, rf02_current) take the
--     acting user id from the Edge Function, which resolved it from the
--     caller's JWT, and re-check participant/active/confirmed state;
--   * maintenance operations (provisioning result, invite claim, presence,
--     reconcile batch, cleanup marks, recovery) are service-role only and
--     do NOT require the Booking to be confirmed or accounts to be active,
--     so cleanup still works after termination or deactivation.
-- Every function is EXECUTE-granted to service_role only (no PUBLIC,
-- anon or authenticated) and is called only by Edge Functions.
--
-- Provisioning results (server-only, rf02_record_provisioning):
--   'ready'    provider confirmed the room exists.
--   'rejected' definitive provider refusal: the call fails.
--   'unknown'  timeout / 5xx / network: retried, never treated as failure
--              or success. A late 'ready' on an already-terminal call keeps
--              the call terminal and its cleanup pending.
--
-- Cleanup: terminal calls move to cleanup_state 'pending'. 'confirmed' is set
-- only through rf02_mark_cleanup(ok => true) after provider-confirmed
-- revocation + deletion. Retry exhaustion leaves 'failed' with the room
-- name retained; rf02_retry_failed_cleanup is the recovery path.
-- Confirmed rows are purged 7 days later; failed rows are never purged.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;


-- ---------- 1. TABLE ----------

CREATE TABLE private.booking_calls (
  call_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id           uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  caller_id            uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  callee_id            uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  room_name            text GENERATED ALWAYS AS ('call_' || call_id::text) STORED,
  state                text NOT NULL DEFAULT 'ringing',
  end_reason           text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  ring_expires_at      timestamptz NOT NULL DEFAULT now() + interval '45 seconds',
  answered_at          timestamptz,
  ended_at             timestamptz,
  provision_state      text NOT NULL DEFAULT 'pending',
  provision_attempts   integer NOT NULL DEFAULT 0,
  provisioned_at       timestamptz,
  invite_sent_at       timestamptz,
  caller_away_since    timestamptz,
  callee_away_since    timestamptz,
  cleanup_state        text NOT NULL DEFAULT 'none',
  cleanup_attempts     integer NOT NULL DEFAULT 0,
  next_cleanup_at      timestamptz,
  cleanup_confirmed_at timestamptz,
  last_reconciled_at   timestamptz,
  CONSTRAINT booking_calls_state_chk CHECK (state IN
    ('ringing', 'accepted', 'declined', 'cancelled', 'missed', 'ended', 'failed')),
  CONSTRAINT booking_calls_end_reason_chk CHECK (end_reason IS NULL OR end_reason IN
    ('declined', 'cancelled', 'missed', 'hung_up', 'abandoned', 'max_duration',
     'booking_ended', 'account_inactive', 'provider_rejected')),
  CONSTRAINT booking_calls_provision_chk CHECK (provision_state IN
    ('pending', 'ready', 'rejected', 'unknown')),
  CONSTRAINT booking_calls_cleanup_chk CHECK (cleanup_state IN
    ('none', 'pending', 'confirmed', 'failed')),
  CONSTRAINT booking_calls_distinct_parties_chk CHECK (caller_id <> callee_id),
  CONSTRAINT booking_calls_terminal_chk CHECK (
    (state IN ('ringing', 'accepted')) = (ended_at IS NULL)
    AND (state IN ('ringing', 'accepted')) = (cleanup_state = 'none')
  )
);

-- One authoritative active call per Booking.
CREATE UNIQUE INDEX booking_calls_one_active_idx
  ON private.booking_calls (booking_id)
  WHERE state IN ('ringing', 'accepted');

CREATE INDEX booking_calls_cleanup_due_idx
  ON private.booking_calls (next_cleanup_at)
  WHERE cleanup_state = 'pending';

ALTER TABLE private.booking_calls ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.booking_calls FROM PUBLIC;
REVOKE ALL ON TABLE private.booking_calls FROM anon;
REVOKE ALL ON TABLE private.booking_calls FROM authenticated;
REVOKE ALL ON TABLE private.booking_calls FROM service_role;

COMMENT ON TABLE private.booking_calls IS
  'RF-02 / D-011: authoritative one-to-one call state for confirmed Bookings. '
  'No media, no recording. Service-role RPCs only.';


-- ---------- 2. VIEW SHAPE ----------

CREATE OR REPLACE FUNCTION private.rf02_view(p_call private.booking_calls, p_actor uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'call_id', p_call.call_id,
    'booking_id', p_call.booking_id,
    'room_name', p_call.room_name,
    'caller_id', p_call.caller_id,
    'callee_id', p_call.callee_id,
    'role', CASE WHEN p_actor = p_call.caller_id THEN 'caller' ELSE 'callee' END,
    'state', p_call.state,
    'end_reason', p_call.end_reason,
    'ring_expires_at', p_call.ring_expires_at,
    'answered_at', p_call.answered_at,
    'ended_at', p_call.ended_at,
    'provision_state', p_call.provision_state,
    'provision_attempts', p_call.provision_attempts,
    'counterpart_away', CASE WHEN p_actor = p_call.caller_id
      THEN p_call.callee_away_since IS NOT NULL ELSE p_call.caller_away_since IS NOT NULL END,
    'server_now', now()
  );
$$;


-- ---------- 3. TERMINAL HELPER (single place that ends a call) ----------

CREATE OR REPLACE FUNCTION private.rf02_finish(p_call_id uuid, p_state text, p_reason text)
RETURNS private.booking_calls
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row private.booking_calls;
BEGIN
  UPDATE private.booking_calls AS c
  SET state = p_state,
      end_reason = p_reason,
      ended_at = now(),
      cleanup_state = 'pending',
      next_cleanup_at = now()
  WHERE c.call_id = p_call_id
    AND c.state IN ('ringing', 'accepted')
  RETURNING c.* INTO v_row;
  RETURN v_row;  -- NULL when the call was already terminal
END;
$$;


-- ---------- 4. PARTICIPANT AUTHORIZATION ----------
-- Locks actor + counterpart users rows and the Booking FOR SHARE so a
-- concurrent termination cannot interleave with a start/accept/rejoin.

CREATE OR REPLACE FUNCTION private.rf02_authorize_live(p_actor uuid, p_booking_id uuid)
RETURNS uuid  -- counterpart user id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
  v_worker uuid;
  v_client uuid;
  v_other  uuid;
  v_active int;
BEGIN
  IF p_actor IS NULL OR p_booking_id IS NULL THEN
    RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT b.status, b.worker_id, b.client_id INTO v_status, v_worker, v_client
  FROM public.bookings AS b WHERE b.id = p_booking_id FOR SHARE;
  IF NOT FOUND OR v_status IS DISTINCT FROM 'confirmed'
     OR p_actor IS DISTINCT FROM v_worker AND p_actor IS DISTINCT FROM v_client THEN
    RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
  END IF;
  v_other := CASE WHEN p_actor = v_worker THEN v_client ELSE v_worker END;
  SELECT count(*) INTO v_active FROM (
    SELECT 1 FROM public.users AS u
    WHERE u.id IN (p_actor, v_other) AND u.is_active = true
    ORDER BY u.id
    FOR SHARE
  ) AS locked;
  IF v_active <> 2 THEN
    RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN v_other;
END;
$$;


-- ---------- 5. START (participant) ----------
-- Returns {created, call}. Concurrent starts converge on one row through the
-- partial unique index. A retried start returns the same call with
-- created = false, so the Edge Function does not resend the invitation.

CREATE OR REPLACE FUNCTION private.rf02_start(p_actor uuid, p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_other uuid;
  v_row   private.booking_calls;
BEGIN
  v_other := private.rf02_authorize_live(p_actor, p_booking_id);

  -- An expired ringing call must not block a new one.
  PERFORM private.rf02_finish(c.call_id, 'missed', 'missed')
  FROM private.booking_calls AS c
  WHERE c.booking_id = p_booking_id AND c.state = 'ringing' AND c.ring_expires_at <= now();

  INSERT INTO private.booking_calls (booking_id, caller_id, callee_id)
  VALUES (p_booking_id, p_actor, v_other)
  ON CONFLICT (booking_id) WHERE state IN ('ringing', 'accepted') DO NOTHING
  RETURNING * INTO v_row;

  IF v_row.call_id IS NOT NULL THEN
    RETURN jsonb_build_object('created', true, 'call', private.rf02_view(v_row, p_actor));
  END IF;

  SELECT * INTO v_row FROM private.booking_calls AS c
  WHERE c.booking_id = p_booking_id AND c.state IN ('ringing', 'accepted');
  RETURN jsonb_build_object('created', false, 'call', private.rf02_view(v_row, p_actor));
END;
$$;


-- ---------- 6. ACT (participant) ----------
-- Actions and who may take them:
--   accept  callee  ringing, before expiry, provision 'ready'
--   decline callee  ringing
--   cancel  caller  ringing
--   end     either  accepted
--   away    either  accepted   (app left the call screen / backgrounded)
--   back    either  accepted   (app returned; clears own away mark)
--   rejoin  either  accepted, live Booking, own away mark within 90 s
-- Returns {ok, reason?, call}. A conflict returns ok = false with the current
-- state; it never raises, so the client can show what actually happened.

CREATE OR REPLACE FUNCTION private.rf02_act(p_actor uuid, p_call_id uuid, p_action text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row     private.booking_calls;
  v_is_caller boolean;
  v_own_away timestamptz;
BEGIN
  IF p_action IS NULL OR p_action NOT IN ('accept', 'decline', 'cancel', 'end', 'away', 'back', 'rejoin') THEN
    RAISE EXCEPTION 'invalid call action' USING ERRCODE = '22023';
  END IF;

  -- Read identity without a row lock, then take the same Booking/users/Call
  -- lock order as start and termination. Re-read under lock before acting.
  SELECT * INTO v_row FROM private.booking_calls AS c WHERE c.call_id = p_call_id;
  IF NOT FOUND OR p_actor IS NULL OR p_actor NOT IN (v_row.caller_id, v_row.callee_id) THEN
    RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_action IN ('accept', 'rejoin') THEN
    PERFORM private.rf02_authorize_live(p_actor, v_row.booking_id);
  END IF;
  SELECT * INTO v_row FROM private.booking_calls AS c WHERE c.call_id = p_call_id FOR UPDATE;
  IF NOT FOUND OR p_actor NOT IN (v_row.caller_id, v_row.callee_id) THEN
    RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
  END IF;
  v_is_caller := p_actor = v_row.caller_id;

  -- Lazy ring expiry.
  IF v_row.state = 'ringing' AND v_row.ring_expires_at <= now() THEN
    v_row := private.rf02_finish(v_row.call_id, 'missed', 'missed');
  END IF;

  IF p_action = 'accept' THEN
    IF v_is_caller THEN
      RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
    END IF;
    IF v_row.state <> 'ringing' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_ringing', 'call', private.rf02_view(v_row, p_actor));
    END IF;
    IF v_row.provision_state <> 'ready' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'provisioning', 'call', private.rf02_view(v_row, p_actor));
    END IF;
    UPDATE private.booking_calls AS c SET state = 'accepted', answered_at = now()
    WHERE c.call_id = v_row.call_id RETURNING c.* INTO v_row;

  ELSIF p_action IN ('decline', 'cancel') THEN
    IF (p_action = 'decline') = v_is_caller THEN
      RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
    END IF;
    IF v_row.state <> 'ringing' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_ringing', 'call', private.rf02_view(v_row, p_actor));
    END IF;
    v_row := private.rf02_finish(v_row.call_id,
      CASE WHEN p_action = 'decline' THEN 'declined' ELSE 'cancelled' END,
      CASE WHEN p_action = 'decline' THEN 'declined' ELSE 'cancelled' END);

  ELSIF p_action = 'end' THEN
    IF v_row.state <> 'accepted' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_active', 'call', private.rf02_view(v_row, p_actor));
    END IF;
    v_row := private.rf02_finish(v_row.call_id, 'ended', 'hung_up');

  ELSIF p_action IN ('away', 'back') THEN
    IF v_row.state <> 'accepted' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_active', 'call', private.rf02_view(v_row, p_actor));
    END IF;
    IF v_is_caller THEN
      UPDATE private.booking_calls AS c
      SET caller_away_since = CASE WHEN p_action = 'away' THEN coalesce(c.caller_away_since, now()) END
      WHERE c.call_id = v_row.call_id RETURNING c.* INTO v_row;
    ELSE
      UPDATE private.booking_calls AS c
      SET callee_away_since = CASE WHEN p_action = 'away' THEN coalesce(c.callee_away_since, now()) END
      WHERE c.call_id = v_row.call_id RETURNING c.* INTO v_row;
    END IF;

  ELSIF p_action = 'rejoin' THEN
    IF v_row.state <> 'accepted' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_active', 'call', private.rf02_view(v_row, p_actor));
    END IF;
    v_own_away := CASE WHEN v_is_caller THEN v_row.caller_away_since ELSE v_row.callee_away_since END;
    IF v_own_away IS NOT NULL AND v_own_away <= now() - interval '90 seconds' THEN
      v_row := private.rf02_finish(v_row.call_id, 'ended', 'abandoned');
      RETURN jsonb_build_object('ok', false, 'reason', 'abandoned', 'call', private.rf02_view(v_row, p_actor));
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'call', private.rf02_view(v_row, p_actor));
END;
$$;


-- ---------- 7. CURRENT (participant read) ----------
-- With a Booking: that Booking's active call, else its most recent call.
-- Without: the actor's incoming ringing calls (for the global incoming host).

CREATE OR REPLACE FUNCTION private.rf02_current(p_actor uuid, p_booking_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row private.booking_calls;
  v_out jsonb;
BEGIN
  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
  END IF;

  -- Lazy ring expiry for anything the actor can see.
  PERFORM private.rf02_finish(c.call_id, 'missed', 'missed')
  FROM private.booking_calls AS c
  WHERE c.state = 'ringing' AND c.ring_expires_at <= now()
    AND p_actor IN (c.caller_id, c.callee_id)
    AND (p_booking_id IS NULL OR c.booking_id = p_booking_id);

  IF p_booking_id IS NULL THEN
    SELECT coalesce(jsonb_agg(private.rf02_view(c, p_actor) ORDER BY c.created_at), '[]'::jsonb)
      INTO v_out
    FROM private.booking_calls AS c
    JOIN public.users AS u ON u.id = p_actor AND u.is_active = true
    JOIN public.bookings AS b ON b.id = c.booking_id AND b.status = 'confirmed'
    WHERE c.callee_id = p_actor AND c.state = 'ringing';
    RETURN jsonb_build_object('incoming', v_out, 'server_now', now());
  END IF;

  PERFORM 1 FROM public.bookings AS b
  WHERE b.id = p_booking_id AND p_actor IN (b.worker_id, b.client_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'call not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM private.booking_calls AS c
  WHERE c.booking_id = p_booking_id AND p_actor IN (c.caller_id, c.callee_id)
  ORDER BY (c.state IN ('ringing', 'accepted')) DESC, c.created_at DESC
  LIMIT 1;
  RETURN jsonb_build_object(
    'call', CASE WHEN v_row.call_id IS NULL THEN NULL ELSE private.rf02_view(v_row, p_actor) END,
    'server_now', now());
END;
$$;


-- ---------- 8. MAINTENANCE (service-role only; no participant checks) ----------

-- Provisioning result. Returns the resulting call row as jsonb.
CREATE OR REPLACE FUNCTION private.rf02_record_provisioning(p_call_id uuid, p_result text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row private.booking_calls;
BEGIN
  IF p_result IS NULL OR p_result NOT IN ('ready', 'rejected', 'unknown') THEN
    RAISE EXCEPTION 'invalid provisioning result' USING ERRCODE = '22023';
  END IF;
  UPDATE private.booking_calls AS c
  SET provision_state = CASE
        WHEN c.provision_state = 'ready' THEN 'ready'   -- never downgrade a confirmed room
        ELSE p_result END,
      provision_attempts = c.provision_attempts + 1,
      provisioned_at = CASE WHEN p_result = 'ready' THEN coalesce(c.provisioned_at, now()) ELSE c.provisioned_at END,
      cleanup_state = CASE WHEN c.state NOT IN ('ringing', 'accepted') AND p_result IN ('ready', 'unknown')
        THEN 'pending' ELSE c.cleanup_state END,
      cleanup_attempts = CASE WHEN c.state NOT IN ('ringing', 'accepted') AND p_result IN ('ready', 'unknown')
        THEN 0 ELSE c.cleanup_attempts END,
      cleanup_confirmed_at = CASE WHEN c.state NOT IN ('ringing', 'accepted') AND p_result IN ('ready', 'unknown')
        THEN NULL ELSE c.cleanup_confirmed_at END,
      next_cleanup_at = CASE WHEN c.state NOT IN ('ringing', 'accepted') AND p_result IN ('ready', 'unknown')
        THEN now() ELSE c.next_cleanup_at END
  WHERE c.call_id = p_call_id
  RETURNING c.* INTO v_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown call' USING ERRCODE = 'P0002';
  END IF;
  -- A definitive rejection fails a still-live call. A terminal call (for
  -- example cancelled during provisioning) stays terminal. Late successful or
  -- ambiguous creation invalidates prior absence confirmation and retries cleanup.
  IF p_result = 'rejected' AND v_row.provision_state = 'rejected' AND v_row.state IN ('ringing', 'accepted') THEN
    v_row := private.rf02_finish(v_row.call_id, 'failed', 'provider_rejected');
  END IF;
  RETURN to_jsonb(v_row);
END;
$$;

-- Atomically claims the single invitation push for a call.
CREATE OR REPLACE FUNCTION private.rf02_claim_invite(p_call_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE private.booking_calls AS c SET invite_sent_at = now()
  WHERE c.call_id = p_call_id AND c.invite_sent_at IS NULL
    AND c.state = 'ringing' AND c.ring_expires_at > now();
  RETURN FOUND;
END;
$$;

-- Callee's active push tokens for a still-ringing call on a live Booking.
CREATE OR REPLACE FUNCTION private.rf02_call_push_targets(p_call_id uuid)
RETURNS TABLE (expo_push_token text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT d.expo_push_token
  FROM private.booking_calls AS c
  JOIN public.bookings AS b ON b.id = c.booking_id AND b.status = 'confirmed'
  JOIN public.users AS u ON u.id = c.callee_id AND u.is_active = true
  JOIN private.user_devices AS d ON d.user_id = c.callee_id AND d.is_active = true
  WHERE c.call_id = p_call_id AND c.state = 'ringing' AND c.ring_expires_at > now();
$$;

-- Provider presence for an accepted call (identities = user ids). Sets or
-- clears each participant's away mark. Returns the call row.
CREATE OR REPLACE FUNCTION private.rf02_record_presence(p_call_id uuid, p_present uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row private.booking_calls;
BEGIN
  UPDATE private.booking_calls AS c
  SET caller_away_since = CASE WHEN c.caller_id = ANY (coalesce(p_present, '{}')) THEN NULL
                               ELSE coalesce(c.caller_away_since, now()) END,
      callee_away_since = CASE WHEN c.callee_id = ANY (coalesce(p_present, '{}')) THEN NULL
                               ELSE coalesce(c.callee_away_since, now()) END,
      last_reconciled_at = now()
  WHERE c.call_id = p_call_id AND c.state = 'accepted'
  RETURNING c.* INTO v_row;
  RETURN to_jsonb(v_row);
END;
$$;

-- Expire/abandon/cap, purge, and hand back the work list.
CREATE OR REPLACE FUNCTION private.rf02_reconcile_batch(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
BEGIN
  PERFORM private.rf02_finish(c.call_id, 'missed', 'missed')
  FROM private.booking_calls AS c
  WHERE c.state = 'ringing' AND c.ring_expires_at <= now();

  PERFORM private.rf02_finish(c.call_id, 'ended', 'abandoned')
  FROM private.booking_calls AS c
  WHERE c.state = 'accepted'
    AND (c.caller_away_since <= now() - interval '90 seconds'
         OR c.callee_away_since <= now() - interval '90 seconds');

  PERFORM private.rf02_finish(c.call_id, 'ended', 'max_duration')
  FROM private.booking_calls AS c
  WHERE c.state = 'accepted' AND c.answered_at <= now() - interval '60 minutes';

  DELETE FROM private.booking_calls AS c
  WHERE c.cleanup_state = 'confirmed' AND c.cleanup_confirmed_at < now() - interval '7 days';

  RETURN jsonb_build_object(
    'presence', coalesce((
      SELECT jsonb_agg(jsonb_build_object('call_id', c.call_id, 'room_name', c.room_name,
                                          'caller_id', c.caller_id, 'callee_id', c.callee_id))
      FROM (SELECT * FROM private.booking_calls WHERE state = 'accepted'
            ORDER BY last_reconciled_at NULLS FIRST LIMIT v_limit) AS c), '[]'::jsonb),
    'provisioning', coalesce((
      SELECT jsonb_agg(jsonb_build_object('call_id', c.call_id, 'room_name', c.room_name))
      FROM (SELECT * FROM private.booking_calls
            WHERE state = 'ringing' AND provision_state IN ('pending', 'unknown')
              AND created_at <= now() - interval '5 seconds'
            ORDER BY created_at LIMIT v_limit) AS c), '[]'::jsonb),
    'cleanup', coalesce((
      SELECT jsonb_agg(jsonb_build_object('call_id', c.call_id, 'room_name', c.room_name,
                                          'caller_id', c.caller_id, 'callee_id', c.callee_id,
                                          'provision_attempts', c.provision_attempts))
      FROM (SELECT * FROM private.booking_calls
            WHERE cleanup_state = 'pending' AND next_cleanup_at <= now()
            ORDER BY next_cleanup_at LIMIT v_limit) AS c), '[]'::jsonb),
    'server_now', now()
  );
END;
$$;

-- Cleanup outcome. ok => provider-confirmed revocation + deletion.
-- Backoff 1, 2, 4, 8, 15, 15, 15, 15 minutes; then 'failed' (retained).
CREATE OR REPLACE FUNCTION private.rf02_mark_cleanup(
  p_call_id uuid, p_ok boolean, p_provision_attempts integer DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_state text;
BEGIN
  UPDATE private.booking_calls AS c
  SET cleanup_state = CASE
        WHEN p_ok THEN 'confirmed'
        WHEN c.cleanup_attempts + 1 >= 8 THEN 'failed'
        ELSE 'pending' END,
      cleanup_attempts = c.cleanup_attempts + CASE WHEN p_ok THEN 0 ELSE 1 END,
      cleanup_confirmed_at = CASE WHEN p_ok THEN now() END,
      next_cleanup_at = CASE
        WHEN p_ok OR c.cleanup_attempts + 1 >= 8 THEN NULL
        ELSE now() + (ARRAY[1, 2, 4, 8, 15, 15, 15, 15])[c.cleanup_attempts + 1] * interval '1 minute' END
  WHERE c.call_id = p_call_id AND c.cleanup_state = 'pending'
    -- The provider observation must postdate the latest provisioning outcome.
    -- If creation completed while cleanup ran, leave its newly pending work.
    AND (p_ok IS NOT TRUE OR c.provision_attempts = p_provision_attempts)
  RETURNING c.cleanup_state INTO v_state;
  IF v_state IS NULL AND p_ok IS TRUE AND EXISTS (
    SELECT 1 FROM private.booking_calls AS c WHERE c.call_id = p_call_id AND c.cleanup_state = 'pending'
  ) THEN
    RETURN 'stale_provisioning';
  END IF;
  RETURN coalesce(v_state, 'not_pending');
END;
$$;

-- Owner/operator recovery after retry exhaustion.
CREATE OR REPLACE FUNCTION private.rf02_retry_failed_cleanup(p_call_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE private.booking_calls AS c
  SET cleanup_state = 'pending', cleanup_attempts = 0, next_cleanup_at = now()
  WHERE c.call_id = p_call_id AND c.cleanup_state = 'failed';
  RETURN FOUND;
END;
$$;

-- Look up a call by provider room name (webhook hints).
CREATE OR REPLACE FUNCTION private.rf02_call_by_room(p_room_name text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.call_id FROM private.booking_calls AS c WHERE c.room_name = p_room_name;
$$;


-- ---------- 9. PUBLIC ENTRY POINTS FOR EDGE FUNCTIONS ----------
-- PostgREST exposes only `public`, so thin service-role-only wrappers live
-- there. They add no logic.

CREATE OR REPLACE FUNCTION public.rf02_call_start(p_actor uuid, p_booking_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_start(p_actor, p_booking_id); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_act(p_actor uuid, p_call_id uuid, p_action text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_act(p_actor, p_call_id, p_action); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_current(p_actor uuid, p_booking_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_current(p_actor, p_booking_id); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_record_provisioning(p_call_id uuid, p_result text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_record_provisioning(p_call_id, p_result); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_claim_invite(p_call_id uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_claim_invite(p_call_id); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_push_targets(p_call_id uuid)
RETURNS TABLE (expo_push_token text) LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT t.expo_push_token FROM private.rf02_call_push_targets(p_call_id) AS t; $$;

CREATE OR REPLACE FUNCTION public.rf02_call_record_presence(p_call_id uuid, p_present uuid[])
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_record_presence(p_call_id, p_present); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_reconcile_batch(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_reconcile_batch(p_limit); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_mark_cleanup(
  p_call_id uuid, p_ok boolean, p_provision_attempts integer DEFAULT NULL
)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_mark_cleanup(p_call_id, p_ok, p_provision_attempts); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_retry_failed_cleanup(p_call_id uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_retry_failed_cleanup(p_call_id); $$;

CREATE OR REPLACE FUNCTION public.rf02_call_by_room(p_room_name text)
RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT private.rf02_call_by_room(p_room_name); $$;


-- ---------- 10. TERMINATION TRIGGERS + FAST-PATH DISPATCH ----------

-- Best-effort POST to booking-call-reconcile. Missing Vault config or pg_net
-- failure never rolls back the business write; the 1-minute schedule is the
-- fallback. A queued request is NOT proof of provider cleanup.
CREATE OR REPLACE FUNCTION private.rf02_dispatch_reconcile(p_call_id uuid DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_endpoint text;
  v_secret   text;
BEGIN
  SELECT ds.decrypted_secret INTO v_endpoint
  FROM vault.decrypted_secrets AS ds WHERE ds.name = 'rf02_call_reconcile_endpoint' LIMIT 1;
  SELECT ds.decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets AS ds WHERE ds.name = 'rf02_call_reconcile_secret' LIMIT 1;
  IF v_endpoint IS NULL OR btrim(v_endpoint) = '' OR v_secret IS NULL OR btrim(v_secret) = '' THEN
    RAISE WARNING 'RF-02 call reconcile dispatch skipped: vault config missing';
    RETURN;
  END IF;
  BEGIN
    PERFORM net.http_post(
      url := btrim(v_endpoint),
      body := CASE WHEN p_call_id IS NULL THEN jsonb_build_object('tick', true)
                   ELSE jsonb_build_object('call_id', p_call_id) END,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-skillmatch-dispatch-secret', v_secret),
      timeout_milliseconds := 5000
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'RF-02 call reconcile dispatch request failed';
  END;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'RF-02 call reconcile dispatch failed open';
END;
$$;

CREATE OR REPLACE FUNCTION private.rf02_end_calls_for_booking()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_call uuid;
BEGIN
  FOR v_call IN
    SELECT c.call_id FROM private.booking_calls AS c
    WHERE c.booking_id = NEW.id AND c.state IN ('ringing', 'accepted')
  LOOP
    PERFORM private.rf02_finish(v_call, 'ended', 'booking_ended');
    PERFORM private.rf02_dispatch_reconcile(v_call);
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION private.rf02_end_calls_for_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_call uuid;
BEGIN
  FOR v_call IN
    SELECT c.call_id FROM private.booking_calls AS c
    WHERE NEW.id IN (c.caller_id, c.callee_id) AND c.state IN ('ringing', 'accepted')
  LOOP
    PERFORM private.rf02_finish(v_call, 'ended', 'account_inactive');
    PERFORM private.rf02_dispatch_reconcile(v_call);
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE TRIGGER rf02_end_calls_for_booking
  AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM 'confirmed')
  EXECUTE FUNCTION private.rf02_end_calls_for_booking();

CREATE TRIGGER rf02_end_calls_for_user
  AFTER UPDATE OF is_active ON public.users
  FOR EACH ROW
  WHEN (NEW.is_active IS DISTINCT FROM true)
  EXECUTE FUNCTION private.rf02_end_calls_for_user();


-- ---------- 11. IDS-ONLY INVALIDATION ON BOTH USER TOPICS ----------

CREATE OR REPLACE FUNCTION private.rf02_broadcast_call_state()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payload jsonb := jsonb_build_object('booking_id', NEW.booking_id, 'call_id', NEW.call_id);
BEGIN
  PERFORM realtime.send(v_payload, 'call_state_changed',
    'user:' || NEW.caller_id::text || ':notifications', true);
  PERFORM realtime.send(v_payload, 'call_state_changed',
    'user:' || NEW.callee_id::text || ':notifications', true);
  RETURN NULL;
END;
$$;

CREATE TRIGGER rf02_broadcast_call_state
  AFTER INSERT OR UPDATE OF state, provision_state, caller_away_since, callee_away_since
  ON private.booking_calls
  FOR EACH ROW
  EXECUTE FUNCTION private.rf02_broadcast_call_state();


-- ---------- 12. EFFECTIVE PRIVILEGES ----------
-- Revoke inherited PUBLIC EXECUTE everywhere. Public wrappers: service_role only.
-- Private functions: no client or service role (reached via definer wrappers).

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'private.rf02_view(private.booking_calls, uuid)',
    'private.rf02_finish(uuid, text, text)',
    'private.rf02_authorize_live(uuid, uuid)',
    'private.rf02_start(uuid, uuid)',
    'private.rf02_act(uuid, uuid, text)',
    'private.rf02_current(uuid, uuid)',
    'private.rf02_record_provisioning(uuid, text)',
    'private.rf02_claim_invite(uuid)',
    'private.rf02_call_push_targets(uuid)',
    'private.rf02_record_presence(uuid, uuid[])',
    'private.rf02_reconcile_batch(integer)',
    'private.rf02_mark_cleanup(uuid, boolean, integer)',
    'private.rf02_retry_failed_cleanup(uuid)',
    'private.rf02_call_by_room(text)',
    'private.rf02_dispatch_reconcile(uuid)',
    'private.rf02_end_calls_for_booking()',
    'private.rf02_end_calls_for_user()',
    'private.rf02_broadcast_call_state()'
  ] LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO postgres', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role', f);
  END LOOP;

  FOREACH f IN ARRAY ARRAY[
    'public.rf02_call_start(uuid, uuid)',
    'public.rf02_call_act(uuid, uuid, text)',
    'public.rf02_call_current(uuid, uuid)',
    'public.rf02_call_record_provisioning(uuid, text)',
    'public.rf02_call_claim_invite(uuid)',
    'public.rf02_call_push_targets(uuid)',
    'public.rf02_call_record_presence(uuid, uuid[])',
    'public.rf02_call_reconcile_batch(integer)',
    'public.rf02_call_mark_cleanup(uuid, boolean, integer)',
    'public.rf02_call_retry_failed_cleanup(uuid)',
    'public.rf02_call_by_room(text)'
  ] LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO postgres', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END;
$$;


-- ---------- 13. SCHEDULE (activation hosted-gated) ----------
-- Locally there are no rf02 Vault secrets, so each tick only logs a warning
-- and reaches no external service.

SELECT cron.schedule(
  'rf02-call-reconcile',
  '* * * * *',
  'SELECT private.rf02_dispatch_reconcile(NULL)'
);
