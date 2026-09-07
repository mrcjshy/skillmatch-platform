// ============================================================
// PM-01C: PAYMONGO WEBHOOK (Edge Function)
// ============================================================
//
// ############################################################
// #  TEST MODE ONLY.                                         #
// #                                                          #
// #  Only a livemode = false event may change SkillMatch     #
// #  state. A live event is acknowledged and ignored, never  #
// #  settled. Nothing here scans a QR or opens a test_url.   #
// ############################################################
//
// SCOPE
// -----
// The provider-driven half of settlement. PayMongo POSTs a signed
// `payment.paid` event; this function proves the event really came from
// PayMongo, finds the Booking the named Payment Intent is bound to,
// re-reads that Intent from PayMongo itself, and only then asks the
// database to move `pending -> paid` through PM-01A's
// public.settle_booking_qrph.
//
// It never creates a Payment Intent, a Payment Method or a QR -- that is
// PM-01B's alone -- and it never writes `bookings` directly.
//
//
// WHY verify_jwt = false HERE, AND WHY THAT IS NOT A HOLE
// -------------------------------------------------------
// The caller is PayMongo, which has no Supabase user JWT, so platform
// JWT verification cannot be the boundary. The boundary is the provider
// signature instead, and it is checked BEFORE the body is parsed, before
// any database read and before any provider call. An unsigned or badly
// signed request never reaches a single line of business logic.
//
// This is the opposite trade to initiate-qrph-payment, where
// verify_jwt = true is necessary but insufficient and auth.getUser() does
// the real work. Here there is no user at all: the signature IS the
// authentication.
//
//
// SIGNATURE CONTRACT (researched and recorded in the PM-01B preflight)
// --------------------------------------------------------------------
//   header  Paymongo-Signature
//   value   t=<unix seconds>,te=<hex digest>,li=<hex digest>
//   signed  <t> + "." + <raw request body>
//   digest  HMAC-SHA256 keyed with PAYMONGO_WEBHOOK_SECRET
//
// `te` is the TEST-mode digest and `li` the live one. Pre-defense this
// project verifies `te` and treats a live-only signature as unverified:
// accepting `li` would mean a live event could be authenticated, and no
// live event may touch hosted state before the defense.
//
// The raw body is read ONCE as text and hashed exactly as received.
// Re-serialising parsed JSON would change bytes (key order, spacing,
// number formatting) and break the digest -- which is why the parse
// happens strictly after verification.
//
//
// WHY THE INTENT IS RE-READ EVEN THOUGH THE EVENT IS SIGNED
// ---------------------------------------------------------
// A valid signature proves ORIGIN, not that the payload still describes
// current provider truth. Settlement therefore converges on the stored
// Payment Intent: this function retrieves it with the secret key and
// requires `status = succeeded` there. A replayed or stale event whose
// Intent has not actually succeeded settles nothing.
//
//
// IDEMPOTENCY
// -----------
// There is no event-deduplication table, deliberately. PM-01A's
// settle_booking_qrph takes a row lock and treats an already-paid
// Booking as a repeat-safe no-op that writes nothing, so PayMongo may
// retry delivery freely. That RPC is the idempotency boundary.
//
// QR-11 holds: settlement emits NO notification.

import { createClient } from "npm:@supabase/supabase-js@2";

const PAYMONGO_API = "https://api.paymongo.com/v1";
const PROVIDER_TIMEOUT_MS = 15_000;
/** Replay window on the signature timestamp, in seconds. */
const MAX_SKEW_SECONDS = 300;

/* ------------------------------------------------------------------ *
 * Environment
 *
 * Same tolerant lookup order PM-01B uses, for the same reason: which
 * key-name pair this project's Edge Runtime injects is an
 * implementation-time fact, not an architecture choice. Duplicated
 * rather than shared because PM-01B is closed and proven, and reopening
 * it to extract a helper would put a verified function back in scope.
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
const SUPABASE_SERVER_KEY = firstEnv(
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_SECRET_KEY",
  "SUPABASE_SECRET_KEYS",
);

/* ------------------------------------------------------------------ *
 * Pure helpers -- exported so they can be verified locally without
 * contacting PayMongo or Supabase.
 * ------------------------------------------------------------------ */

