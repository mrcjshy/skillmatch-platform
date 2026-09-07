// ============================================================
// PM-01C: QR PH SERVER RECONCILIATION (Edge Function)
// ============================================================
//
// ############################################################
// #  TEST MODE ONLY.                                         #
// #                                                          #
// #  livemode = true is refused. This function never scans a #
// #  QR, never opens a test_url and never simulates a        #
// #  payment -- it only asks PayMongo what already happened. #
// ############################################################
//
// SCOPE
// -----
// The client-driven half of settlement, and the reason a missed webhook
// is not a stuck payment. The signed-in Client asks "is my payment
// through yet?"; this function reads the authoritative Booking, asks
// PayMongo about the Intent already bound to it, and -- only if PayMongo
// itself says `succeeded` -- settles through the SAME
// public.settle_booking_qrph the webhook uses.
//
// It observes and settles. It never initiates: no Payment Intent, no
// Payment Method, no QR, no replacement paymongo_ref. Regenerating a QR
// remains PM-01B's initiate/resume behaviour.
//
//
// THE CLIENT CANNOT ASSERT PAYMENT
// --------------------------------
// The request body carries `booking_id` and nothing else. There is no
// amount, status, provider status, Intent id or client id parameter, so
// a tampered client cannot claim a payment succeeded -- there is no
// field through which to say it. The only thing a caller controls is
// WHICH Booking is refreshed, and ownership is re-checked before
// anything is read from the provider.
//
// `verify_jwt = true` rejects unauthenticated calls, but under this
// project's key model it also accepts the publishable key that ships in
// the APK, so it is necessary and NOT sufficient. The handler resolves
// the real caller with auth.getUser(), requires an active `client` role,
// and requires that the Booking is theirs.
//
//
// WHY THE PAID BRANCH DOES NOT GO THROUGH prepare_booking_qrph
// ------------------------------------------------------------
// PM-01A's prepare_booking_qrph accepts exactly two tuples -- FRESH
// (NULL, pending, NULL) and RESUME (qrph, pending, pi_...) -- and fails
// closed on an already-paid Booking. That is correct for initiation and
// wrong for a status refresh, which must be able to answer "already
// paid". So authorization here is done directly: the caller's own role
// row, plus a participant-scoped read of the Booking whose client_id
// must equal the resolved user. No new RPC and no migration.
//
// QR-11 holds: settlement emits NO notification.

import { createClient } from "npm:@supabase/supabase-js@2";

const PAYMONGO_API = "https://api.paymongo.com/v1";
const PROVIDER_TIMEOUT_MS = 15_000;

/* ------------------------------------------------------------------ *
 * Environment -- same tolerant lookup order as PM-01B and the webhook.
 * ------------------------------------------------------------------ */

function firstEnv(...names: string[]): string | undefined {
  for (const name of names) {
    const raw = Deno.env.get(name);
    if (!raw) continue;
    const value = raw.trim();
    if (value === "") continue;
    if (value.startsWith("[")) {
      try {
        const parsed = JSON.parse(value);
        if (Array.isArray(parsed) && typeof parsed[0] === "string") {
          return parsed[0].trim();
        }
      } catch {
        // fall through to the raw value
      }
    }
    if (name.endsWith("_KEYS") && value.includes(",")) {
      return value.split(",")[0].trim();
    }
    return value;
  }
  return undefined;
}

const SUPABASE_URL = firstEnv("SUPABASE_URL");
const SUPABASE_CALLER_KEY = firstEnv(
  "SUPABASE_ANON_KEY",
  "SUPABASE_PUBLISHABLE_KEY",
  "SUPABASE_PUBLISHABLE_KEYS",
);
const SUPABASE_SERVER_KEY = firstEnv(
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_SECRET_KEY",
  "SUPABASE_SECRET_KEYS",
);

/* ------------------------------------------------------------------ *
 * Pure helpers -- exported for local verification.
 * ------------------------------------------------------------------ */

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

