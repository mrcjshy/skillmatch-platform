-- ============================================================
-- R4-DB-01: JOB POSTING-TIME PAYMENT INTENT
-- ============================================================
--
-- SCOPE
-- -----
-- Clients choose Cash (`cod`) or QR Ph (`qrph`) while posting a Job.
-- That choice is Job-level intent. Booking payment columns remain the
-- claimed/processing state and are NOT copied at acceptance.
--
-- This migration:
--   1. adds nullable public.job_postings.payment_method (no default)
--   2. adds CHECKs for allowed values and the QR Ph payable-budget rule
--   3. requires a valid method on new authenticated Client INSERTs
--   4. makes payment_method immutable after INSERT
--   5. DROP/CREATE public.list_my_job_opportunities() with +1 field
--   6. amends COD select and QR Ph prepare/claim to enforce non-NULL
--      Job intent (legacy NULL keeps dual choice)
--
-- D-001: table count stays 12. No 13th table. No Booking column.
-- Matching/scoring and public.accept_job_opportunity() are untouched.
-- No PayMongo call and no Edge Function is introduced or invoked.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No backfill of existing Jobs (NULL remains legitimate legacy).
--   * No path that converts a legacy NULL Job to cod/qrph (R4B).
--   * No copy of Job intent onto bookings.payment_method at accept.
--   * No gcash/maya at Job level.
--   * No change to private.compute_job_matches or location_points.
--   * No Edge Function request-shape change.
-- ============================================================


-- ---------- 1. COLUMN + CHECKS ----------
--
-- NULLABLE, NO DEFAULT: existing rows stay NULL. PostgreSQL CHECK
-- treats UNKNOWN as pass, so a method CHECK of IN ('cod','qrph')
-- would already allow NULL; the NULL disjunct is written explicitly
-- so the legacy case is not an accident of three-valued logic.
--
-- The QR Ph budget CHECK cannot be
--   payment_method <> 'qrph' OR budget >= 1
-- because NULL <> 'qrph' is UNKNOWN and CHECK accepts UNKNOWN, which
-- would admit a qrph row with a NULL budget. IS DISTINCT FROM plus an
-- explicit budget IS NOT NULL conjunct rejects that combination.

ALTER TABLE public.job_postings
  ADD COLUMN payment_method character varying(20);

COMMENT ON COLUMN public.job_postings.payment_method IS
  'R4: posting-time payment intent. cod = Cash, qrph = QR Ph. NULL is '
  'legacy compatibility only; new Client INSERTs must supply cod or '
  'qrph. Immutable after INSERT. Not the Booking claimed/processing '
  'state (bookings.payment_method).';


ALTER TABLE public.job_postings
  ADD CONSTRAINT job_postings_payment_method_check
  CHECK (
    payment_method IS NULL
    OR (payment_method)::text = ANY (
      (ARRAY['cod'::character varying,
             'qrph'::character varying])::text[]
    )
  );


ALTER TABLE public.job_postings
  ADD CONSTRAINT job_postings_qrph_budget_check
  CHECK (
    (payment_method)::text IS DISTINCT FROM 'qrph'::text
    OR (budget IS NOT NULL AND budget >= 1.00)
  );


-- ---------- 2. NEW INSERTS MUST CHOOSE A METHOD ----------
--
-- WITH CHECK requires TRUE. payment_method IN ('cod','qrph') is
-- UNKNOWN when the column is NULL, so a new authenticated INSERT
-- without a method is denied. Existing NULL rows are not INSERTs
-- and are unaffected. Active-Client / own-client_id gates are
-- preserved.

DROP POLICY IF EXISTS "Active clients can insert their own jobs"
  ON public.job_postings;

CREATE POLICY "Active clients can insert their own jobs"
  ON public.job_postings
  FOR INSERT
  TO authenticated
  WITH CHECK (
    private.is_active_client()
    AND client_id = auth.uid()
    AND (payment_method)::text = ANY (
      (ARRAY['cod'::character varying,
             'qrph'::character varying])::text[]
    )
  );


