-- ============================================================
-- PM-01A-DB-01: QR PH TRUSTED DATABASE BOUNDARY
-- ============================================================
--
-- SCOPE
-- -----
-- The database foundation for the online half of the payment lifecycle,
-- locked by the PM-01 QR Ph amendment in docs/DECISIONS.md (QR-01..QR-15).
--
-- This migration:
--   1. widens bookings_payment_method_check by exactly one value, 'qrph'
--   2. adds public.prepare_booking_qrph()           -- read-only preparation
--   3. adds public.claim_and_bind_booking_qrph()    -- the atomic transition
--   4. adds public.settle_booking_qrph()            -- provider settlement
--
-- It creates no table, column, index, constraint (beyond replacing one
-- CHECK with the same CHECK plus a value), trigger, enum or publication,
-- and it creates and drops no policy. The locked 11-table ERD (D-001) is
-- untouched at 11 tables / 74 columns, and the public policy count stays
-- 24. This IS, however, a live constraint mutation, which is why hosted
-- deployment is gated separately from D-001.
--
-- No existing function body is modified. The COD path, the BL-01A
-- lifecycle path, N9 acceptance, N11 lists, N12 notifications and the
-- BL-01B ratings path are all left exactly as they are.
--
--
-- WHY THESE FUNCTIONS ARE service_role-ONLY
-- -----------------------------------------
-- Every trusted RPC before this piece was granted to `authenticated`,
-- because the app itself was the actor. QR Ph is different: QR-04 locks
-- the Expo client OUT of the provider flow entirely --
--
--     Expo client --(booking_id only)--> Edge Function --> DB / PayMongo
--
-- If these functions were granted to `authenticated`, the app could call
-- them straight through PostgREST and bind, or settle, a Booking without
-- the Edge Function ever running. Settlement in particular must never be
-- reachable by the paying party. So EXECUTE is granted to `service_role`
-- alone and explicitly revoked from PUBLIC, anon and authenticated. A
-- native caller is stopped at the function privilege boundary with 42501,
-- before a single line of body runs.
--
--
-- WHY THE CALLER IDENTITY IS A PARAMETER
-- --------------------------------------
-- private.is_active_client() and private.is_active_worker() both read
-- auth.uid(), which under a service_role call is NULL. Reusing them here
-- would make every call fail closed for the wrong reason. The Edge
-- Function authenticates the JWT, derives the authoritative user id and
-- passes it as p_client_id; the database then INDEPENDENTLY revalidates
-- that id against public.users and against the Booking's client_id.
--
-- To be precise about what that does and does not prove: the database is
-- NOT authenticating the original JWT. It is refusing to act on a client
-- id that is not an active Client, and refusing to touch a Booking that
-- id does not own -- so a bug in the Edge Function still cannot settle an
-- arbitrary Booking.
--
--
-- THE ATOMIC TRANSITION (QR-07, as amended)
-- -----------------------------------------
-- The Payment Intent is created by PM-01B BEFORE any Booking state is
-- committed, and one operation performs the claim and the binding
-- together:
--
--     (NULL,  'pending', NULL)   ->   ('qrph', 'pending', pi_...)
--
-- payment_method and paymongo_ref are written in a SINGLE statement, so
-- no (qrph, pending, NULL) state is ever committed. That matters: such a
-- row would be a Booking claimed for QR Ph with no provider resource and
-- -- under the locked 11-table / 74-column model, which has no durable
-- claim timestamp anywhere -- no safe way to tell an in-flight request
-- from an abandoned one. The state is designed out rather than recovered
-- from.
--
-- A concurrent loser is refused by the same row lock. Its Payment Intent
-- is never attached and becomes an orphan provider resource; it never
-- becomes payable, because attachment happens only against the stored
-- authoritative reference. No cross-system atomicity is claimed.
--
--
-- ERROR TAXONOMY -- REUSED, NOT EXTENDED
-- --------------------------------------
--   42501  caller is not an active Client account
--   SM409  collapsed "not available": wrong Booking, not the caller's,
--          wrong lifecycle state, wrong payment tuple, or a Job whose
--          budget cannot express a payable amount
--   22023  caller-SUPPLIED value is malformed or disagrees with the
--          server's own derivation (reference, currency, amount)
--
-- The split is deliberate: SM409 covers facts the server reads for
-- itself and collapses them so the function is not a Booking-existence
-- oracle; 22023 covers values the Edge Function passed in, where naming
-- the fault leaks nothing and makes a server bug diagnosable.
--
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
-- No PayMongo call and no PayMongo credential -- this piece is pure SQL.
-- No notification: QR-11 locks QR Ph settlement as silent pre-defense,
-- and COD's payment_received behaviour is untouched. No refund, no
-- payment reversal, no method switching after selection (QR-10), no
-- Worker confirmation for QR Ph, no Client mark-paid, no Booking
-- lifecycle write, no Job write, no rating, no message.


