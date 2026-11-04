-- MOD-01: Administrator ban and reinstate for Worker and Client accounts.
--
-- A ban is the same account state as the FT-05 third-strike suspension
-- (public.users.is_active = false), so every existing inactive-account rule,
-- the /blocked screen and the FT-06 eligibility invalidation apply unchanged.
-- A ban lasts until an Administrator reinstates the account. Reinstating a
-- Worker resets their no-show strikes to 0 (owner decision 2026-11-03).
-- Every change is recorded in private.account_moderation_events, a
-- private-schema object like private.booking_calls: it is not a public
-- application table, so the D-001 public table count stays 13.
-- Existing RPC payloads (get_admin_user_detail) are NOT changed: shipped app
-- parsers require their exact key sets.


-- ---------- 1. NOTIFICATION TYPE DOMAIN ----------

ALTER TABLE public.notifications
  DROP CONSTRAINT notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (
    (type)::text = ANY (
      ARRAY[
        'booking_request'::character varying,
        'booking_confirmed'::character varying,
        'booking_cancelled'::character varying,
        'booking_completed'::character varying,
        'no_show_strike'::character varying,
        'account_suspended'::character varying,
        'account_reinstated'::character varying,
        'payment_received'::character varying,
        'worker_verified'::character varying,
        'report_submitted'::character varying
      ]::text[]
    )
  );


-- ---------- 2. AUDIT TRAIL ----------

CREATE TABLE private.account_moderation_events (
  -- Identity, not a random uuid: it orders events written in one transaction.
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('ban', 'reinstate')),
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 1 AND 500),
  actor_id uuid REFERENCES public.users (id) ON DELETE SET NULL,
  strike_count_before integer CHECK (strike_count_before IS NULL OR strike_count_before BETWEEN 0 AND 3),
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE private.account_moderation_events IS
  'MOD-01: append-only record of Administrator bans and reinstatements. Written only by admin_set_account_banned; read only through get_admin_account_moderation. No direct table access for any client role.';

CREATE INDEX account_moderation_events_user_created_idx
  ON private.account_moderation_events (user_id, id DESC);

ALTER TABLE private.account_moderation_events ENABLE ROW LEVEL SECURITY;
-- No policies: with RLS on and every grant revoked, only postgres-owned
-- SECURITY DEFINER functions can read or write the table. Role-by-role
-- revocation because schema private grants to roles by name (GAP-004).
REVOKE ALL ON TABLE private.account_moderation_events FROM PUBLIC;
REVOKE ALL ON TABLE private.account_moderation_events FROM anon;
REVOKE ALL ON TABLE private.account_moderation_events FROM authenticated;
REVOKE ALL ON TABLE private.account_moderation_events FROM service_role;


-- ---------- 3. BAN / REINSTATE ----------