-- ---------- 3. IMMUTABILITY AFTER INSERT ----------
--
-- Ordinary Clients may still UPDATE title/description/budget/schedule
-- on an open Job. They must not change payment_method, including
-- non-NULL -> NULL, cod -> qrph, qrph -> cod, or NULL -> cod/qrph.
-- Trusted lifecycle RPCs (accept, complete, cancel) UPDATE status
-- only, so an unconditional IS DISTINCT FROM guard does not block
-- them. The guard does not inspect current_user: any role that
-- changes payment_method is refused. SECURITY INVOKER matches the
-- existing Job/profile column-guard convention (trigger functions
-- are not a client-callable EXECUTE surface).

CREATE OR REPLACE FUNCTION public.guard_job_postings_payment_method()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.payment_method IS DISTINCT FROM OLD.payment_method THEN
    RAISE EXCEPTION 'changing a job payment method is not permitted'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;


COMMENT ON FUNCTION public.guard_job_postings_payment_method() IS
  'R4: BEFORE UPDATE guard. Rejects any change to '
  'job_postings.payment_method (42501), including legacy NULL to '
  'cod/qrph. Other Job columns are unaffected. Does not inspect '
  'current_user. SECURITY INVOKER; EXECUTE revoked from client roles. '
  'Complements, and does not replace, the open-Job UPDATE RLS policy.';


REVOKE ALL ON FUNCTION public.guard_job_postings_payment_method()
FROM PUBLIC, anon, authenticated, service_role;


DROP TRIGGER IF EXISTS trg_guard_job_postings_payment_method
  ON public.job_postings;

CREATE TRIGGER trg_guard_job_postings_payment_method
  BEFORE UPDATE ON public.job_postings
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_job_postings_payment_method();


-- ---------- 4. WORKER OPPORTUNITY PROJECTION ----------
--
-- PostgreSQL cannot CREATE OR REPLACE a changed RETURNS TABLE / OUT
-- shape. DROP has no SQL dependents. No CASCADE. Recreate preserves
-- STABLE, SECURITY DEFINER, empty search_path, owner, comment, and
-- authenticated-only EXECUTE.

DROP FUNCTION public.list_my_job_opportunities();