-- ---------- 1. PAYMENT METHOD CHECK ----------
--
-- One value added. 'gcash', 'maya' and 'cod' are all retained: gcash and
-- maya are not implemented for the defense, but they remain valid schema
-- values for historical and forward compatibility, and 'cod' is live.
-- 'qrph' is 4 characters against payment_method's varchar(20).
--
-- The table currently holds zero rows, so the replacement validates
-- immediately. Widening a CHECK cannot invalidate existing data in any
-- case: every value the old constraint admitted, the new one admits.

ALTER TABLE public.bookings
  DROP CONSTRAINT bookings_payment_method_check;

ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_payment_method_check
  CHECK (
    (payment_method)::text = ANY (
      (ARRAY['gcash'::character varying,
             'maya'::character varying,
             'qrph'::character varying,
             'cod'::character varying])::text[]
    )
  );


-- ---------- 2. READ-ONLY PREPARATION ----------
--
-- PM-01B calls this first, before it talks to PayMongo, to learn two
-- things it must not decide for itself: whether a new Payment Intent is
-- needed, and how much the payment is for.
--
-- The answer is carried by paymongo_ref in the returned row:
--
--   ref IS NULL      -> FRESH  : create a new Payment Intent
--   ref IS NOT NULL  -> RESUME : reuse the stored Intent, create a new
--                                QR Ph Payment Method and attach it
--
-- RESUME is what makes QR-09 (expiry regenerates the QR, never the
-- Intent) and QR-07's crash-after-bind case recoverable through the same
-- code path.
--
-- (qrph, pending, NULL) is NOT a preparable state. Under the amended
-- QR-07 it cannot be produced by any code path, so encountering one
-- means the data is inconsistent; treating it as resumable would
-- reintroduce exactly the duplicate-Intent hazard the atomic transition
-- removed. It is refused with the collapsed conflict.
--
-- Writes nothing. Emits nothing. Locks nothing -- a lock here would be
-- meaningless, because every decision is re-made under a real lock
-- inside claim_and_bind.

CREATE OR REPLACE FUNCTION public.prepare_booking_qrph(
  p_booking_id uuid,
  p_client_id  uuid
)
RETURNS TABLE (
  booking_id      uuid,
  payment_method  text,
  payment_status  text,
  paymongo_ref    text,
  amount_centavos bigint,
  currency        text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_booking_status text;
  v_booking_client uuid;
  v_job_id         uuid;
  v_pay_method     text;
  v_pay_status     text;
  v_pay_ref        text;
  v_budget         numeric;
  v_centavos       numeric;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (account level)
  --
  -- The Edge Function has already authenticated the JWT; this is the
  -- database refusing to act on an id that is not an active Client.
  ----------------------------------------------------------------
  IF p_client_id IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM public.users AS u
        WHERE u.id = p_client_id
          AND u.role = 'client'
          AND u.is_active = true
     )
  THEN
    RAISE EXCEPTION 'not authorized to prepare qr ph payment'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. READ THE BOOKING
  ----------------------------------------------------------------
  SELECT b.status::text, b.client_id, b.job_id,
         b.payment_method::text, b.payment_status::text, b.paymongo_ref::text
    INTO v_booking_status, v_booking_client, v_job_id,
         v_pay_method, v_pay_status, v_pay_ref
  FROM public.bookings AS b
  WHERE b.id = p_booking_id;

  ----------------------------------------------------------------
  -- 3. MUST EXIST, BE OURS, AND BE COMPLETED
  --
  -- One collapsed error, so this cannot be used to probe which Booking
  -- ids exist or which belong to someone else. 'completed' is required
  -- because payment follows completion (docs/DECISIONS.md, Payment
  -- sequencing).
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM p_client_id
     OR v_booking_status IS DISTINCT FROM 'completed'
  THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. ONLY TWO PREPARABLE TUPLES
  --
  -- FRESH  : nothing chosen yet.
  -- RESUME : already bound to a provider Intent, still unpaid.
  --
  -- Everything else -- cod, gcash, maya, paid, refunded, and the
  -- impossible (qrph, pending, NULL) -- fails closed here.
  ----------------------------------------------------------------
  IF NOT (
       (v_pay_method IS NULL     AND v_pay_status = 'pending' AND v_pay_ref IS NULL)
    OR (v_pay_method = 'qrph'    AND v_pay_status = 'pending' AND v_pay_ref IS NOT NULL)
  )
  THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 5. AUTHORITATIVE AMOUNT
  --
  -- Derived from the Job, never supplied by a caller. job_postings.budget
  -- is numeric(10,2) and NULLABLE with CHECK (budget >= 0), so a NULL
  -- budget and a zero budget are both real cases, not theory -- and
  -- neither can express a payable amount. Arithmetic stays in numeric
  -- throughout; nothing here touches a floating-point type.
  ----------------------------------------------------------------
  SELECT jp.budget
    INTO v_budget
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id;

  IF NOT FOUND OR v_budget IS NULL THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment'
      USING ERRCODE = 'SM409';
  END IF;

  v_centavos := v_budget * 100;

  -- Exact at scale 2, asserted anyway: a future scale change must fail
  -- loudly here rather than silently round somebody's money.
  IF v_centavos <> trunc(v_centavos)
     OR v_centavos < 100                -- PayMongo minimum PHP 1.00
     OR v_centavos > 9999999999         -- numeric(10,2) ceiling in centavos
  THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT p_booking_id, v_pay_method, v_pay_status, v_pay_ref,
         v_centavos::bigint, 'PHP'::text;