CREATE FUNCTION public.admin_set_account_banned(
  p_user_id uuid,
  p_banned boolean,
  p_reason text
)
RETURNS TABLE (
  user_id uuid,
  is_active boolean,
  strike_count integer,
  changed boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_reason text;
  v_profile_id uuid;
  v_strikes integer;
  v_role text;
  v_was_active boolean;
  v_changed boolean := false;
BEGIN
  IF v_caller IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to moderate accounts'
      USING ERRCODE = '42501';
  END IF;

  IF p_user_id IS NULL OR p_banned IS NULL THEN
    RAISE EXCEPTION 'invalid moderation arguments'
      USING ERRCODE = '22023';
  END IF;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  IF v_reason IS NULL OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'reason must be between 1 and 500 characters'
      USING ERRCODE = '22023';
  END IF;

  -- Lock order matches FT-05 resolve_no_show_report_with_strike
  -- (worker profile, then user) so the two can never deadlock.
  SELECT wp.id, wp.strike_count
    INTO v_profile_id, v_strikes
  FROM public.worker_profiles AS wp
  WHERE wp.user_id = p_user_id
  FOR UPDATE;

  SELECT u.role::text, u.is_active IS TRUE
    INTO v_role, v_was_active
  FROM public.users AS u
  WHERE u.id = p_user_id
  FOR UPDATE;

  -- Administrators (including the caller) are never moderated here.
  IF NOT FOUND OR v_role NOT IN ('worker', 'client') OR p_user_id = v_caller THEN
    RAISE EXCEPTION 'this account is not available for moderation'
      USING ERRCODE = 'SM409';
  END IF;

  IF p_banned THEN
    IF v_was_active THEN
      UPDATE public.users AS u SET is_active = false WHERE u.id = p_user_id;
      INSERT INTO private.account_moderation_events (user_id, action, reason, actor_id, strike_count_before)
      VALUES (p_user_id, 'ban', v_reason, v_caller, v_strikes);
      PERFORM private.emit_notification(
        p_user_id,
        'account_suspended',
        'An Administrator suspended your account. Reason: ' || v_reason
      );
      v_changed := true;
    END IF;
  ELSE
    -- Only a suspended account is reinstated, and reinstating clears a
    -- Worker's no-show strikes. An active account's strikes are untouched.
    IF NOT v_was_active THEN
      UPDATE public.users AS u SET is_active = true WHERE u.id = p_user_id;
      IF v_profile_id IS NOT NULL AND v_strikes IS DISTINCT FROM 0 THEN
        UPDATE public.worker_profiles AS wp SET strike_count = 0 WHERE wp.id = v_profile_id;
      END IF;
      INSERT INTO private.account_moderation_events (user_id, action, reason, actor_id, strike_count_before)
      VALUES (p_user_id, 'reinstate', v_reason, v_caller, v_strikes);
      PERFORM private.emit_notification(
        p_user_id,
        'account_reinstated',
        CASE WHEN v_role = 'worker'
          THEN 'An Administrator reinstated your account. Your no-show strikes were reset to 0.'
          ELSE 'An Administrator reinstated your account.'
        END
      );
      v_changed := true;
    END IF;
  END IF;

  RETURN QUERY
  SELECT u.id, u.is_active IS TRUE, wp.strike_count, v_changed
  FROM public.users AS u
  LEFT JOIN public.worker_profiles AS wp ON wp.user_id = u.id
  WHERE u.id = p_user_id;
END;
$$;

COMMENT ON FUNCTION public.admin_set_account_banned(uuid, boolean, text) IS
  'MOD-01: active-Administrator-only ban (is_active -> false) or reinstate (suspended account only: is_active -> true, Worker strikes -> 0) of one Worker or Client account, with a required 1-500 character reason. Never moderates an Administrator or the caller. Idempotent: an account already in the requested state is returned with changed = false and no event or notification. Locks worker profile then user, matching FT-05. Writes one audit event and one notification per change; a notification failure rolls back every write.';

ALTER FUNCTION public.admin_set_account_banned(uuid, boolean, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.admin_set_account_banned(uuid, boolean, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_account_banned(uuid, boolean, text) TO authenticated;


-- ---------- 4. ADMINISTRATOR READ ----------

CREATE FUNCTION public.get_admin_account_moderation(p_user_id uuid)
RETURNS TABLE (
  is_active boolean,
  strike_count integer,
  last_action text,
  last_reason text,
  last_action_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to read account moderation'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users AS u
    WHERE u.id = p_user_id AND u.role::text IN ('worker', 'client')
  ) THEN
    RAISE EXCEPTION 'this account is not available'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT
    u.is_active IS TRUE,
    wp.strike_count,
    e.action,
    e.reason,
    e.created_at
  FROM public.users AS u
  LEFT JOIN public.worker_profiles AS wp ON wp.user_id = u.id
  LEFT JOIN LATERAL (
    SELECT ev.action, ev.reason, ev.created_at
    FROM private.account_moderation_events AS ev
    WHERE ev.user_id = u.id
    ORDER BY ev.id DESC
    LIMIT 1
  ) AS e ON true
  WHERE u.id = p_user_id;
END;
$$;

COMMENT ON FUNCTION public.get_admin_account_moderation(uuid) IS
  'MOD-01: active-Administrator-only read of one Worker or Client account: active state, Worker strike count (NULL for Clients and Workers without a profile) and the latest ban/reinstate with its reason. Missing or Administrator accounts are SM409. No writes.';

ALTER FUNCTION public.get_admin_account_moderation(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_admin_account_moderation(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_admin_account_moderation(uuid) TO authenticated;