CREATE FUNCTION public.list_my_job_opportunities()
RETURNS TABLE (
  job_id          uuid,
  title           character varying,
  description     text,
  barangay        character varying,
  city            character varying,
  budget          numeric,
  scheduled_at    timestamp with time zone,
  skill_points    numeric,
  location_points numeric,
  rating_points   numeric,
  total_points    numeric,
  payment_method  character varying
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  ----------------------------------------------------------------
  -- CALLER GATE -- unchanged from N8-W-01
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized for worker opportunities'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- OPPORTUNITIES
  --
  -- Same open-Job filter, same LATERAL scorer, same privacy: no join
  -- to the Client's public.users row, no address. R4 adds the Job's
  -- posting-time payment_method (cod, qrph, or NULL for legacy).
  -- Matching/scoring is not consulted for that column.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT
    jp.id,
    jp.title,
    jp.description,
    jp.barangay,
    jp.city,
    jp.budget,
    jp.scheduled_at,
    m.skill_points,
    m.location_points,
    m.rating_points,
    m.total_points,
    jp.payment_method
  FROM public.job_postings AS jp
  CROSS JOIN LATERAL private.compute_job_matches(jp.id) AS m
  WHERE jp.status = 'open'
    AND m.worker_id = v_caller
  ORDER BY
    m.total_points DESC,
    jp.scheduled_at ASC NULLS LAST,
    jp.id ASC;
END;
$$;


COMMENT ON FUNCTION public.list_my_job_opportunities() IS
  'N8-W-01 as amended by R4: authenticated Worker read API for '
  'matched job opportunities. Takes no parameter -- the caller is '
  'always auth.uid(), so there is no Worker id that could be '
  'substituted to inspect someone else. Requires an active '
  'authoritative Worker (42501 otherwise); an active but unverified, '
  'busy, or offline Worker receives zero rows rather than an error, '
  'because Stage 1 eligibility lives in private.compute_job_matches(), '
  'which this function reuses as the single source of truth for D-002 '
  'eligibility and 50/30/20 scoring. Returns open jobs only, with the '
  'caller''s own score components and the Job posting-time '
  'payment_method (cod, qrph, or NULL for legacy) -- no Client '
  'identity or contact data, no exact address, no competitor rows, no '
  'rank. Implements no acceptance or booking behavior (D-003 / N9).';


ALTER FUNCTION public.list_my_job_opportunities() OWNER TO postgres;

REVOKE ALL ON FUNCTION public.list_my_job_opportunities() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_my_job_opportunities() FROM anon;

REVOKE ALL ON FUNCTION public.list_my_job_opportunities() FROM authenticated;

REVOKE ALL ON FUNCTION public.list_my_job_opportunities() FROM service_role;

GRANT EXECUTE ON FUNCTION public.list_my_job_opportunities() TO authenticated;


-- ---------- 5. CASH ENFORCEMENT ----------
--
-- CREATE OR REPLACE: return type unchanged. A Job whose intent is
-- qrph cannot be claimed as COD. NULL Job intent keeps BL-01D dual
-- choice. Job is read, not locked or written: payment_method is
-- immutable, and COD still changes no Job row.

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
  v_job_id         uuid;
  v_job_method     text;
  v_pay_method     text;
  v_pay_status     text;
  v_rows           integer;
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to select booking payment'
      USING ERRCODE = '42501';
  END IF;

  SELECT b.status::text, b.client_id, b.job_id,
         b.payment_method::text, b.payment_status::text
    INTO v_booking_status, v_booking_client, v_job_id,
         v_pay_method, v_pay_status
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM v_caller
     OR v_booking_status IS DISTINCT FROM 'completed'
  THEN
    RAISE EXCEPTION 'this booking is not available for payment selection'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- R4: non-NULL Job intent is authoritative. qrph Jobs cannot be
  -- claimed as COD. Missing Job is the same collapsed SM409.
  -- NULL Job intent falls through to the existing tuple logic.
  ----------------------------------------------------------------
  SELECT jp.payment_method::text
    INTO v_job_method
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id;

  IF NOT FOUND OR v_job_method IS NOT DISTINCT FROM 'qrph' THEN
    RAISE EXCEPTION 'this booking is not available for payment selection'
      USING ERRCODE = 'SM409';
  END IF;

  IF v_pay_method IS NULL AND v_pay_status = 'pending' THEN

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

    NULL;

  ELSE

    RAISE EXCEPTION 'this booking is not available for payment selection'
      USING ERRCODE = 'SM409';

  END IF;

  RETURN QUERY SELECT p_booking_id, v_pay_method, v_pay_status;
END;
$$;

COMMENT ON FUNCTION public.select_my_booking_cod(uuid) IS
  'BL-01D as amended by R4: the Client chooses Cash on Delivery for '
  'one completed Booking they own. Requires an active Client account '
  '(42501 otherwise), then that the Booking exists, is the caller''s, '
  'and is completed -- all three collapsed into the SAME SM409 so the '
  'function is not a Booking-existence oracle. A Job whose posting-time '
  'payment_method is qrph is also SM409. A Job whose method is cod, or '
  'NULL (legacy), keeps the BL-01D tuple rules. Takes no payment value: '
  'the only write it can perform is payment_method = ''cod'' on a '
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


-- ---------- 6. QR PH ENFORCEMENT ----------
--
-- Return types unchanged. FRESH remains (NULL, pending, NULL). Claim
-- still writes method and paymongo_ref in one statement. A Job whose
-- intent is cod cannot be prepared or bound as QR Ph. NULL Job intent
-- keeps PM-01A dual choice.

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
  v_job_method     text;
  v_pay_method     text;
  v_pay_status     text;
  v_pay_ref        text;
  v_budget         numeric;
  v_centavos       numeric;
BEGIN
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

  SELECT b.status::text, b.client_id, b.job_id,
         b.payment_method::text, b.payment_status::text, b.paymongo_ref::text
    INTO v_booking_status, v_booking_client, v_job_id,
         v_pay_method, v_pay_status, v_pay_ref
  FROM public.bookings AS b
  WHERE b.id = p_booking_id;

  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM p_client_id
     OR v_booking_status IS DISTINCT FROM 'completed'
  THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- R4: cod Jobs cannot enter QR Ph. Read, no lock -- the Job method
  -- is immutable and this function writes nothing. NULL Job intent
  -- is legacy dual choice and continues.
  ----------------------------------------------------------------
  SELECT jp.payment_method::text, jp.budget
    INTO v_job_method, v_budget
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id;

  IF NOT FOUND OR v_job_method IS NOT DISTINCT FROM 'cod' THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment'
      USING ERRCODE = 'SM409';
  END IF;

  IF NOT (
       (v_pay_method IS NULL     AND v_pay_status = 'pending' AND v_pay_ref IS NULL)
    OR (v_pay_method = 'qrph'    AND v_pay_status = 'pending' AND v_pay_ref IS NOT NULL)
  )
  THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment'
      USING ERRCODE = 'SM409';
  END IF;

  IF v_budget IS NULL THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment'
      USING ERRCODE = 'SM409';
  END IF;

  v_centavos := v_budget * 100;

  IF v_centavos <> trunc(v_centavos)
     OR v_centavos < 100
     OR v_centavos > 9999999999
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
  'PM-01A as amended by R4: read-only preparation for a QR Ph payment. '
  'Requires an active Client id (42501 otherwise), then that the '
  'Booking exists, is that Client''s and is completed -- all three '
  'collapsed into the SAME SM409 so the function is not a '
  'Booking-existence oracle. A Job whose posting-time payment_method '
  'is cod is also SM409. A Job whose method is qrph, or NULL (legacy), '
  'keeps the PM-01A preparable tuples. Returns the payment tuple plus '
  'the authoritative amount in centavos derived from the Job budget, '
  'never from a caller. A NULL paymongo_ref means FRESH (create a '
  'Payment Intent); a non-NULL one means RESUME (reuse the stored '
  'Intent). Every other tuple -- Booking-level cod, gcash, maya, paid, '
  'refunded, and the impossible (qrph, pending, NULL) -- is refused. '
  'Writes nothing and emits no notification. service_role EXECUTE only.';

ALTER FUNCTION public.prepare_booking_qrph(uuid, uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.prepare_booking_qrph(uuid, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.prepare_booking_qrph(uuid, uuid) FROM anon;

REVOKE ALL ON FUNCTION public.prepare_booking_qrph(uuid, uuid) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.prepare_booking_qrph(uuid, uuid) TO service_role;


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
  v_job_method     text;
  v_pay_method     text;
  v_pay_status     text;
  v_pay_ref        text;
  v_budget         numeric;
  v_centavos       numeric;
  v_rows           integer;
BEGIN
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

  SELECT b.status::text, b.client_id, b.job_id,
         b.payment_method::text, b.payment_status::text, b.paymongo_ref::text
    INTO v_booking_status, v_booking_client, v_job_id,
         v_pay_method, v_pay_status, v_pay_ref
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

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

  SELECT jp.budget, jp.payment_method::text
    INTO v_budget, v_job_method
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id
  FOR SHARE;

  IF NOT FOUND
     OR v_budget IS NULL
     OR v_job_method IS NOT DISTINCT FROM 'cod'
  THEN
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

  IF p_amount_centavos <> v_centavos::bigint THEN
    RAISE EXCEPTION 'payment amount does not match the authoritative job budget'
      USING ERRCODE = '22023';
  END IF;

  -- Atomic transition: never commits (qrph, pending, NULL).
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
  'PM-01A as amended by R4: the atomic QR-07 transition. Requires an '
  'active Client id (42501), a well-formed reference/currency/amount '
  '(22023 otherwise), then -- under a row lock -- that the Booking '
  'exists, is the caller''s, is completed and is entirely unclaimed '
  '(NULL method, pending status, NULL paymongo_ref), all collapsed into '
  'one SM409. A Job whose posting-time payment_method is cod is also '
  'SM409. A Job whose method is qrph, or NULL (legacy), may be bound. '
  'Sets payment_method = ''qrph'' AND paymongo_ref in a SINGLE statement, '
  'so no (qrph, pending, NULL) state is ever committed. An existing '
  'non-NULL paymongo_ref is never replaced, which is what makes a '
  'concurrent second bind lose rather than overwrite. The amount is '
  're-derived from the Job under a FOR SHARE lock and must equal the '
  'caller''s value. Writes no payment_status, no bookings.status, no '
  'completed_at and no Job row, and emits no notification. service_role '
  'EXECUTE only.';

ALTER FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) FROM anon;

REVOKE ALL ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.claim_and_bind_booking_qrph(uuid, uuid, text, bigint, text) TO service_role;
