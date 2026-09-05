-- ============================================================
-- BL-01A-DB-01: BOOKING COMPLETION AND CANCELLATION
-- ============================================================
--
-- N9 removed the direct authenticated Booking INSERT and UPDATE
-- policies and did not replace them, so public.bookings currently has
-- NO INSERT and NO UPDATE policy at all. That was deliberate: it closed
-- the Client-assigns-Worker side door, but it also left a Booking with
-- no way out of 'confirmed'. Every Booking created by
-- accept_job_opportunity is permanent, and its Job is permanently
-- 'matched'.
--
-- This migration adds the two lifecycle exits, and only those two:
--
--   public.complete_my_client_booking(p_booking_id uuid)
--   public.cancel_my_booking(p_booking_id uuid)
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
-- No table, column, index, constraint or trigger is added, so the
-- locked 11-table ERD (D-001) is untouched. No policy is created,
-- dropped or altered -- in particular the direct Booking UPDATE path
-- stays closed, and these functions are the only way to move a Booking
-- out of 'confirmed'. No payment field is written. No 'no_show'
-- transition, no strike_count change, no suspension, no refund, no
-- rematching, no Ratings, no Messaging change. Those are separate
-- pieces.
--
-- WHY TWO NARROW FUNCTIONS RATHER THAN ONE transition_booking()
-- -------------------------------------------------------------
-- The two actions have different actors: completion is Client-only,
-- cancellation is either participant. A single generic entry point
-- would multiplex two different authorization models behind one
-- EXECUTE grant and one caller-supplied action string, which is both a
-- weaker privilege boundary and harder to audit. Every existing public
-- RPC in this project (N8, N8-W, N9, N10, N11, N12) is narrow and
-- single-purpose; these follow that convention.
--
-- WHY THESE WRITE AT ALL WITH NO UPDATE POLICY PRESENT
-- ----------------------------------------------------
-- public.bookings and public.job_postings are owned by postgres with
-- relforcerowsecurity = false, so a postgres-owned SECURITY DEFINER
-- function is the table owner and is not subject to RLS on them. The
-- writes below therefore succeed with no UPDATE policy present -- which
-- is the point: afterwards the ONLY way a Booking can leave 'confirmed'
-- is from inside one of these two reviewed functions. Same mechanism
-- N10 documents for worker_profiles and N12 for notifications.
--
-- LOCK ORDER (fixed, both functions)
-- ----------------------------------
--   1. the Booking row   FOR UPDATE
--   2. its Job row       FOR UPDATE
--
-- Never inverted. N9's acceptance path locks a Job row, so a lifecycle
-- function that took the Job first and the Booking second could deadlock
-- against a future writer holding them the other way round. Booking
-- first is also the natural order: the Booking is the row being acted
-- on, and its job_id is what identifies the Job to lock.
--
-- Both functions re-read the authoritative values FROM THE LOCKED ROWS
-- and decide from those, never from a pre-lock read. Under READ
-- COMMITTED a blocked SELECT ... FOR UPDATE re-reads the newest
-- committed version once the lock is granted, so a second concurrent
-- caller sees the terminal status the winner just committed and stops
-- before writing anything. That is what makes repeated and racing calls
-- safe without any exception handler.
--
-- ERROR CONTRACT (extends the N9 taxonomy, does not replace it)
-- -------------------------------------------------------------
--   42501  the caller's account/role may not use this surface at all
--   SM403  a proven participant, blocked by a specific eligibility rule
--   SM409  unavailable / current-state conflict
--
-- SM409 deliberately collapses: nonexistent Booking, Booking belonging
-- to someone else, Booking already terminal, Booking not 'confirmed',
-- and inconsistent Booking/Job linkage. An authenticated caller must not
-- be able to probe which Booking ids exist or what state another
-- participant's Booking is in, so all of those produce one identical
-- error. SM403 is used only AFTER participation has been proven, where
-- the caller already knows everything the error reveals.

-- ---------- 1. CLIENT-ONLY COMPLETION ----------
--
-- VOLATILE (it writes). SECURITY DEFINER for the owner-bypass described
-- in the header: public.bookings has no UPDATE policy and must not get
-- one.
--
-- The Worker cannot reach this function. Completion is the Client's
-- attestation that the work was delivered, and under the locked
-- sequencing (service completion first, payment afterward) it is the
-- event a later payment piece will depend on. A Worker-writable
-- completion would let the Worker declare their own work finished.