/**
 * Only these three shapes are meaningful to a refresh:
 *
 *   paid       already settled -- answer without touching the provider
 *   settleable qrph + pending + a bound Intent -- ask PayMongo
 *   no         anything else (cod, gcash, maya, refunded, unbound qrph)
 *
 * An unbound `qrph` Booking is deliberately NOT settleable: with no
 * Intent there is nothing to reconcile against, and inventing one would
 * be initiation.
 */
export function classifyPayment(
  method: string | null,
  status: string | null,
  ref: string | null,
): "paid" | "settleable" | "no" {
  if (method === "qrph" && status === "paid") return "paid";
  if (method === "qrph" && status === "pending" && typeof ref === "string" && ref !== "") {
    return "settleable";
  }
  return "no";
}

/**
 * The stored Intent must independently say the payment succeeded.
 * Identical requirements to the webhook's validator -- duplicated rather
 * than shared, because the two functions deploy separately and a shared
 * module would couple their release cycles.
 */
export function validateSucceededIntent(
  payload: unknown,
  expectedIntentId: string,
): { ok: true; amount: number } | { ok: false; reason: string } {
  const data = (payload as { data?: Record<string, unknown> } | null)?.data;
  if (!data || typeof data !== "object") return { ok: false, reason: "shape" };
  if (data.type !== "payment_intent") return { ok: false, reason: "type" };
  if (typeof data.id !== "string" || data.id.trim() !== expectedIntentId) {
    return { ok: false, reason: "id_mismatch" };
  }

  const attrs = data.attributes as Record<string, unknown> | undefined;
  if (!attrs || typeof attrs !== "object") return { ok: false, reason: "attributes" };
  if (attrs.livemode !== false) return { ok: false, reason: "livemode" };
  if (typeof attrs.currency !== "string" || attrs.currency.toUpperCase() !== "PHP") {
    return { ok: false, reason: "currency" };
  }
  if (typeof attrs.amount !== "number" || !Number.isInteger(attrs.amount) || attrs.amount < 100) {
    return { ok: false, reason: "amount" };
  }
  if (attrs.status !== "succeeded") return { ok: false, reason: "not_succeeded" };

  return { ok: true, amount: attrs.amount };
}

/* ------------------------------------------------------------------ *
 * Responses
 * ------------------------------------------------------------------ */

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function fail(status: number, code: string, message: string): Response {
  return json(status, { error: { code, message } });
}

/* ------------------------------------------------------------------ *
 * PayMongo read -- server-side, secret key only, never logged.
 * ------------------------------------------------------------------ */

