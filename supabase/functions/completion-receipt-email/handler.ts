// ============================================================
// Lane C: completion receipt email dispatcher (I/O injected)
// ============================================================
//
// Caller: the proposed AFTER UPDATE trigger on public.bookings
// (status -> 'completed') via pg_net, body exactly {"booking_id": uuid},
// header x-skillmatch-dispatch-secret. verify_jwt is false; the shared
// secret is the boundary (R5B posture). A manual retry re-POSTs the same
// body with the same secret.
//
// Recipient, amount, method, payment status and completion time are all
// re-read server-side. The booking's completion is already committed
// before this runs; nothing here mutates the booking, and every email
// failure is reported as {sent:false} without affecting it.
//
// Dedup: durable ledger key completion-receipt:<booking_id>, which is
// also the Resend Idempotency-Key. "sent" in the response means the
// provider accepted the request, never that an inbox received it.

import {
  buildReceiptDedupKey,
  buildReceiptEmail,
  parseReceiptRequest,
  validateContext,
} from "./receipt.ts";

export const RESEND_URL = "https://api.resend.com/emails";
export const MAX_ATTEMPTS_PER_RECEIPT = 3;
const PROVIDER_TIMEOUT_MS = 15_000;

export type ReceiptDeps = {
  env: {
    webhookSecret?: string;
    resendApiKey?: string;
    from?: string;
    /** Must be exactly "true" to send. */
    enabled?: string;
  };
  /** public.get_completion_receipt_context(p_booking_id) first row, or null. */
  getContext: (bookingId: string) => Promise<unknown | null>;
  claim: (dedupKey: string, bookingId: string, maxAttempts: number) => Promise<boolean>;
  finish: (dedupKey: string, sent: boolean, providerRef: string | null, error: string | null) => Promise<void>;
  fetchImpl?: typeof fetch;
};

export function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const len = Math.max(x.length, y.length);
  for (let i = 0; i < len; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleReceiptRequest(req: Request, deps: ReceiptDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "POST required" });
  const secret = deps.env.webhookSecret?.trim();
  if (!secret) return json(500, { error: "server configuration incomplete" });
  const supplied = req.headers.get("x-skillmatch-dispatch-secret");
  if (typeof supplied !== "string" || !timingSafeEqual(supplied, secret)) {
    return json(401, { error: "unauthorized" });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(await req.text());
  } catch {
    return json(400, { error: "invalid request" });
  }
  const parsed = parseReceiptRequest(payload);
  if (!parsed) return json(400, { error: "invalid request" });

  if (deps.env.enabled !== "true") return json(200, { sent: false, reason: "disabled" });
  const resendKey = deps.env.resendApiKey?.trim();
  const from = deps.env.from?.trim();
  if (!resendKey || !from) return json(503, { sent: false, reason: "not_configured" });

  let context;
  try {
    context = validateContext(await deps.getContext(parsed.bookingId), parsed.bookingId);
  } catch {
    return json(503, { sent: false, reason: "unavailable" });
  }
  // Not completed, unverified email, inconsistent pair or unknown booking:
  // collapsed to one answer so the endpoint is not a booking oracle.
  if (!context) return json(200, { sent: false, reason: "not_eligible" });

  const key = buildReceiptDedupKey(parsed.bookingId);
  let claimed: boolean;
  try {
    claimed = await deps.claim(key, parsed.bookingId, MAX_ATTEMPTS_PER_RECEIPT);
  } catch {
    // Without the durable ledger there is no send (fail closed).
    return json(503, { sent: false, reason: "unavailable" });
  }
  if (!claimed) return json(200, { sent: false, reason: "duplicate" });

  const email = buildReceiptEmail(context);
  const fetchImpl = deps.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);
  try {
    const res = await fetchImpl(RESEND_URL, {
      method: "POST",
      signal: controller.signal,
      headers: {
        authorization: `Bearer ${resendKey}`,
        "content-type": "application/json",
        "idempotency-key": key,
      },
      body: JSON.stringify({
        from,
        to: [email.to],
        subject: email.subject,
        text: email.text,
        html: email.html,
      }),
    });
    if (!res.ok) {
      await deps.finish(key, false, null, `http_${res.status}`).catch(() => {});
      return json(200, { sent: false, reason: "provider_rejected" });
    }
    let providerRef: string | null = null;
    try {
      const body = await res.json() as { id?: unknown };
      providerRef = typeof body?.id === "string" ? body.id.slice(0, 200) : null;
    } catch {
      providerRef = null;
    }
    await deps.finish(key, true, providerRef, null).catch(() => {});
    return json(200, { sent: true });
  } catch {
    await deps.finish(key, false, null, "network").catch(() => {});
    return json(200, { sent: false, reason: "provider_unreachable" });
  } finally {
    clearTimeout(timer);
  }
}
