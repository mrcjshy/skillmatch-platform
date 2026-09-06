-- ============================================================
-- BL-01D-DB-01: TRUSTED CASH-ON-DELIVERY PAYMENT PATH
-- ============================================================
--
-- SCOPE
-- -----
-- Implements the COD half of the payment lifecycle that
-- docs/DECISIONS.md ("Payment sequencing -- LOCKED") reserved but left
-- unimplemented: completion happens first, payment after.
--
-- This migration:
--   1. narrows direct table privileges on public.bookings
--   2. adds public.select_my_booking_cod()            -- Client chooses
--   3. adds public.confirm_my_cod_payment_received()  -- Worker confirms
--
-- It creates no table, column, index, constraint, trigger, enum or
-- publication, so the locked 11-table ERD (D-001) is untouched, and it
-- creates and drops no policy, so the public policy count stays 24.
--
-- ZERO SCHEMA EXPANSION, ON PURPOSE
-- ---------------------------------
-- Every value COD needs already exists in the baseline schema:
--
--   bookings_payment_method_check : ('gcash','maya','cod')
--   bookings_payment_status_check : ('pending','paid','refunded')
--
-- so the whole flow is expressible as tuples of columns that are
-- already there:
--
--   after N9 acceptance      (method NULL,  status 'pending')
--   after BL-01A completion  (method NULL,  status 'pending')
--   Client selects COD       (method 'cod', status 'pending')
--   Worker confirms cash     (method 'cod', status 'paid')
--
-- paymongo_ref stays NULL throughout: it is nullable with no default,
-- so COD never has to invent a provider reference, and a later PayMongo
-- piece can still use 'gcash'/'maya' with a real reference beside this.
--
-- WHY TWO RPCs RATHER THAN A BOOKING UPDATE POLICY
-- ------------------------------------------------
-- public.bookings has exactly one policy -- a participant SELECT. N9
-- removed the direct INSERT and UPDATE policies and BL-01A deliberately
-- did not restore them, so the ONLY writers of a Booking are trusted
-- postgres-owned functions. Adding an UPDATE policy for payment would
-- reverse that decision and would have to police which COLUMNS a
-- statement touches -- RLS cannot express "may set payment_method but
-- not payment_status, status or completed_at" cleanly. Two narrow
-- functions that accept no payment value at all are the smaller
-- boundary, and they match N9, N10, N12, BL-01A and BL-01B.
--
-- THE TWO ACTORS ARE DELIBERATELY DIFFERENT
-- -----------------------------------------
-- The Client chooses HOW to pay; only the assigned Worker can attest
-- that cash physically changed hands. Splitting the two transitions
-- across two functions with two different account gates is what makes
-- that unforgeable: a Client cannot mark their own Booking paid, and a
-- Worker cannot choose the Client's payment method. Neither is a UI
-- convention -- each function refuses the other's role at step 1.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
-- No refund path ('refunded' remains a value no code produces). No
-- PayMongo: nothing here writes paymongo_ref, sets 'gcash' or 'maya',
-- or settles an online method. No payment reversal or edit. No Booking
-- lifecycle change -- status, completed_at and job_postings are never
-- written. No Rating, no Message, no matching change. No new
-- notification type: 'payment_received' is already in
-- notifications_type_check and already labelled in the mobile client.
--


-- ---------- 1. DIRECT TABLE PRIVILEGES ON public.bookings ----------
--
-- public.bookings is the last table still carrying the unnarrowed
-- Supabase default ACL -- anon and authenticated both hold arwdDxtm.
-- Those grants are inert today only because the table has no INSERT,
-- UPDATE or DELETE policy, so RLS refuses every write by default.
--
-- BL-01D is the right moment to close that. Before this piece a Booking
-- carried no settled money state; after it, payment_status = 'paid' is
-- a real financial assertion, so the blast radius of one mistaken
-- permissive UPDATE policy is materially larger than it used to be.
-- Removing the privilege at the GRANT layer means such a mistake fails
-- before RLS is even consulted (GAP-004 discipline, the same treatment
-- N12 gave notifications, BL-01C gave messages and BL-01B gave
-- ratings).
--
-- SELECT is re-granted because participants legitimately read their own
-- Bookings -- the existing participant SELECT policy is unchanged and
-- keeps scoping that read -- and because the COD client reads its own
-- payment tuple directly rather than widening the N11 return shape.
--
-- REVOKE ALL rather than an enumerated list, so the end state does not
-- depend on which privilege letters this server version supports;
-- PostgreSQL 17's MAINTAIN is present in the current ACL.
--
-- service_role and the postgres owner entry are deliberately untouched.