END;
$$;

COMMENT ON FUNCTION public.prepare_booking_qrph(uuid, uuid) IS
  'PM-01A: read-only preparation for a QR Ph payment. Requires an active '
  'Client id (42501 otherwise), then that the Booking exists, is that '
  'Client''s and is completed -- all three collapsed into the SAME SM409 '
  'so the function is not a Booking-existence oracle. Returns the payment '
  'tuple plus the authoritative amount in centavos derived from the Job '
  'budget, never from a caller. A NULL paymongo_ref means FRESH (create a '
  'Payment Intent); a non-NULL one means RESUME (reuse the stored Intent). '
  'Every other tuple -- cod, gcash, maya, paid, refunded, and the '
  'impossible (qrph, pending, NULL) -- is refused. Writes nothing and '
  'emits no notification. service_role EXECUTE only.';

ALTER FUNCTION public.prepare_booking_qrph(uuid, uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.prepare_booking_qrph(uuid, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.prepare_booking_qrph(uuid, uuid) FROM anon;

REVOKE ALL ON FUNCTION public.prepare_booking_qrph(uuid, uuid) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.prepare_booking_qrph(uuid, uuid) TO service_role;


-- ---------- 3. ATOMIC CLAIM AND BIND ----------
--
-- The first mutation, and the whole point of the amended QR-07: the
-- Booking is claimed for QR Ph and bound to its Payment Intent in ONE
-- statement inside ONE transaction.
--
-- The caller has already created the Intent. If this operation refuses,
-- that Intent is simply never attached and becomes an orphan -- unpayable,
-- because a QR only exists after attachment, and attachment only ever
-- targets the reference stored here.

CREATE OR REPLACE FUNCTION public.claim_and_bind_booking_qrph(
  p_booking_id      uuid,
  p_client_id       uuid,
  p_intent_id       text,
  p_amount_centavos bigint,
  p_currency        text
)
RETURNS TABLE (
  booking_id      uuid,
  payment_method  text,
  payment_status  text,
  paymongo_ref    text,
  amount_centavos bigint,
  currency        text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_intent_id      text := btrim(coalesce(p_intent_id, ''));
  v_booking_status text;
  v_booking_client uuid;
  v_job_id         uuid;
  v_pay_method     text;
  v_pay_status     text;
  v_pay_ref        text;
  v_budget         numeric;
  v_centavos       numeric;
  v_rows           integer;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER-SUPPLIED VALUE VALIDATION
  --
  -- 22023 rather than SM409: these are values the Edge Function passed
  -- in, so naming the fault leaks nothing about anyone's Booking and
  -- makes a server bug diagnosable. No fixed PayMongo id length is
  -- assumed -- only non-empty, and short enough for paymongo_ref's
  -- varchar(100).
  ----------------------------------------------------------------
  IF v_intent_id = '' OR length(v_intent_id) > 100 THEN
    RAISE EXCEPTION 'invalid payment intent reference'
      USING ERRCODE = '22023';
  END IF;

  IF p_currency IS NULL OR upper(btrim(p_currency)) <> 'PHP' THEN
    RAISE EXCEPTION 'unsupported payment currency'
      USING ERRCODE = '22023';
  END IF;

  IF p_amount_centavos IS NULL OR p_amount_centavos < 100 THEN
    RAISE EXCEPTION 'invalid payment amount'
      USING ERRCODE = '22023';
  END IF;

  ----------------------------------------------------------------
  -- 2. CALLER AUTHORIZATION (account level)
  ----------------------------------------------------------------
  IF p_client_id IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM public.users AS u
        WHERE u.id = p_client_id
          AND u.role = 'client'
          AND u.is_active = true
     )
  THEN
    RAISE EXCEPTION 'not authorized to bind qr ph payment'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 3. LOCK THE BOOKING (lock order step 1)
  --
  -- Every authorization and state fact below is read from the LOCKED
  -- row. This is what serialises two concurrent binds: the loser blocks
  -- here, and the statement it runs after acquiring the lock sees the
  -- winner's committed row and stops at step 4 without writing.
  ----------------------------------------------------------------
  SELECT b.status::text, b.client_id, b.job_id,
         b.payment_method::text, b.payment_status::text, b.paymongo_ref::text
    INTO v_booking_status, v_booking_client, v_job_id,
         v_pay_method, v_pay_status, v_pay_ref
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 4. REQUIRED INITIAL STATE -- EXACTLY ONE TUPLE
  --
  -- Must exist, be the caller's, be completed, and be entirely
  -- unclaimed. Requiring paymongo_ref IS NULL is what guarantees an
  -- existing reference is NEVER replaced: a Booking already bound to
  -- pi_A cannot be re-bound to pi_B by any caller, in any order.
  --
  -- Collapsed into one SM409: a Booking that is already cod, already
  -- qrph, already paid, cancelled or someone else's are all simply
  -- "not available".
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM p_client_id
     OR v_booking_status IS DISTINCT FROM 'completed'
     OR v_pay_method     IS NOT NULL
     OR v_pay_status     IS DISTINCT FROM 'pending'
     OR v_pay_ref        IS NOT NULL
  THEN
    RAISE EXCEPTION 'this booking is not available for qr ph binding'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 5. RE-DERIVE THE AMOUNT UNDER THE LOCK (lock order step 2)
  --
  -- The amount returned by prepare_booking_qrph is NOT trusted: it was
  -- read outside this transaction and the caller could have altered it
  -- in transit. The Job is locked FOR SHARE -- the least restrictive
  -- lock that still prevents the budget changing underneath us -- and
  -- always AFTER the Booking, never inverting the project's fixed
  -- Booking -> Job lock order.
  ----------------------------------------------------------------
  SELECT jp.budget
    INTO v_budget
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id
  FOR SHARE;

  IF NOT FOUND OR v_budget IS NULL THEN
    RAISE EXCEPTION 'this booking is not available for qr ph binding'
      USING ERRCODE = 'SM409';
  END IF;

  v_centavos := v_budget * 100;

  IF v_centavos <> trunc(v_centavos)
     OR v_centavos < 100
     OR v_centavos > 9999999999
  THEN
    RAISE EXCEPTION 'this booking is not available for qr ph binding'
      USING ERRCODE = 'SM409';
  END IF;

  -- The caller's amount must match the server's own derivation exactly.
  IF p_amount_centavos <> v_centavos::bigint THEN
    RAISE EXCEPTION 'payment amount does not match the authoritative job budget'
      USING ERRCODE = '22023';
  END IF;

  ----------------------------------------------------------------
  -- 6. THE ATOMIC TRANSITION
  --
  -- payment_method and paymongo_ref are set in the SAME statement, so
  -- (qrph, pending, NULL) is never committed and never observable.
  -- payment_status is absent from the statement and stays 'pending';
  -- bookings.status, completed_at and every Job column are untouched.
  ----------------------------------------------------------------
  UPDATE public.bookings AS b
     SET payment_method = 'qrph',
         paymongo_ref   = v_intent_id
   WHERE b.id = p_booking_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'this booking is not available for qr ph binding'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT p_booking_id, 'qrph'::text, 'pending'::text, v_intent_id,
         v_centavos::bigint, 'PHP'::text;
END;
$$;

COMMENT ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) IS
  'PM-01A: the atomic QR-07 transition. Requires an active Client id '
  '(42501), a well-formed reference/currency/amount (22023 otherwise), '
  'then -- under a row lock -- that the Booking exists, is the caller''s, '
  'is completed and is entirely unclaimed (NULL method, pending status, '
  'NULL paymongo_ref), all collapsed into one SM409. Sets payment_method '
  '= ''qrph'' AND paymongo_ref in a SINGLE statement, so no '
  '(qrph, pending, NULL) state is ever committed. An existing non-NULL '
  'paymongo_ref is never replaced, which is what makes a concurrent '
  'second bind lose rather than overwrite. The amount is re-derived from '
  'the Job under a FOR SHARE lock and must equal the caller''s value. '
  'Writes no payment_status, no bookings.status, no completed_at and no '
  'Job row, and emits no notification. service_role EXECUTE only.';

ALTER FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) FROM anon;

