-- Booking completion receipt email (owner request 2026-11-05: "an email receipt after the booking
-- completed"). Implements the Lane C approval design of 2026-10-14 (C-email-reminders-approvals.md,
-- sections 4a and 4b) unchanged except where noted:
--
--   * private.outbound_dispatches: a dedup ledger (infrastructure, no recipient, token or content).
--   * claim_outbound_dispatch / finish_outbound_dispatch: service_role-only ledger RPCs.
--   * get_completion_receipt_context: service_role-only read of one completed booking for the
--     Client receipt. The email comes from auth.users and only when it is confirmed. No Worker name
--     or contact and no exact address (R3B terminal privacy). Client only (owner, 2026-11-05).
--   * An AFTER UPDATE trigger on public.bookings: when status becomes 'completed' it POSTs
--     {booking_id} to the completion-receipt-email Edge Function with the dispatch secret, both
--     read from Vault. It fails open: an email or HTTP problem never blocks or undoes a completion,
--     and with no Vault config it does nothing.
--
-- The Edge Function re-reads everything server-side and sends through Gmail SMTP only when
-- COMPLETION_RECEIPT_ENABLED is exactly "true".

CREATE TABLE private.outbound_dispatches (
  dedup_key        text PRIMARY KEY CHECK (char_length(dedup_key) BETWEEN 1 AND 300),
  kind             text NOT NULL CHECK (kind IN ('completion_receipt', 'worker_reminder')),
  booking_id       uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  status           text NOT NULL DEFAULT 'claimed' CHECK (status IN ('claimed', 'sent', 'failed')),
  attempts         integer NOT NULL DEFAULT 1 CHECK (attempts BETWEEN 1 AND 10),
  provider_ref     text CHECK (provider_ref IS NULL OR char_length(provider_ref) <= 200),
  last_error       text CHECK (last_error IS NULL OR char_length(last_error) <= 200),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.outbound_dispatches OWNER TO postgres;
ALTER TABLE private.outbound_dispatches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.outbound_dispatches FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE private.outbound_dispatches IS
  'Dedup ledger for the completion receipt email (and future Worker reminders). Infrastructure, not a D-001 application table. No recipient address, token or content stored.';

-- Claim a send. Returns true only for the caller that may send now.
-- New key -> insert claimed. 'failed' with attempts < p_max_attempts -> reclaim.
-- 'claimed' older than 10 minutes (crashed sender) -> reclaim. 'sent' -> false.
CREATE OR REPLACE FUNCTION public.claim_outbound_dispatch(
  p_dedup_key text, p_kind text, p_booking_id uuid, p_max_attempts integer)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_claimed boolean := false;
BEGIN
  INSERT INTO private.outbound_dispatches (dedup_key, kind, booking_id)
  VALUES (p_dedup_key, p_kind, p_booking_id)
  ON CONFLICT (dedup_key) DO NOTHING;
  IF FOUND THEN RETURN true; END IF;
  UPDATE private.outbound_dispatches AS d
     SET status = 'claimed', attempts = d.attempts + 1, updated_at = now()
   WHERE d.dedup_key = p_dedup_key
     AND d.attempts < LEAST(GREATEST(p_max_attempts, 1), 10)
     AND (d.status = 'failed'
          OR (d.status = 'claimed' AND d.updated_at < now() - interval '10 minutes'))
  RETURNING true INTO v_claimed;
  RETURN coalesce(v_claimed, false);
END; $$;

CREATE OR REPLACE FUNCTION public.finish_outbound_dispatch(
  p_dedup_key text, p_sent boolean, p_provider_ref text, p_error text)
RETURNS void LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
  UPDATE private.outbound_dispatches
     SET status = CASE WHEN p_sent THEN 'sent' ELSE 'failed' END,
         provider_ref = left(p_provider_ref, 200),
         last_error = left(p_error, 200),
         updated_at = now()
   WHERE dedup_key = p_dedup_key AND status = 'claimed';
$$;

ALTER FUNCTION public.claim_outbound_dispatch(text, text, uuid, integer) OWNER TO postgres;
ALTER FUNCTION public.finish_outbound_dispatch(text, boolean, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.claim_outbound_dispatch(text, text, uuid, integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finish_outbound_dispatch(text, boolean, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_outbound_dispatch(text, text, uuid, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.finish_outbound_dispatch(text, boolean, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.get_completion_receipt_context(p_booking_id uuid)
RETURNS TABLE (booking_id uuid, booking_status text, completed_at timestamptz,
  payment_method text, payment_status text, job_title text, job_barangay text,
  job_city text, job_budget numeric, client_full_name text, client_email text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT b.id, b.status::text, b.completed_at, b.payment_method::text, b.payment_status::text,
         jp.title::text, jp.barangay::text, jp.city::text, jp.budget,
         u.full_name, au.email::text
  FROM public.bookings b
  JOIN public.job_postings jp ON jp.id = b.job_id AND jp.client_id = b.client_id
  JOIN public.users u ON u.id = b.client_id AND u.role = 'client'
  JOIN auth.users au ON au.id = b.client_id AND au.email_confirmed_at IS NOT NULL
  WHERE b.id = p_booking_id AND b.status = 'completed' AND b.completed_at IS NOT NULL;
$$;
ALTER FUNCTION public.get_completion_receipt_context(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_completion_receipt_context(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_completion_receipt_context(uuid) TO service_role;

CREATE OR REPLACE FUNCTION private.dispatch_booking_completed_receipt()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_endpoint text; v_secret text;
BEGIN
  SELECT ds.decrypted_secret INTO v_endpoint FROM vault.decrypted_secrets AS ds
   WHERE ds.name = 'completion_receipt_endpoint' LIMIT 1;
  SELECT ds.decrypted_secret INTO v_secret FROM vault.decrypted_secrets AS ds
   WHERE ds.name = 'skillmatch_dispatch_webhook_secret' LIMIT 1;
  IF v_endpoint IS NULL OR btrim(v_endpoint) = '' OR v_secret IS NULL OR btrim(v_secret) = '' THEN
    RAISE WARNING 'completion receipt dispatch skipped: vault config missing';
    RETURN NULL;
  END IF;
  BEGIN
    PERFORM net.http_post(
      url := btrim(v_endpoint),
      body := jsonb_build_object('booking_id', NEW.id),
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'x-skillmatch-dispatch-secret', v_secret),
      timeout_milliseconds := 5000);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'completion receipt dispatch request failed';
  END;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'completion receipt dispatch failed open';
  RETURN NULL;
END; $$;
ALTER FUNCTION private.dispatch_booking_completed_receipt() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.dispatch_booking_completed_receipt() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER dispatch_booking_completed_receipt
  AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW
  WHEN (NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed')
  EXECUTE FUNCTION private.dispatch_booking_completed_receipt();