REVOKE ALL ON TABLE public.bookings FROM anon;

REVOKE ALL ON TABLE public.bookings FROM authenticated;

-- Re-granted explicitly so the intended end state is stated rather than
-- inherited. SELECT is the only direct client privilege that remains.
GRANT SELECT ON TABLE public.bookings TO authenticated;


-- ---------- 2. CLIENT CHOOSES COD ----------
--
-- The Client names a Booking and nothing else. There is no payment
-- method, status or reference parameter, so "select COD" is the only
-- thing this function can express -- a caller cannot smuggle 'paid',
-- 'gcash' or a provider reference through it.
--
-- REPEAT SELECTION IS A NO-OP, NOT A CONFLICT.
-- N9, BL-01A and BL-01B all raise SM409 on a repeated call, because in
-- each of those a repeat would be a SECOND MEANINGFUL EVENT: a second
-- acceptance, a second completion, a second rating. Re-selecting COD on
-- a Booking that is already (cod, pending) is not a second event -- it
-- is a restatement of the same choice, it changes no row, and there is
-- no notification that could be duplicated. So it returns the current
-- state and writes nothing. This is a deliberate, narrow departure from
-- the repeat-conflict convention, and it is NOT idempotency in general:
-- every OTHER repeat (already paid, another method) still conflicts.