REVOKE ALL ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) TO service_role;


-- ---------- 4. PROVIDER SETTLEMENT ----------
--
-- The single trusted path from 'pending' to 'paid' for QR Ph. PM-01C
-- calls it from the signature-verified webhook and from server-side
-- reconciliation (QR-14); both are service_role server paths.
--
-- A verified provider signature proves only that the event came from
-- PayMongo. It never proves that a given Booking may be marked paid, so
-- the binding, the amount and the currency are all re-checked here
-- against the server's own record. The signature check lives in PM-01C;
-- these checks stay mandatory regardless of it.
--
-- No notification: QR-11 locks QR Ph settlement as silent pre-defense,
-- because 'payment_received' was defined for COD -- where the Worker
-- attests cash and the Client learns something new -- and the QR Ph payer
-- IS the Client. COD's notification behaviour is unchanged.

CREATE OR REPLACE FUNCTION public.settle_booking_qrph(
  p_booking_id      uuid,
  p_intent_id       text,
  p_amount_centavos bigint,
  p_currency        text,
  p_provider_status text
)
RETURNS TABLE (
  booking_id     uuid,
  payment_method text,
  payment_status text,
  paymongo_ref   text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_intent_id      text := btrim(coalesce(p_intent_id, ''));
  v_booking_status text;
  v_job_id         uuid;
  v_pay_method     text;
  v_pay_status     text;
  v_pay_ref        text;
  v_budget         numeric;
  v_centavos       numeric;
  v_rows           integer;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER-SUPPLIED VALUE VALIDATION
  ----------------------------------------------------------------
  IF v_intent_id = '' OR length(v_intent_id) > 100 THEN
    RAISE EXCEPTION 'invalid payment intent reference'
      USING ERRCODE = '22023';
  END IF;

  IF p_currency IS NULL OR upper(btrim(p_currency)) <> 'PHP' THEN
    RAISE EXCEPTION 'unsupported payment currency'
      USING ERRCODE = '22023';
  END IF;

  IF p_amount_centavos IS NULL OR p_amount_centavos < 100 THEN
    RAISE EXCEPTION 'invalid payment amount'
      USING ERRCODE = '22023';
  END IF;

  ----------------------------------------------------------------
  -- 2. ONLY A SUCCEEDED PROVIDER STATE MAY SETTLE
  --
  -- A pending or failed provider state must never write 'paid'. PM-01C
  -- is expected not to call this for such events at all; this is the
  -- backstop that makes a mistake there harmless rather than financial.
  ----------------------------------------------------------------
  IF p_provider_status IS NULL OR btrim(p_provider_status) <> 'succeeded' THEN
    RAISE EXCEPTION 'this qr ph payment cannot be settled'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 3. LOCK THE BOOKING (lock order step 1)
  --
  -- Serialises duplicate webhook deliveries: the second one blocks here
  -- and, after acquiring the lock, sees the committed 'paid' row and
  -- returns at step 5 without writing again.
  ----------------------------------------------------------------
  SELECT b.status::text, b.job_id,
         b.payment_method::text, b.payment_status::text, b.paymongo_ref::text
    INTO v_booking_status, v_job_id,
         v_pay_method, v_pay_status, v_pay_ref
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 4. THE BINDING MUST MATCH
  --
  -- The Booking must exist, be completed, be a QR Ph Booking, and carry
  -- exactly the reference this event names. Requiring
  -- paymongo_ref = the event's Intent is what stops a genuine PayMongo
  -- event for one Booking settling a different one -- and it also
  -- refuses a NULL reference, a cod Booking and a gcash/maya Booking on
  -- the same line.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_booking_status IS DISTINCT FROM 'completed'
     OR v_pay_method     IS DISTINCT FROM 'qrph'
     OR v_pay_ref        IS DISTINCT FROM v_intent_id
  THEN
    RAISE EXCEPTION 'this qr ph payment cannot be settled'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 5. AMOUNT AND CURRENCY AGAINST THE SERVER'S OWN RECORD
  --
  -- Re-derived from the Job, never taken from the event. Checked BEFORE
  -- the already-paid branch, so a duplicate delivery carrying a
  -- different amount is refused rather than quietly acknowledged.
  ----------------------------------------------------------------
  SELECT jp.budget
    INTO v_budget
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id
  FOR SHARE;

  IF NOT FOUND OR v_budget IS NULL THEN
    RAISE EXCEPTION 'this qr ph payment cannot be settled'
      USING ERRCODE = 'SM409';
  END IF;

  v_centavos := v_budget * 100;

  IF v_centavos <> trunc(v_centavos)
     OR v_centavos < 100
     OR v_centavos > 9999999999
  THEN
    RAISE EXCEPTION 'this qr ph payment cannot be settled'
      USING ERRCODE = 'SM409';
  END IF;

  IF p_amount_centavos <> v_centavos::bigint THEN
    RAISE EXCEPTION 'payment amount does not match the authoritative job budget'
      USING ERRCODE = '22023';
  END IF;

  ----------------------------------------------------------------
  -- 6. ALREADY SETTLED -- REPEAT-SAFE NO-OP (QR-08)
  --
  -- Reached only after the binding, amount and currency have all been
  -- proven, so this really is the same payment arriving twice. Returns
  -- the current authoritative state, writes nothing, notifies nothing.
  -- PayMongo can therefore retry delivery freely.
  ----------------------------------------------------------------
  IF v_pay_status = 'paid' THEN
    RETURN QUERY
    SELECT p_booking_id, v_pay_method, v_pay_status, v_pay_ref;
    RETURN;
  END IF;

  -- Anything that is neither 'pending' nor 'paid' -- i.e. 'refunded' --
  -- is not a settleable state. No refund path exists; this is a forward
  -- guard.
  IF v_pay_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'this qr ph payment cannot be settled'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 7. THE ONLY WRITE
  --
  -- payment_status is the sole column in the statement. payment_method
  -- stays 'qrph', paymongo_ref keeps the same Intent, and
  -- bookings.status, completed_at and every Job column are untouched.
  ----------------------------------------------------------------
  UPDATE public.bookings AS b
     SET payment_status = 'paid'
   WHERE b.id = p_booking_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'this qr ph payment cannot be settled'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT p_booking_id, v_pay_method, 'paid'::text, v_pay_ref;
END;
$$;

COMMENT ON FUNCTION public.settle_booking_qrph(uuid, text, bigint, text, text) IS
  'PM-01A: the single trusted path from pending to paid for QR Ph. '
  'Requires a well-formed reference/currency/amount (22023) and a '
  '''succeeded'' provider state, then -- under a row lock -- that the '
  'Booking is completed, is payment_method = ''qrph'', and carries '
  'exactly the Payment Intent this event names, all collapsed into one '
  'SM409; that binding requirement is what stops a genuine PayMongo event '
  'for one Booking settling another. The amount is re-derived from the '
  'Job and compared, never taken from the event. A duplicate delivery of '
  'the same settled payment is a repeat-safe NO-OP that writes nothing. '
  'Sets payment_status = ''paid'' and nothing else, and emits NO '
  'notification (QR-11). service_role EXECUTE only.';

ALTER FUNCTION public.settle_booking_qrph(uuid, text, bigint, text, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.settle_booking_qrph(uuid, text, bigint, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.settle_booking_qrph(uuid, text, bigint, text, text) FROM anon;

REVOKE ALL ON FUNCTION public.settle_booking_qrph(uuid, text, bigint, text, text) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.settle_booking_qrph(uuid, text, bigint, text, text) TO service_role;