async function retrieveIntent(secret: string, intentId: string): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);
  try {
    const res = await fetch(
      `${PAYMONGO_API}/payment_intents/${encodeURIComponent(intentId)}`,
      {
        method: "GET",
        signal: controller.signal,
        headers: {
          Authorization: `Basic ${btoa(`${secret}:`)}`,
          "content-type": "application/json",
        },
      },
    );
    if (!res.ok) throw new Error(`provider status ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

/* ------------------------------------------------------------------ *
 * Handler
 * ------------------------------------------------------------------ */

/**
 * One collapsed refusal for every "you may not refresh this Booking"
 * cause: not yours, does not exist, not a QR Ph Booking, not in a
 * settleable state. Keeping them indistinguishable stops this endpoint
 * being used to probe for other participants' Bookings.
 */
const UNAVAILABLE = "this booking is not available for payment reconciliation";

export async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return fail(405, "method_not_allowed", "POST required");
  }

  if (!SUPABASE_URL || !SUPABASE_CALLER_KEY || !SUPABASE_SERVER_KEY) {
    return fail(500, "server_misconfigured", "server configuration incomplete");
  }

  // ---------- 1. Caller identity ----------
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return fail(401, "unauthenticated", "authentication required");

  const callerClient = createClient(SUPABASE_URL, SUPABASE_CALLER_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await callerClient.auth.getUser();
  const user = userData?.user;
  if (userError || !user?.id) {
    // Closes the verify_jwt gap: a project anon key satisfies the
    // platform but resolves to no user and stops here.
    return fail(401, "unauthenticated", "authentication required");
  }
  const clientId = user.id;

  // ---------- 2. Input ----------
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return fail(400, "invalid_request", "booking_id is required");
  }
  const bookingId = (body as { booking_id?: unknown } | null)?.booking_id;
  if (!isUuid(bookingId)) {
    return fail(400, "invalid_request", "booking_id is required");
  }
  // Every other field is ignored on purpose. Nothing but the Booking id
  // may influence this request -- least of all a claim about payment.

  const paymongoSecret = firstEnv("PAYMONGO_SECRET_KEY");
  if (!paymongoSecret) {
    return fail(500, "server_misconfigured", "payment provider not configured");
  }

  try {
    // ---------- 3. The caller must be an active Client ----------
    // `users` SELECT is own-row-only, so this reads the caller's own row
    // through their own session -- no elevated read of anyone else.
    const { data: me, error: meError } = await callerClient
      .from("users")
      .select("role, is_active")
      .eq("id", clientId)
      .maybeSingle();
    if (meError || !me || me.role !== "client" || me.is_active !== true) {
      return fail(403, "forbidden", "you are not allowed to do that");
    }

    // ---------- 4. The Booking must be theirs ----------
    // Read through the caller's session, so RLS restricts it to Bookings
    // they participate in; client_id is then compared explicitly,
    // because a Worker is also a participant and must not reconcile.
    const { data: booking, error: bookingError } = await callerClient
      .from("bookings")
      .select("id, client_id, status, payment_method, payment_status, paymongo_ref")
      .eq("id", bookingId)
      .maybeSingle();
    if (bookingError) return fail(500, "server_error", "unexpected server error");
    if (!booking || booking.client_id !== clientId) {
      return fail(409, "booking_unavailable", UNAVAILABLE);
    }

    const method = (booking.payment_method as string | null) ?? null;
    const status = (booking.payment_status as string | null) ?? null;
    const ref = (booking.paymongo_ref as string | null) ?? null;
    const state = classifyPayment(method, status, ref);

    // ---------- 5. Already settled ----------
    if (state === "paid") {
      // Authoritative and final. No provider call, no settlement.
      return json(200, { booking_id: booking.id, payment_status: "paid", settled: false });
    }

    if (state === "no") {
      return fail(409, "booking_unavailable", UNAVAILABLE);
    }

    // ---------- 6. Ask the provider about the bound Intent ----------
    const intentId = ref as string;
    let intent: unknown;
    try {
      intent = await retrieveIntent(paymongoSecret, intentId);
    } catch {
      return fail(502, "provider_unavailable", "payment provider unavailable");
    }

    const check = validateSucceededIntent(intent, intentId);
    if (!check.ok) {
      // Not succeeded yet -- or not a usable Intent. Either way the
      // Booking stays pending, and the answer is the authoritative
      // state, not an error the app has to interpret.
      return json(200, { booking_id: booking.id, payment_status: "pending", settled: false });
    }

    // ---------- 7. The single trusted settlement path ----------
    // Same RPC the webhook calls, with the PROVIDER's amount so PM-01A
    // can compare it against the Job's own budget independently.
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVER_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { error: settleError } = await admin
      .rpc("settle_booking_qrph", {
        p_booking_id: booking.id,
        p_intent_id: intentId,
        p_amount_centavos: check.amount,
        p_currency: "PHP",
        p_provider_status: "succeeded",
      })
      .maybeSingle();

    if (settleError) {
      if (settleError.code === "SM409" || settleError.code === "22023") {
        return fail(409, "booking_unavailable", UNAVAILABLE);
      }
      return fail(500, "server_error", "unexpected server error");
    }

    return json(200, { booking_id: booking.id, payment_status: "paid", settled: true });
  } catch {
    return fail(500, "server_error", "unexpected server error");
  }
}

// Guarded so the module can be imported for local verification without
// binding a port.
if (import.meta.main) {
  Deno.serve(handleRequest);
}
