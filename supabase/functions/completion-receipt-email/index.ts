// ============================================================
// Lane C: completion-receipt-email Edge Function entry (Deno wiring)
// ============================================================
//
// Proposed config.toml: [functions.completion-receipt-email] verify_jwt = false.
// Boundary: x-skillmatch-dispatch-secret == SKILLMATCH_DISPATCH_WEBHOOK_SECRET.
// Provider: Gmail SMTP (GMAIL_SMTP_USER, GMAIL_SMTP_APP_PASSWORD, optional
// EMAIL_FROM_NAME; see _shared/gmail-mailer.ts). Owner decision 2026-11-05.
// Requires the service_role-only RPCs proposed in the Lane C approvals file:
//   get_completion_receipt_context, claim_outbound_dispatch, finish_outbound_dispatch.
// Sends only when COMPLETION_RECEIPT_ENABLED is exactly "true".

import { createClient } from "npm:@supabase/supabase-js@2";
import { gmailConfig } from "../_shared/gmail-mailer.ts";
import { createGmailSender } from "../_shared/gmail-transport.ts";
import { handleReceiptRequest } from "./handler.ts";

function env(name: string): string | undefined {
  const value = Deno.env.get(name)?.trim();
  return value ? value : undefined;
}

export function serve(req: Request): Promise<Response> {
  const url = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return Promise.resolve(
      new Response(JSON.stringify({ error: "server configuration incomplete" }), {
        status: 500,
        headers: { "content-type": "application/json" },
      }),
    );
  }
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return handleReceiptRequest(req, {
    env: {
      webhookSecret: env("SKILLMATCH_DISPATCH_WEBHOOK_SECRET"),
      enabled: env("COMPLETION_RECEIPT_ENABLED"),
    },
    send: (() => {
      const config = gmailConfig(env);
      return config ? createGmailSender(config) : null;
    })(),
    getContext: async (bookingId) => {
      const { data, error } = await admin.rpc("get_completion_receipt_context", {
        p_booking_id: bookingId,
      });
      if (error) throw new Error("context unavailable");
      return Array.isArray(data) && data.length === 1 ? data[0] : null;
    },
    claim: async (dedupKey, bookingId, maxAttempts) => {
      const { data, error } = await admin.rpc("claim_outbound_dispatch", {
        p_dedup_key: dedupKey,
        p_kind: "completion_receipt",
        p_booking_id: bookingId,
        p_max_attempts: maxAttempts,
      });
      if (error) throw new Error("ledger unavailable");
      return data === true;
    },
    finish: async (dedupKey, sent, providerRef, error) => {
      await admin.rpc("finish_outbound_dispatch", {
        p_dedup_key: dedupKey,
        p_sent: sent,
        p_provider_ref: providerRef,
        p_error: error,
      });
    },
  });
}

if (import.meta.main) Deno.serve(serve);