CREATE OR REPLACE FUNCTION public.select_my_booking_cod(p_booking_id uuid)
RETURNS TABLE (
  booking_id     uuid,
  payment_method text,
  payment_status text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller         uuid := auth.uid();
  v_booking_status text;
  v_booking_client uuid;
  v_pay_method     text;
  v_pay_status     text;
  v_rows           integer;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (account level)
  --
  -- Client-only, which is what makes the direction unforgeable: a
  -- Worker attempting to choose the payment method is rejected here,
  -- before any Booking is read, and learns nothing about any Booking.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to select booking payment'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. LOCK THE BOOKING
  --
  -- One row, locked before any decision, so a concurrent selection or
  -- Worker confirmation cannot interleave between the read and the
  -- write. public.job_postings is deliberately NOT touched or locked:
  -- COD changes no Job state, so the project's Booking -> Job lock
  -- order never comes into play here.
  ----------------------------------------------------------------
  SELECT b.status::text, b.client_id,
         b.payment_method::text, b.payment_status::text
    INTO v_booking_status, v_booking_client, v_pay_method, v_pay_status
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 3. MUST EXIST, BE OURS, AND BE COMPLETED
  --
  -- One error for all three. A Client must not be able to distinguish
  -- "no such Booking" from "somebody else's Booking" from "not finished
  -- yet", or this becomes a Booking-existence oracle. NOT FOUND covers
  -- the nonexistent case because SELECT ... INTO leaves FOUND false.
  --
  -- 'completed' is required because payment follows completion
  -- (docs/DECISIONS.md, Payment sequencing). A confirmed Booking is not
  -- yet payable; cancelled and no_show never become payable.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM v_caller
     OR v_booking_status IS DISTINCT FROM 'completed'
  THEN
    RAISE EXCEPTION 'this booking is not available for payment selection'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. DECIDE FROM THE LOCKED PAYMENT TUPLE
  ----------------------------------------------------------------
  IF v_pay_method IS NULL AND v_pay_status = 'pending' THEN

    -- The real transition. Only payment_method is written: status stays
    -- 'pending' (cash has not changed hands yet), and paymongo_ref,
    -- bookings.status and completed_at are not in the statement at all.
    UPDATE public.bookings AS b
       SET payment_method = 'cod'
     WHERE b.id = p_booking_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows <> 1 THEN
      RAISE EXCEPTION 'this booking is not available for payment selection'
        USING ERRCODE = 'SM409';
    END IF;

    v_pay_method := 'cod';

  ELSIF v_pay_method = 'cod' AND v_pay_status = 'pending' THEN

    -- Already exactly what was asked for. No UPDATE is executed and no
    -- notification is emitted; the current state is returned unchanged.
    NULL;

  ELSE

    -- Everything else conflicts: already paid, refunded, or an online
    -- method already chosen. 'gcash' and 'maya' are unreachable today
    -- because nothing sets them, so this is also the forward guard that
    -- stops COD selection from overwriting a future PayMongo choice.
    RAISE EXCEPTION 'this booking is not available for payment selection'
      USING ERRCODE = 'SM409';

  END IF;

  RETURN QUERY SELECT p_booking_id, v_pay_method, v_pay_status;
END;
$$;

COMMENT ON FUNCTION public.select_my_booking_cod(uuid) IS
  'BL-01D: the Client chooses Cash on Delivery for one completed '
  'Booking they own. Requires an active Client account (42501 '
  'otherwise), then that the Booking exists, is the caller''s, and is '
  'completed -- all three collapsed into the SAME SM409 so the function '
  'is not a Booking-existence oracle. Takes no payment value: the only '
  'write it can perform is payment_method = ''cod'' on a '
  '(NULL, pending) tuple. Re-selecting COD on a Booking that is already '
  '(cod, pending) is a NO-OP that writes nothing and returns the '
  'current state; every other tuple -- already paid, refunded, or an '
  'online method -- conflicts with SM409. Writes no payment_status, no '
  'paymongo_ref, no bookings.status, no completed_at and no Job row, '
  'and emits no notification.';

REVOKE ALL ON FUNCTION public.select_my_booking_cod(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.select_my_booking_cod(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.select_my_booking_cod(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.select_my_booking_cod(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.select_my_booking_cod(uuid) TO authenticated;


-- ---------- 3. WORKER CONFIRMS CASH RECEIVED ----------
--
-- The single trusted path from 'pending' to 'paid'. Only the assigned
-- Worker can execute it, because only they can attest that cash
-- physically changed hands; the Client -- who has every incentive to
-- assert payment -- is refused at the account gate.
--
-- The Client notification is emitted inside this same transaction, so
-- "marked paid" and "Client told" commit together or not at all.
-- private.emit_notification deliberately carries no exception handler,
-- so a failed insert propagates here and rolls the payment transition
-- back rather than leaving a silently unannounced settlement.

CREATE OR REPLACE FUNCTION public.confirm_my_cod_payment_received(p_booking_id uuid)
RETURNS TABLE (
  booking_id     uuid,
  payment_method text,
  payment_status text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller         uuid := auth.uid();
  v_booking_status text;
  v_booking_worker uuid;
  v_booking_client uuid;
  v_job_id         uuid;
  v_job_title      text;
  v_pay_method     text;
  v_pay_status     text;
  v_rows           integer;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (account level)
  --
  -- Worker-only. A Client calling this is rejected before any Booking
  -- is read, which is what stops the paying party from asserting its
  -- own payment.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized to confirm cash payment'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. LOCK THE BOOKING
  --
  -- Serialises two concurrent confirmations of the same Booking: the
  -- loser blocks here, and the statement it runs after acquiring the
  -- lock sees the committed 'paid' row and stops at step 4 without
  -- writing or notifying again. Again no Job lock -- COD does not touch
  -- job_postings.
  ----------------------------------------------------------------
  SELECT b.status::text, b.worker_id, b.client_id, b.job_id,
         b.payment_method::text, b.payment_status::text
    INTO v_booking_status, v_booking_worker, v_booking_client, v_job_id,
         v_pay_method, v_pay_status
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 3. MUST EXIST, BE OURS, BE COMPLETED, AND BE COD
  --
  -- One collapsed error for all four, so a Worker cannot probe which
  -- Booking ids exist, which are theirs, or how another participant
  -- chose to pay. Requiring payment_method = 'cod' here is also the
  -- PayMongo forward guard: this function can never settle a 'gcash' or
  -- 'maya' Booking, whatever a future online piece adds.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_booking_worker IS DISTINCT FROM v_caller
     OR v_booking_status IS DISTINCT FROM 'completed'
     OR v_pay_method IS DISTINCT FROM 'cod'
  THEN
    RAISE EXCEPTION 'this cash payment cannot be confirmed'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. ALREADY PAID
  --
  -- SM403 rather than SM409, matching the BL-01A paid guard: by this
  -- point the caller is the proven assigned Worker of a completed COD
  -- Booking, so telling them it is already settled reveals nothing they
  -- do not already know, and a distinct code lets the app say so
  -- plainly instead of showing a generic conflict.
  --
  -- Reached BEFORE any write and before any notification, which is what
  -- guarantees a repeated confirmation cannot pay twice or notify
  -- twice.
  ----------------------------------------------------------------
  IF v_pay_status = 'paid' THEN
    RAISE EXCEPTION 'this cash payment has already been confirmed'
      USING ERRCODE = 'SM403';
  END IF;

  -- Anything that is neither 'pending' nor 'paid' -- i.e. 'refunded' --
  -- is not a settleable state and collapses back into the conflict
  -- class. No refund path exists, so this is a forward guard.
  IF v_pay_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'this cash payment cannot be confirmed'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 5. JOB TITLE FOR THE NOTIFICATION
  --
  -- Read WITHOUT a lock: the title is display text for the message and
  -- COD writes nothing to job_postings, so locking it would add
  -- ordering risk for no benefit. A missing Job would be anomalous
  -- data; fail closed with the same collapsed error rather than emit a
  -- notification naming nothing.
  ----------------------------------------------------------------
  SELECT jp.title::text
    INTO v_job_title
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'this cash payment cannot be confirmed'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 6. THE ONLY WRITE
  --
  -- payment_status is the sole column in the statement. payment_method
  -- stays 'cod', paymongo_ref stays NULL, and bookings.status,
  -- completed_at and every Job column are untouched.
  ----------------------------------------------------------------
  UPDATE public.bookings AS b
     SET payment_status = 'paid'
   WHERE b.id = p_booking_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'this cash payment cannot be confirmed'
      USING ERRCODE = 'SM409';
  END IF;

  v_pay_status := 'paid';

  ----------------------------------------------------------------
  -- 7. NOTIFY THE CLIENT -- SAME TRANSACTION
  --
  -- 'payment_received' is already permitted by notifications_type_check
  -- and already carries a label in the mobile client, so no type is
  -- added anywhere. The message carries the Job title and fixed
  -- operational text only -- no amount, no contact detail, no Worker
  -- identity -- matching the N12 notification privacy rule.
  ----------------------------------------------------------------
  PERFORM private.emit_notification(
    v_booking_client,
    'payment_received',
    'Cash payment received for your job "' || v_job_title || '".'
  );

  RETURN QUERY SELECT p_booking_id, v_pay_method, v_pay_status;
END;
$$;

COMMENT ON FUNCTION public.confirm_my_cod_payment_received(uuid) IS
  'BL-01D: the assigned Worker confirms that COD cash was actually '
  'received. Requires an active Worker account (42501 otherwise), then '
  'that the Booking exists, names the caller as worker_id, is '
  'completed, and has payment_method = ''cod'' -- all four collapsed '
  'into the SAME SM409, which is also the guard that stops this '
  'function ever settling a gcash or maya Booking. An already-paid '
  'Booking raises SM403 after participation is proven, before any write '
  'or notification, so a repeated confirmation cannot pay twice or '
  'notify twice. Sets payment_status = ''paid'' and nothing else -- '
  'payment_method, paymongo_ref, bookings.status, completed_at and '
  'job_postings are all untouched -- and emits exactly one '
  'payment_received notification to the CLIENT in the same '
  'transaction, so a failed notification rolls the settlement back. '
  'The Client can never execute this; the Worker can never choose the '
  'payment method.';

REVOKE ALL ON FUNCTION public.confirm_my_cod_payment_received(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.confirm_my_cod_payment_received(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.confirm_my_cod_payment_received(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.confirm_my_cod_payment_received(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.confirm_my_cod_payment_received(uuid) TO authenticated;
