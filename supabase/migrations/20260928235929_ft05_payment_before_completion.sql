-- FT-05 #18: payment settlement precedes final Client completion.
-- Existing completed/pending rows retain payment compatibility.

CREATE OR REPLACE FUNCTION public.complete_my_client_booking(p_booking_id uuid)
RETURNS TABLE (booking_id uuid, job_id uuid, booking_status text, job_status text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_booking_status text;
  v_booking_client uuid;
  v_booking_worker uuid;
  v_payment_status text;
  v_job_id uuid;
  v_job_status text;
  v_job_client uuid;
  v_job_title text;
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to complete bookings' USING ERRCODE = '42501';
  END IF;

  SELECT b.status::text, b.client_id, b.worker_id, b.payment_status::text, b.job_id
    INTO v_booking_status, v_booking_client, v_booking_worker, v_payment_status, v_job_id
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM v_caller
     OR v_booking_status IS DISTINCT FROM 'confirmed'
  THEN
    RAISE EXCEPTION 'this booking is not available for completion' USING ERRCODE = 'SM409';
  END IF;

  SELECT jp.status::text, jp.client_id, jp.title::text
    INTO v_job_status, v_job_client, v_job_title
  FROM public.job_postings AS jp
  WHERE jp.id = v_job_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_job_status IS DISTINCT FROM 'matched'
     OR v_job_client IS DISTINCT FROM v_booking_client
  THEN
    RAISE EXCEPTION 'this booking is not available for completion' USING ERRCODE = 'SM409';
  END IF;

  IF v_payment_status IS DISTINCT FROM 'paid' THEN
    RAISE EXCEPTION 'payment must settle before final completion' USING ERRCODE = 'SM403';
  END IF;

  UPDATE public.bookings
     SET status = 'completed', completed_at = now()
   WHERE id = p_booking_id;

  UPDATE public.job_postings SET status = 'completed' WHERE id = v_job_id;

  PERFORM private.emit_notification(
    v_booking_worker,
    'booking_completed',
    'Your booking for "' || v_job_title || '" has been marked completed.'
  );

  RETURN QUERY
  SELECT b.id, b.job_id, b.status::text, jp.status::text
  FROM public.bookings AS b
  JOIN public.job_postings AS jp ON jp.id = b.job_id
  WHERE b.id = p_booking_id;
END;
$$;

COMMENT ON FUNCTION public.complete_my_client_booking(uuid) IS
  'FT-05 #18: active owning Client final-completes only a confirmed, paid, internally consistent Booking/Job pair. Locks Booking then Job, preserves every payment field, writes database completion time, completes both rows atomically, and emits one fixed Worker notification. Unpaid after ownership/lifecycle/pair proof is SM403; unavailable states are collapsed SM409.';

REVOKE ALL ON FUNCTION public.complete_my_client_booking(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_my_client_booking(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.select_my_booking_cod(p_booking_id uuid)
RETURNS TABLE (booking_id uuid, payment_method text, payment_status text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_booking_status text;
  v_booking_client uuid;
  v_job_id uuid;
  v_job_method text;
  v_pay_method text;
  v_pay_status text;
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to select booking payment' USING ERRCODE = '42501';
  END IF;

  SELECT b.status::text, b.client_id, b.job_id, b.payment_method::text, b.payment_status::text
    INTO v_booking_status, v_booking_client, v_job_id, v_pay_method, v_pay_status
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM v_caller
     OR v_booking_status NOT IN ('confirmed', 'completed')
  THEN
    RAISE EXCEPTION 'this booking is not available for payment selection' USING ERRCODE = 'SM409';
  END IF;

  SELECT jp.payment_method::text INTO v_job_method
  FROM public.job_postings AS jp WHERE jp.id = v_job_id;

  IF NOT FOUND OR v_job_method IS NOT DISTINCT FROM 'qrph' THEN
    RAISE EXCEPTION 'this booking is not available for payment selection' USING ERRCODE = 'SM409';
  END IF;

  IF v_pay_method IS NULL AND v_pay_status = 'pending' THEN
    UPDATE public.bookings SET payment_method = 'cod' WHERE id = p_booking_id;
    v_pay_method := 'cod';
  ELSIF (v_pay_method = 'cod' AND v_pay_status = 'pending') IS NOT TRUE THEN
    RAISE EXCEPTION 'this booking is not available for payment selection' USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY SELECT p_booking_id, v_pay_method, v_pay_status;
END;
$$;

COMMENT ON FUNCTION public.select_my_booking_cod(uuid) IS
  'FT-05 #18: active owning Client selects COD for a confirmed forward-lifecycle or completed legacy Booking. Only NULL/pending becomes cod/pending; cod/pending is repeat-safe. Job QR intent, paid/refunded/online tuples and unavailable records are SM409. Writes no status, provider reference, Booking lifecycle, completion time or Job row.';

REVOKE ALL ON FUNCTION public.select_my_booking_cod(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.select_my_booking_cod(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.confirm_my_cod_payment_received(p_booking_id uuid)
RETURNS TABLE (booking_id uuid, payment_method text, payment_status text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_booking_status text;
  v_booking_worker uuid;
  v_booking_client uuid;
  v_job_id uuid;
  v_job_title text;
  v_pay_method text;
  v_pay_status text;
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized to confirm cash payment' USING ERRCODE = '42501';
  END IF;

  SELECT b.status::text, b.worker_id, b.client_id, b.job_id,
         b.payment_method::text, b.payment_status::text
    INTO v_booking_status, v_booking_worker, v_booking_client, v_job_id,
         v_pay_method, v_pay_status
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_booking_worker IS DISTINCT FROM v_caller
     OR v_booking_status NOT IN ('confirmed', 'completed')
     OR v_pay_method IS DISTINCT FROM 'cod'
  THEN
    RAISE EXCEPTION 'this cash payment cannot be confirmed' USING ERRCODE = 'SM409';
  END IF;

  IF v_pay_status = 'paid' THEN
    RAISE EXCEPTION 'this cash payment has already been confirmed' USING ERRCODE = 'SM403';
  END IF;
  IF v_pay_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'this cash payment cannot be confirmed' USING ERRCODE = 'SM409';
  END IF;

  SELECT jp.title::text INTO v_job_title FROM public.job_postings AS jp WHERE jp.id = v_job_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'this cash payment cannot be confirmed' USING ERRCODE = 'SM409';
  END IF;

  UPDATE public.bookings SET payment_status = 'paid' WHERE id = p_booking_id;
  v_pay_status := 'paid';

  PERFORM private.emit_notification(
    v_booking_client,
    'payment_received',
    'Cash payment received for your job "' || v_job_title || '".'
  );

  RETURN QUERY SELECT p_booking_id, v_pay_method, v_pay_status;
END;
$$;

COMMENT ON FUNCTION public.confirm_my_cod_payment_received(uuid) IS
  'FT-05 #18: assigned active Worker alone attests COD receipt on confirmed forward-lifecycle or completed legacy Bookings. Changes only pending to paid and emits one fixed Client notification atomically. Client cannot execute and Worker cannot select method.';

REVOKE ALL ON FUNCTION public.confirm_my_cod_payment_received(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_my_cod_payment_received(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.prepare_booking_qrph(p_booking_id uuid, p_client_id uuid)
RETURNS TABLE (booking_id uuid, payment_method text, payment_status text, paymongo_ref text, amount_centavos bigint, currency text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_booking_status text; v_booking_client uuid; v_job_id uuid; v_job_method text;
  v_pay_method text; v_pay_status text; v_pay_ref text; v_budget numeric; v_centavos numeric;
BEGIN
  IF p_client_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.users WHERE id=p_client_id AND role='client' AND is_active=true
  ) THEN
    RAISE EXCEPTION 'not authorized to prepare qr ph payment' USING ERRCODE = '42501';
  END IF;

  SELECT b.status::text,b.client_id,b.job_id,b.payment_method::text,b.payment_status::text,b.paymongo_ref::text
    INTO v_booking_status,v_booking_client,v_job_id,v_pay_method,v_pay_status,v_pay_ref
  FROM public.bookings AS b WHERE b.id=p_booking_id;

  IF NOT FOUND OR v_booking_client IS DISTINCT FROM p_client_id
     OR v_booking_status NOT IN ('confirmed','completed')
  THEN RAISE EXCEPTION 'this booking is not available for qr ph payment' USING ERRCODE='SM409'; END IF;

  SELECT jp.payment_method::text,jp.budget INTO v_job_method,v_budget
  FROM public.job_postings AS jp WHERE jp.id=v_job_id;
  IF NOT FOUND OR v_job_method IS NOT DISTINCT FROM 'cod' THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment' USING ERRCODE='SM409';
  END IF;
  IF ((v_pay_method IS NULL AND v_pay_status='pending' AND v_pay_ref IS NULL)
       OR (v_pay_method='qrph' AND v_pay_status='pending' AND v_pay_ref IS NOT NULL))
     IS NOT TRUE
  THEN RAISE EXCEPTION 'this booking is not available for qr ph payment' USING ERRCODE='SM409'; END IF;
  IF v_budget IS NULL THEN RAISE EXCEPTION 'this booking is not available for qr ph payment' USING ERRCODE='SM409'; END IF;
  v_centavos:=v_budget*100;
  IF v_centavos<>trunc(v_centavos) OR v_centavos<100 OR v_centavos>9999999999 THEN
    RAISE EXCEPTION 'this booking is not available for qr ph payment' USING ERRCODE='SM409';
  END IF;
  RETURN QUERY SELECT p_booking_id,v_pay_method,v_pay_status,v_pay_ref,v_centavos::bigint,'PHP'::text;
END;
$$;

COMMENT ON FUNCTION public.prepare_booking_qrph(uuid,uuid) IS
  'FT-05 #18: service-only QR Ph preparation for confirmed forward-lifecycle or completed legacy Bookings. Preserves active Client, ownership, authoritative Job intent/budget and strict fresh/resume tuple validation. Writes nothing.';
ALTER FUNCTION public.prepare_booking_qrph(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.prepare_booking_qrph(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prepare_booking_qrph(uuid,uuid) TO service_role;


CREATE OR REPLACE FUNCTION public.claim_and_bind_booking_qrph(
  p_booking_id uuid,p_client_id uuid,p_intent_id text,p_amount_centavos bigint,p_currency text
)
RETURNS TABLE (booking_id uuid,payment_method text,payment_status text,paymongo_ref text,amount_centavos bigint,currency text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  v_intent_id text:=btrim(coalesce(p_intent_id,'')); v_booking_status text; v_booking_client uuid;
  v_job_id uuid; v_job_method text; v_pay_method text; v_pay_status text; v_pay_ref text;
  v_budget numeric; v_centavos numeric;
BEGIN
  IF v_intent_id='' OR length(v_intent_id)>100 THEN RAISE EXCEPTION 'invalid payment intent reference' USING ERRCODE='22023'; END IF;
  IF p_currency IS NULL OR upper(btrim(p_currency))<>'PHP' THEN RAISE EXCEPTION 'unsupported payment currency' USING ERRCODE='22023'; END IF;
  IF p_amount_centavos IS NULL OR p_amount_centavos<100 THEN RAISE EXCEPTION 'invalid payment amount' USING ERRCODE='22023'; END IF;
  IF p_client_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.users WHERE id=p_client_id AND role='client' AND is_active=true)
  THEN RAISE EXCEPTION 'not authorized to bind qr ph payment' USING ERRCODE='42501'; END IF;

  SELECT b.status::text,b.client_id,b.job_id,b.payment_method::text,b.payment_status::text,b.paymongo_ref::text
    INTO v_booking_status,v_booking_client,v_job_id,v_pay_method,v_pay_status,v_pay_ref
  FROM public.bookings AS b WHERE b.id=p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_booking_client IS DISTINCT FROM p_client_id
     OR v_booking_status NOT IN ('confirmed','completed')
     OR v_pay_method IS NOT NULL OR v_pay_status IS DISTINCT FROM 'pending' OR v_pay_ref IS NOT NULL
  THEN RAISE EXCEPTION 'this booking is not available for qr ph binding' USING ERRCODE='SM409'; END IF;

  SELECT jp.budget,jp.payment_method::text INTO v_budget,v_job_method
  FROM public.job_postings AS jp WHERE jp.id=v_job_id FOR SHARE;
  IF NOT FOUND OR v_budget IS NULL OR v_job_method IS NOT DISTINCT FROM 'cod'
  THEN RAISE EXCEPTION 'this booking is not available for qr ph binding' USING ERRCODE='SM409'; END IF;
  v_centavos:=v_budget*100;
  IF v_centavos<>trunc(v_centavos) OR v_centavos<100 OR v_centavos>9999999999
  THEN RAISE EXCEPTION 'this booking is not available for qr ph binding' USING ERRCODE='SM409'; END IF;
  IF p_amount_centavos<>v_centavos::bigint
  THEN RAISE EXCEPTION 'payment amount does not match the authoritative job budget' USING ERRCODE='22023'; END IF;

  UPDATE public.bookings SET payment_method='qrph',paymongo_ref=v_intent_id WHERE id=p_booking_id;
  RETURN QUERY SELECT p_booking_id,'qrph'::text,'pending'::text,v_intent_id,v_centavos::bigint,'PHP'::text;
END;
$$;

COMMENT ON FUNCTION public.claim_and_bind_booking_qrph(uuid,uuid,text,bigint,text) IS
  'FT-05 #18: service-only atomic QR Ph binding for confirmed forward-lifecycle or completed legacy Bookings. Retains active Client, ownership, authoritative amount/currency, Job intent, fresh tuple and immutable-reference controls.';
ALTER FUNCTION public.claim_and_bind_booking_qrph(uuid,uuid,text,bigint,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.claim_and_bind_booking_qrph(uuid,uuid,text,bigint,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_and_bind_booking_qrph(uuid,uuid,text,bigint,text) TO service_role;


CREATE OR REPLACE FUNCTION public.settle_booking_qrph(
  p_booking_id uuid,p_intent_id text,p_amount_centavos bigint,p_currency text,p_provider_status text
)
RETURNS TABLE (booking_id uuid,payment_method text,payment_status text,paymongo_ref text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  v_intent_id text:=btrim(coalesce(p_intent_id,'')); v_booking_status text; v_job_id uuid;
  v_pay_method text; v_pay_status text; v_pay_ref text; v_budget numeric; v_centavos numeric;
BEGIN
  IF v_intent_id='' OR length(v_intent_id)>100 THEN RAISE EXCEPTION 'invalid payment intent reference' USING ERRCODE='22023'; END IF;
  IF p_currency IS NULL OR upper(btrim(p_currency))<>'PHP' THEN RAISE EXCEPTION 'unsupported payment currency' USING ERRCODE='22023'; END IF;
  IF p_amount_centavos IS NULL OR p_amount_centavos<100 THEN RAISE EXCEPTION 'invalid payment amount' USING ERRCODE='22023'; END IF;
  IF p_provider_status IS NULL OR btrim(p_provider_status)<>'succeeded'
  THEN RAISE EXCEPTION 'this qr ph payment cannot be settled' USING ERRCODE='SM409'; END IF;

  SELECT b.status::text,b.job_id,b.payment_method::text,b.payment_status::text,b.paymongo_ref::text
    INTO v_booking_status,v_job_id,v_pay_method,v_pay_status,v_pay_ref
  FROM public.bookings AS b WHERE b.id=p_booking_id FOR UPDATE;

  IF NOT FOUND OR v_booking_status NOT IN ('confirmed','completed')
     OR v_pay_method IS DISTINCT FROM 'qrph' OR v_pay_ref IS DISTINCT FROM v_intent_id
  THEN RAISE EXCEPTION 'this qr ph payment cannot be settled' USING ERRCODE='SM409'; END IF;

  SELECT jp.budget INTO v_budget FROM public.job_postings AS jp WHERE jp.id=v_job_id FOR SHARE;
  IF NOT FOUND OR v_budget IS NULL THEN RAISE EXCEPTION 'this qr ph payment cannot be settled' USING ERRCODE='SM409'; END IF;
  v_centavos:=v_budget*100;
  IF v_centavos<>trunc(v_centavos) OR v_centavos<100 OR v_centavos>9999999999
  THEN RAISE EXCEPTION 'this qr ph payment cannot be settled' USING ERRCODE='SM409'; END IF;
  IF p_amount_centavos<>v_centavos::bigint
  THEN RAISE EXCEPTION 'payment amount does not match the authoritative job budget' USING ERRCODE='22023'; END IF;

  IF v_pay_status='paid' THEN
    RETURN QUERY SELECT p_booking_id,v_pay_method,v_pay_status,v_pay_ref; RETURN;
  END IF;
  IF v_pay_status IS DISTINCT FROM 'pending'
  THEN RAISE EXCEPTION 'this qr ph payment cannot be settled' USING ERRCODE='SM409'; END IF;

  UPDATE public.bookings SET payment_status='paid' WHERE id=p_booking_id;
  RETURN QUERY SELECT p_booking_id,v_pay_method,'paid'::text,v_pay_ref;
END;
$$;

COMMENT ON FUNCTION public.settle_booking_qrph(uuid,text,bigint,text,text) IS
  'FT-05 #18: service-only provider settlement for confirmed forward-lifecycle or completed legacy QR Ph Bookings. Cancelled, no_show and unrelated bindings are SM409. Authoritative amount/currency/reference checks and repeat-safe paid handling are preserved; only payment_status may change.';
ALTER FUNCTION public.settle_booking_qrph(uuid,text,bigint,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.settle_booking_qrph(uuid,text,bigint,text,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.settle_booking_qrph(uuid,text,bigint,text,text) TO service_role;


CREATE OR REPLACE FUNCTION public.cancel_my_booking(
  p_booking_id uuid,p_reason_code text,p_reason_detail text DEFAULT NULL
)
RETURNS TABLE (booking_id uuid,job_id uuid,booking_status text,job_status text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  v_caller uuid:=auth.uid(); v_booking_status text; v_booking_client uuid; v_booking_worker uuid;
  v_payment_method text; v_payment_status text; v_paymongo_ref text; v_job_id uuid;
  v_job_status text; v_job_client uuid; v_job_title text; v_recipient uuid; v_reason_detail text;
BEGIN
  IF v_caller IS NULL OR NOT(private.is_active_worker() OR private.is_active_client())
  THEN RAISE EXCEPTION 'not authorized to cancel bookings' USING ERRCODE='42501'; END IF;

  SELECT b.status::text,b.client_id,b.worker_id,b.payment_method::text,b.payment_status::text,b.paymongo_ref::text,b.job_id
    INTO v_booking_status,v_booking_client,v_booking_worker,v_payment_method,v_payment_status,v_paymongo_ref,v_job_id
  FROM public.bookings AS b WHERE b.id=p_booking_id FOR UPDATE;

  IF NOT FOUND OR (v_booking_client IS DISTINCT FROM v_caller AND v_booking_worker IS DISTINCT FROM v_caller)
     OR v_booking_status IS DISTINCT FROM 'confirmed'
  THEN RAISE EXCEPTION 'this booking is not available for cancellation' USING ERRCODE='SM409'; END IF;

  IF (
       (v_payment_method IS NULL AND v_payment_status='pending' AND v_paymongo_ref IS NULL)
    OR (v_payment_method='cod' AND v_payment_status='pending' AND v_paymongo_ref IS NULL)
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'this booking cannot be cancelled in its current payment state' USING ERRCODE='SM403';
  END IF;

  SELECT jp.status::text,jp.client_id,jp.title::text INTO v_job_status,v_job_client,v_job_title
  FROM public.job_postings AS jp WHERE jp.id=v_job_id FOR UPDATE;
  IF NOT FOUND OR v_job_status IS DISTINCT FROM 'matched' OR v_job_client IS DISTINCT FROM v_booking_client
  THEN RAISE EXCEPTION 'this booking is not available for cancellation' USING ERRCODE='SM409'; END IF;

  IF p_reason_code IS NULL OR p_reason_code NOT IN ('schedule_conflict','unable_to_continue','location_issue','payment_issue','other')
  THEN RAISE EXCEPTION 'invalid cancellation reason code' USING ERRCODE='22023'; END IF;
  v_reason_detail:=nullif(btrim(p_reason_detail,E' \t\n\r\f\v'),'');
  IF v_reason_detail IS NOT NULL AND char_length(v_reason_detail)>300
  THEN RAISE EXCEPTION 'invalid cancellation reason detail' USING ERRCODE='22023'; END IF;
  IF p_reason_code='other' AND v_reason_detail IS NULL
  THEN RAISE EXCEPTION 'cancellation reason detail is required for other' USING ERRCODE='22023'; END IF;

  UPDATE public.bookings SET status='cancelled',cancellation_reason_code=p_reason_code,
    cancellation_reason_detail=v_reason_detail,cancelled_by=v_caller,cancelled_at=now()
  WHERE id=p_booking_id;
  UPDATE public.job_postings SET status='cancelled' WHERE id=v_job_id;
  v_recipient:=CASE WHEN v_caller=v_booking_client THEN v_booking_worker ELSE v_booking_client END;
  PERFORM private.emit_notification(v_recipient,'booking_cancelled','The booking for "'||v_job_title||'" has been cancelled.');
  RETURN QUERY SELECT b.id,b.job_id,b.status::text,jp.status::text
  FROM public.bookings b JOIN public.job_postings jp ON jp.id=b.job_id WHERE b.id=p_booking_id;
END;
$$;

COMMENT ON FUNCTION public.cancel_my_booking(uuid,text,text) IS
  'FT-05 #18 over V4 #19-BE1: participant cancellation remains reason-aware and terminal, but is allowed only for exact fresh pending or COD pending tuples. Bound QR Ph, paid, refunded and malformed tuples fail closed with SM403 after participant/lifecycle proof. Locks Booking then Job and preserves every payment field.';
REVOKE ALL ON FUNCTION public.cancel_my_booking(uuid,text,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_my_booking(uuid,text,text) TO authenticated;