CREATE OR REPLACE FUNCTION public.complete_my_client_booking(p_booking_id uuid)
RETURNS TABLE (
  booking_id     uuid,
  job_id         uuid,
  booking_status text,
  job_status     text
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
  v_booking_worker uuid;
  v_job_id         uuid;
  v_job_status     text;
  v_job_client     uuid;
  v_job_title      text;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (account level)
  --
  -- private.is_active_client() answers "may this account use the
  -- completion API at all?" -- role = 'client' AND is_active. Signed
  -- out, Worker, Administrator and suspended Client all raise the SAME
  -- error and learn nothing about any Booking. A Worker attempting a
  -- Client-only completion is rejected here, before any Booking is
  -- touched or even read.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to complete bookings'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. LOCK THE BOOKING (lock order step 1)
  ----------------------------------------------------------------
  SELECT b.status::text, b.client_id, b.worker_id, b.job_id
    INTO v_booking_status, v_booking_client, v_booking_worker, v_job_id
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 3. THE BOOKING MUST EXIST, BE OURS, AND BE 'confirmed'
  --
  -- One error for all three. A Client must not be able to distinguish
  -- "no such Booking" from "somebody else's Booking" from "already
  -- completed", or the function becomes a Booking-existence oracle.
  -- NOT FOUND covers the nonexistent case because SELECT ... INTO
  -- leaves FOUND false.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM v_caller
     OR v_booking_status IS DISTINCT FROM 'confirmed'
  THEN
    RAISE EXCEPTION 'this booking is not available for completion'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. LOCK THE JOB (lock order step 2)
  --
  -- Read under the lock: the title used in the notification is then
  -- guaranteed to be the same row version this completion acted on.
  ----------------------------------------------------------------
  SELECT jp.status::text, jp.client_id, jp.title::text
    INTO v_job_status, v_job_client, v_job_title
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 5. THE PAIR MUST BE INTERNALLY CONSISTENT
  --
  -- Same collapsed error. A Booking whose Job is missing, is not
  -- 'matched', or is owned by a different Client than the Booking is
  -- anomalous legacy/manual data: fail closed rather than write a
  -- half-consistent lifecycle state such as Booking completed with the
  -- Job still matched.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_job_status IS DISTINCT FROM 'matched'
     OR v_job_client IS DISTINCT FROM v_booking_client
  THEN
    RAISE EXCEPTION 'this booking is not available for completion'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 6. ATOMIC WRITES
  --
  -- No exception handler, on purpose: a failure must abort the whole
  -- statement so a Booking can never be completed with its Job left
  -- matched, and vice versa.
  --
  -- completed_at comes from the server clock, never from the caller.
  -- The payment columns are deliberately absent from both UPDATE
  -- statements: payment_method, payment_status and paymongo_ref keep
  -- whatever they already hold. Under the locked sequencing, completion
  -- happens first and payment is a separate later piece.
  ----------------------------------------------------------------
  UPDATE public.bookings AS b
  SET status       = 'completed',
      completed_at = now()
  WHERE b.id = p_booking_id;

  UPDATE public.job_postings AS jp
  SET status = 'completed'
  WHERE jp.id = v_job_id;

  ----------------------------------------------------------------
  -- 7. NOTIFICATION (N12 helper) -- SAME TRANSACTION
  --
  -- Only the Worker is notified. The Client performed this action and
  -- does not need to be told about it; N12's own N9 precedent notifies
  -- both parties because acceptance is news to both, which completion
  -- is not.
  --
  -- Recipient is a trusted value read from the locked Booking row, never
  -- caller input. The message carries the Job title and fixed wording
  -- only -- no phone, email, address or counterparty name. Because a
  -- repeated call raises at step 3 before reaching here, no second
  -- notification can ever be emitted for the same completion.
  ----------------------------------------------------------------
  PERFORM private.emit_notification(
    v_booking_worker,
    'booking_completed',
    'Your booking for "' || v_job_title || '" has been marked completed.'
  );

  ----------------------------------------------------------------
  -- 8. RETURN THE MINIMUM PROJECTION
  --
  -- Read back from the persisted rows rather than echoing the constants
  -- written above, so the caller receives observed state. No identity or
  -- contact data of any party.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT b.id, b.job_id, b.status::text, jp.status::text
  FROM public.bookings AS b
  JOIN public.job_postings AS jp ON jp.id = b.job_id
  WHERE b.id = p_booking_id;
END;
$$;

COMMENT ON FUNCTION public.complete_my_client_booking(uuid) IS
  'BL-01A: Client-only Booking completion. Requires an active Client '
  '(private.is_active_client()) who owns the Booking; every other '
  'caller receives 42501, including the assigned Worker. Locks the '
  'Booking row then its Job row -- fixed order, never inverted -- and '
  'decides only from the locked values. Nonexistent, other-owned, '
  'already-terminal, non-confirmed and inconsistent Booking/Job pairs '
  'all return the SAME SM409, so the function is not a Booking-existence '
  'oracle. Sets bookings.status = completed with a server-clock '
  'completed_at and job_postings.status = completed in one transaction, '
  'and emits exactly one booking_completed notification to the Worker '
  'inside it. Writes no payment column: payment_method, payment_status '
  'and paymongo_ref are preserved. A repeated call raises before any '
  'write, so it cannot mutate twice or notify twice.';

REVOKE ALL ON FUNCTION public.complete_my_client_booking(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.complete_my_client_booking(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.complete_my_client_booking(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.complete_my_client_booking(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.complete_my_client_booking(uuid) TO authenticated;


-- ---------- 2. EITHER-PARTICIPANT CANCELLATION ----------
--
-- Cancellation is terminal pre-defense: the Job goes to 'cancelled' and
-- is NOT reopened, and no replacement Booking is created. If the Client
-- still needs the service they post a new Job.
--
-- That is a deliberate scope choice, not an oversight. Reopening a Job
-- (matched -> open) would allow a second Booking for the same Job, and
-- nothing in the schema prevents two 'confirmed' Bookings coexisting --
-- there is no unique constraint on bookings.job_id, which N9 left
-- deferred precisely until rematching semantics were locked. Terminal
-- cancellation keeps N9's first-wins concurrency model exactly as it is.
--
-- The cancelled Booking is kept as history. N11 continues to list it
-- because ownership and status are separate axes there, and its
-- counterparty contact release flips to suppressed automatically the
-- moment the status becomes 'cancelled' -- the live status rule N12's
-- privacy note depends on.

CREATE OR REPLACE FUNCTION public.cancel_my_booking(p_booking_id uuid)
RETURNS TABLE (
  booking_id     uuid,
  job_id         uuid,
  booking_status text,
  job_status     text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller          uuid := auth.uid();
  v_booking_status  text;
  v_booking_client  uuid;
  v_booking_worker  uuid;
  v_payment_status  text;
  v_job_id          uuid;
  v_job_status      text;
  v_job_client      uuid;
  v_job_title       text;
  v_recipient       uuid;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (account level)
  --
  -- Either participant role may use this surface, so the account gate
  -- accepts an active Worker OR an active Client. Being the RIGHT
  -- Worker or Client is a separate question, answered at step 3 from
  -- the locked row -- and answered with a different, collapsed error,
  -- so this step never reveals anything about a specific Booking.
  ----------------------------------------------------------------
  IF v_caller IS NULL
     OR NOT (private.is_active_worker() OR private.is_active_client())
  THEN
    RAISE EXCEPTION 'not authorized to cancel bookings'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. LOCK THE BOOKING (lock order step 1)
  ----------------------------------------------------------------
  SELECT b.status::text, b.client_id, b.worker_id, b.job_id,
         b.payment_status::text
    INTO v_booking_status, v_booking_client, v_booking_worker, v_job_id,
         v_payment_status
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 3. THE BOOKING MUST EXIST, INVOLVE US, AND BE 'confirmed'
  --
  -- Participation is tested against the LOCKED row: the caller must be
  -- exactly this Booking's worker_id or client_id. A Worker holding
  -- another Booking's id, a Client who owns a different Booking, a
  -- nonexistent id and an already-terminal Booking all collapse into
  -- the same SM409.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR (v_booking_client IS DISTINCT FROM v_caller
         AND v_booking_worker IS DISTINCT FROM v_caller)
     OR v_booking_status IS DISTINCT FROM 'confirmed'
  THEN
    RAISE EXCEPTION 'this booking is not available for cancellation'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. FAIL CLOSED ON AN ALREADY-PAID BOOKING
  --
  -- No path can currently set payment_status to 'paid' -- BL-01A writes
  -- no payment column and there is no payment piece yet -- so this is a
  -- forward guard, not a live case. If an anomalous paid Booking ever
  -- exists, cancelling it would produce a 'cancelled + paid' state with
  -- no refund mechanism to resolve it. Refuse instead.
  --
  -- SM403 rather than SM409 here on purpose: participation has already
  -- been proven at step 3, so this caller is a genuine participant and
  -- the error reveals nothing they do not already know. Collapsing it
  -- into SM409 would only make a real operational problem harder to
  -- diagnose.
  ----------------------------------------------------------------
  IF v_payment_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'a paid booking cannot be cancelled here'
      USING ERRCODE = 'SM403';
  END IF;

  ----------------------------------------------------------------
  -- 5. LOCK THE JOB (lock order step 2)
  ----------------------------------------------------------------
  SELECT jp.status::text, jp.client_id, jp.title::text
    INTO v_job_status, v_job_client, v_job_title
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 6. THE PAIR MUST BE INTERNALLY CONSISTENT
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_job_status IS DISTINCT FROM 'matched'
     OR v_job_client IS DISTINCT FROM v_booking_client
  THEN
    RAISE EXCEPTION 'this booking is not available for cancellation'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 7. ATOMIC WRITES
  --
  -- completed_at is deliberately NOT set -- a cancelled Booking was
  -- never completed. The payment columns are absent from both UPDATEs
  -- and keep whatever they already hold. The Job is terminal: it is set
  -- to 'cancelled', never back to 'open'.
  ----------------------------------------------------------------
  UPDATE public.bookings AS b
  SET status = 'cancelled'
  WHERE b.id = p_booking_id;

  UPDATE public.job_postings AS jp
  SET status = 'cancelled'
  WHERE jp.id = v_job_id;

  ----------------------------------------------------------------
  -- 8. NOTIFICATION (N12 helper) -- SAME TRANSACTION
  --
  -- The counterparty is notified, never the actor: whichever
  -- participant did not call this function. Both ids come from the
  -- locked Booking row.
  ----------------------------------------------------------------
  IF v_caller = v_booking_client THEN
    v_recipient := v_booking_worker;
  ELSE
    v_recipient := v_booking_client;
  END IF;

  PERFORM private.emit_notification(
    v_recipient,
    'booking_cancelled',
    'The booking for "' || v_job_title || '" has been cancelled.'
  );

  ----------------------------------------------------------------
  -- 9. RETURN THE MINIMUM PROJECTION
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT b.id, b.job_id, b.status::text, jp.status::text
  FROM public.bookings AS b
  JOIN public.job_postings AS jp ON jp.id = b.job_id
  WHERE b.id = p_booking_id;
END;
$$;

COMMENT ON FUNCTION public.cancel_my_booking(uuid) IS
  'BL-01A: Booking cancellation by either participant. Requires an '
  'active Worker or active Client account (42501 otherwise), and then '
  'that the caller is exactly this Booking''s worker_id or client_id. '
  'Locks the Booking row then its Job row -- same fixed order as '
  'complete_my_client_booking -- and decides only from the locked '
  'values. Nonexistent, non-participant, already-terminal, '
  'non-confirmed and inconsistent Booking/Job pairs all return the SAME '
  'SM409; an already-paid Booking returns SM403 after participation is '
  'proven, so a cancelled+paid state with no refund path cannot be '
  'created. Sets bookings.status = cancelled and '
  'job_postings.status = cancelled in one transaction and emits exactly '
  'one booking_cancelled notification to the COUNTERPARTY inside it. '
  'Cancellation is terminal: the Job is never reopened, no replacement '
  'Booking is created, nothing is deleted, completed_at stays NULL and '
  'no payment column is written.';

REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.cancel_my_booking(uuid) TO authenticated;