export type SignatureParts = { t: string; te: string | null; li: string | null };

/**
 * Splits `t=...,te=...,li=...` into its parts. Unknown keys are ignored
 * rather than rejected, so PayMongo adding a field later does not turn
 * every delivery into a 401. A missing or empty `t` is fatal.
 */
export function parseSignatureHeader(header: string | null): SignatureParts | null {
  if (typeof header !== "string" || header.trim() === "") return null;
  let t = "";
  let te: string | null = null;
  let li: string | null = null;
  for (const piece of header.split(",")) {
    const eq = piece.indexOf("=");
    if (eq <= 0) continue;
    const key = piece.slice(0, eq).trim();
    const value = piece.slice(eq + 1).trim();
    if (value === "") continue;
    if (key === "t") t = value;
    else if (key === "te") te = value;
    else if (key === "li") li = value;
  }
  if (t === "") return null;
  return { t, te, li };
}

/**
 * The signature timestamp must be a plain unix-seconds integer inside
 * the replay window. A malformed value is rejected rather than coerced.
 */
export function isFreshTimestamp(
  t: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
  maxSkew: number = MAX_SKEW_SECONDS,
): boolean {
  if (!/^\d{1,15}$/.test(t)) return false;
  const ts = Number(t);
  if (!Number.isFinite(ts)) return false;
  return Math.abs(nowSeconds - ts) <= maxSkew;
}

/**
 * Constant-time hex digest comparison.
 *
 * A plain `===` on a digest short-circuits at the first differing
 * character, which leaks how much of a forged signature was correct and
 * makes the digest guessable byte by byte. This walks the full length
 * every time and folds the length check into the same accumulator, so
 * neither a wrong length nor an early divergence changes the work done.
 */
export function timingSafeEqualHex(a: string, b: string): boolean {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  let diff = x.length ^ y.length;
  const len = Math.max(x.length, y.length);
  for (let i = 0; i < len; i++) {
    const cx = i < x.length ? x.charCodeAt(i) : 0;
    const cy = i < y.length ? y.charCodeAt(i) : 0;
    diff |= cx ^ cy;
  }
  return diff === 0;
}

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** HMAC-SHA256 of `<t>.<rawBody>` keyed with the webhook signing secret. */
export async function computeSignature(
  secret: string,
  t: string,
  rawBody: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${t}.${rawBody}`),
  );
  return toHex(mac);
}

/**
 * The whole signature decision in one place, so the test matrix can
 * exercise it directly: header present, timestamp fresh, TEST digest
 * present, digest matches the body exactly as received.
 *
 * `li` is deliberately never accepted. A live-signed event is treated as
 * unverified pre-defense.
 */
export async function verifyWebhookSignature(
  secret: string,
  header: string | null,
  rawBody: string,
  nowSeconds?: number,
): Promise<boolean> {
  const parts = parseSignatureHeader(header);
  if (parts === null) return false;
  if (!isFreshTimestamp(parts.t, nowSeconds)) return false;
  if (parts.te === null) return false;
  if (!/^[0-9a-fA-F]{64}$/.test(parts.te)) return false;
  const expected = await computeSignature(secret, parts.t, rawBody);
  return timingSafeEqualHex(parts.te, expected);
}

export type PaidEvent = {
  intentId: string;
  amountCentavos: number;
  currency: string;
};

/**
 * Extracts the facts a settlement needs from a `payment.paid` event, or
 * explains why the event is not settleable. Returns `ignore` for a
 * validly signed event this piece simply does not handle, and `reject`
 * for one that is handled but fails a TEST-mode invariant.
 */
export function readPaidEvent(
  payload: unknown,
): { kind: "paid"; event: PaidEvent } | { kind: "ignore" } | { kind: "reject"; reason: string } {
  const attrs = (payload as { data?: { attributes?: Record<string, unknown> } })
    ?.data?.attributes;
  if (!attrs || typeof attrs !== "object") return { kind: "ignore" };

  if (attrs.type !== "payment.paid") return { kind: "ignore" };
  // A live event is refused rather than ignored: it is the type this
  // function handles, and silently 200-ing it would hide a real
  // misconfiguration.
  if (attrs.livemode !== false) return { kind: "reject", reason: "livemode" };

  const resource = attrs.data as { type?: unknown; attributes?: Record<string, unknown> } | undefined;
  if (!resource || typeof resource !== "object") return { kind: "reject", reason: "resource" };
  if (resource.type !== "payment") return { kind: "ignore" };

  const ra = resource.attributes;
  if (!ra || typeof ra !== "object") return { kind: "reject", reason: "resource_attributes" };
  if (ra.status !== "paid") return { kind: "reject", reason: "payment_status" };
  if (ra.livemode !== false) return { kind: "reject", reason: "payment_livemode" };

  const intentId = ra.payment_intent_id;
  if (typeof intentId !== "string" || intentId.trim() === "") {
    return { kind: "reject", reason: "payment_intent_id" };
  }
  // bookings.paymongo_ref is varchar(100); PM-01A fails closed too.
  if (intentId.trim().length > 100) return { kind: "reject", reason: "intent_id_length" };

  const amount = ra.amount;
  if (typeof amount !== "number" || !Number.isInteger(amount) || amount < 100) {
    return { kind: "reject", reason: "amount" };
  }

  const currency = typeof ra.currency === "string" ? ra.currency.toUpperCase() : "";
  if (currency !== "PHP") return { kind: "reject", reason: "currency" };

  return { kind: "paid", event: { intentId: intentId.trim(), amountCentavos: amount, currency } };
}

/**
 * The stored Payment Intent, re-read from PayMongo, must independently
 * say the payment succeeded. Mirrors PM-01B's validator but requires
 * `succeeded` rather than merely a well-formed Intent.
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

  const allowed = attrs.payment_method_allowed;
  if (!Array.isArray(allowed) || !allowed.includes("qrph")) {
    return { ok: false, reason: "qrph_not_allowed" };
  }

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

export async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return json(405, { error: { code: "method_not_allowed", message: "POST required" } });
  }

  // ---------- 1. Raw body, read exactly once ----------
  // Hashed as received. NOT parsed yet -- parsing before verification
  // would run attacker-controlled input through the JSON reader and
  // would also lose the exact bytes the digest covers.
  const rawBody = await req.text();

  const webhookSecret = firstEnv("PAYMONGO_WEBHOOK_SECRET");
  const paymongoSecret = firstEnv("PAYMONGO_SECRET_KEY");
  if (!SUPABASE_URL || !SUPABASE_SERVER_KEY || !webhookSecret || !paymongoSecret) {
    // Names only -- never the values.
    return json(500, {
      error: { code: "server_misconfigured", message: "server configuration incomplete" },
    });
  }

  // ---------- 2. Signature, before anything else ----------
  const verified = await verifyWebhookSignature(
    webhookSecret,
    req.headers.get("Paymongo-Signature"),
    rawBody,
  );
  if (!verified) {
    // One answer for every cause: missing header, stale timestamp,
    // live-only signature, malformed digest, tampered body, wrong
    // secret. Naming the failing part would help forge the next attempt.
    return json(401, {
      error: { code: "invalid_webhook_signature", message: "signature verification failed" },
    });
  }

  // ---------- 3. Only now is the body parsed ----------
  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return json(400, { error: { code: "invalid_request", message: "malformed event body" } });
  }

  const read = readPaidEvent(payload);
  if (read.kind === "ignore") {
    // Genuine PayMongo event this piece does not handle. Acknowledged so
    // the provider stops retrying; nothing is mutated.
    return json(200, { received: true, ignored: true });
  }
  if (read.kind === "reject") {
    // Handled type, failed a TEST-mode invariant (including livemode).
    return json(400, { error: { code: "event_not_settleable", message: "event cannot be settled" } });
  }
  const event = read.event;

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVER_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // ---------- 4. The Payment Intent is the binding ----------
    const { data: rows, error: lookupError } = await admin
      .from("bookings")
      .select("id, paymongo_ref")
      .eq("paymongo_ref", event.intentId);

    if (lookupError) {
      // Let PayMongo retry rather than losing a real payment.
      return json(503, { error: { code: "unavailable", message: "try again" } });
    }
    const matches = Array.isArray(rows) ? rows : [];
    if (matches.length === 0) {
      // A valid event for an Intent this system never bound. Not an
      // error and not actionable.
      return json(200, { received: true, ignored: true });
    }
    if (matches.length > 1) {
      // Two Bookings sharing one Payment Intent breaks QR-07's whole
      // premise. Refuse to guess which one to pay.
      return json(500, {
        error: { code: "invariant_violation", message: "ambiguous payment binding" },
      });
    }
    const bookingId = matches[0].id as string;

    // ---------- 5. Converge on the provider's own truth ----------
    // A signature proves origin, not currency of state. A replayed or
    // stale event whose Intent has not succeeded settles nothing.
    let intent: unknown;
    try {
      intent = await retrieveIntent(paymongoSecret, event.intentId);
    } catch {
      return json(503, { error: { code: "unavailable", message: "try again" } });
    }
    const check = validateSucceededIntent(intent, event.intentId);
    if (!check.ok) {
      return json(409, {
        error: { code: "not_settleable", message: "this payment cannot be settled yet" },
      });
    }
    // The event and the Intent must agree. A disagreement is a real
    // anomaly, not something to resolve by preferring one number.
    if (check.amount !== event.amountCentavos) {
      return json(409, {
        error: { code: "not_settleable", message: "this payment cannot be settled yet" },
      });
    }

    // ---------- 6. The single trusted settlement path ----------
    // The amount passed is the PROVIDER's, deliberately: PM-01A
    // re-derives the authoritative amount from the Job and refuses a
    // mismatch. Passing a Job-derived figure here would make that check
    // compare a value against itself.
    const { error: settleError } = await admin
      .rpc("settle_booking_qrph", {
        p_booking_id: bookingId,
        p_intent_id: event.intentId,
        p_amount_centavos: check.amount,
        p_currency: "PHP",
        p_provider_status: "succeeded",
      })
      .maybeSingle();

    if (settleError) {
      // SM409/22023 are DETERMINISTIC refusals: the binding, amount,
      // currency or payment state means this event may not settle this
      // Booking, and redelivering the identical signed event cannot
      // change any of that.
      //
      // PayMongo retries every non-2xx, so answering 4xx here would buy
      // an endless redelivery loop for a condition no retry can repair.
      // The correct answer to the provider is therefore "received, and I
      // did not settle it" -- a 2xx that stops the retries -- NOT a
      // failure, and NOT a fabricated settlement. The RPC already
      // wrote nothing, and it is not called again.
      //
      // The SQLSTATE and the specific reason are deliberately not
      // returned: PayMongo has no use for them, and they would describe
      // internal Booking state to an external party.
      if (settleError.code === "SM409" || settleError.code === "22023") {
        return json(200, { received: true, settled: false });
      }
      // Anything else may be transient; 5xx so PayMongo retries.
      return json(503, { error: { code: "unavailable", message: "try again" } });
    }

    // Duplicate deliveries land here too: settle_booking_qrph treats an
    // already-paid Booking as a no-op, so this is correct for both the
    // first delivery and the fifth.
    return json(200, { received: true, settled: true });
  } catch {
    return json(500, { error: { code: "server_error", message: "unexpected server error" } });
  }
}

// Guarded so the module can be imported for local verification without
// binding a port.
if (import.meta.main) {
  Deno.serve(handleRequest);
}
