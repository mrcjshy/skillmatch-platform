// ============================================================
// PM-01B: QR Ph PAYMENT INITIATION (Edge Function)
// ============================================================
//
// ############################################################
// #  TEST MODE ONLY.                                         #
// #                                                          #
// #  PayMongo test-mode QR Ph generates REAL QR codes.       #
// #  DO NOT scan the generated QR with GCash, Maya, a bank   #
// #  app, or any real QR Ph payer. Doing so moves real       #
// #  money. Simulate outcomes with PayMongo's test_url only. #
// #                                                          #
// #  livemode = true is rejected outright below.             #
// ############################################################
//
// SCOPE
// -----
// The trusted server boundary QR-04 locks between the Expo app and
// PayMongo. The app sends a Booking id and nothing else; this function
// establishes who is calling, asks the database what the payment is
// worth, talks to PayMongo, and binds the resulting Payment Intent
// through PM-01A's service_role-only RPCs.
//
// It does NOT settle payments. `pending -> paid` belongs to PM-01C via
// public.settle_booking_qrph, driven by a signature-verified webhook or
// server reconciliation. This function must never call it.
//
//
// WHY verify_jwt = true IS NOT ENOUGH ON ITS OWN
// ----------------------------------------------
// `verify_jwt = true` makes the platform reject requests carrying no
// valid project JWT. Under this project's key model that check also
// accepts the publishable/anon key itself -- and that key ships inside
// the APK. So platform verification is necessary but NOT sufficient:
// the handler additionally resolves the caller with auth.getUser() and
// refuses to continue unless a real user comes back. `p_client_id` is
// taken ONLY from that resolved user id, never from the request body.
//
// The database then revalidates independently (active Client, and the
// Booking is theirs), so a bug in this function still cannot pay an
// arbitrary Booking. The DB does not authenticate the JWT; this
// function establishes identity and the DB re-checks authorization.
//
//
// THE ONE AUTHORITATIVE INTENT (QR-07, as amended)
// ------------------------------------------------
// The Payment Intent is created BEFORE any Booking payment state is
// committed, then one atomic RPC claims and binds it:
//
//     (NULL, pending, NULL)  ->  ('qrph', pending, pi_...)
//
// A concurrent loser is refused by that RPC. Its Intent is never
// attached, so it never becomes a payable QR -- it is simply an orphan.
// It is NOT claimed that only one provider Intent can ever be created;
// the guarantee is that only one can ever become the Booking's stored
// paymongo_ref, and every attach targets THAT stored reference.
//
//
// PROVIDER FACTS PROVEN AGAINST PAYMONGO TEST MODE (2026-09-07)
// -------------------------------------------------------------
//   1. Secret-key-only flow WORKS. Creating the Payment Intent, creating
//      the QR Ph Payment Method, retrieving the Intent and ATTACHING all
//      succeed with `sk_test_` alone -- no `client_key` in the attach
//      body, and no public key anywhere. So only one PayMongo secret is
//      needed and `client_key` is never stored, returned or required.
//   2. `test_url` lives at exactly
//         data.attributes.next_action.code.test_url
//      alongside `image_url` and `expires_at`. extractTestUrl() reads
//      that path and only that path.
//   3. QR-09 holds: after the QR expires, attaching a NEW QR Ph Payment
//      Method to the SAME Payment Intent returns a fresh QR and a new
//      expires_at, with the Intent id unchanged. No replacement Intent
//      is ever needed.
//
// The one surprise, and why the RESUME branch checks a timestamp rather
// than a status: an expired QR does NOT change the Intent status. It
// stays `awaiting_next_action` with next_action still populated, so only
// next_action.code.expires_at can tell a live QR from a dead one.
//
// None of this changed the database architecture.

import { createClient } from "npm:@supabase/supabase-js@2";

const PAYMONGO_API = "https://api.paymongo.com/v1";
const PROVIDER_TIMEOUT_MS = 15_000;

/* ------------------------------------------------------------------ *
 * Environment
 *
 * Tolerant of both the legacy (ANON/SERVICE_ROLE) and the newer
 * (PUBLISHABLE/SECRET) injected names, because which pair this
 * project's Edge Runtime provides is an implementation-time fact. This
 * is deliberately a lookup order, NOT a key-architecture migration.
 * ------------------------------------------------------------------ */

function firstEnv(...names: string[]): string | undefined {
  for (const name of names) {
    const raw = Deno.env.get(name);
    if (!raw) continue;
    const value = raw.trim();
    if (value === "") continue;
    // The plural *_KEYS variants may arrive as a JSON array or a
    // comma-separated list; take the first entry.
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
 * Pure helpers -- exported so they can be verified locally without
 * contacting PayMongo or Supabase.
 * ------------------------------------------------------------------ */

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

/**
 * PM-01A speaks the project's stable SQLSTATE taxonomy. Map it without
 * widening it: SM409 stays collapsed so this endpoint cannot be used as
 * a Booking-existence oracle.
 */
export function httpStatusForDbError(code: string | null | undefined): number {
  switch (code) {
    case "42501":
      return 403;
    case "SM409":
      return 409;
    case "22023":
      return 400;
    default:
      return 500;
  }
}

export type IntentCheck =
  | { ok: true; id: string; status: string; clientKey: string | null }
  | { ok: false; reason: string };

/**
 * Everything that must be true before a provider Intent id is allowed
 * anywhere near bookings.paymongo_ref. The amount is compared against
 * the database's own derivation -- the provider's number is never the
 * source of truth.
 */
export function validateProviderIntent(
  payload: unknown,
  expectedCentavos: number,
): IntentCheck {
  const root = payload as { data?: Record<string, unknown> } | null;
  const data = root?.data;
  if (!data || typeof data !== "object") return { ok: false, reason: "shape" };

  if (data.type !== "payment_intent") return { ok: false, reason: "type" };

  const id = data.id;
  if (typeof id !== "string" || id.trim() === "") {
    return { ok: false, reason: "id" };
  }
  // bookings.paymongo_ref is varchar(100); PM-01A also fails closed.
  if (id.trim().length > 100) return { ok: false, reason: "id_length" };

  const attrs = data.attributes as Record<string, unknown> | undefined;
  if (!attrs || typeof attrs !== "object") return { ok: false, reason: "attributes" };

  if (attrs.livemode !== false) return { ok: false, reason: "livemode" };

  if (typeof attrs.currency !== "string" || attrs.currency.toUpperCase() !== "PHP") {
    return { ok: false, reason: "currency" };
  }

  if (typeof attrs.amount !== "number" || !Number.isInteger(attrs.amount)) {
    return { ok: false, reason: "amount_shape" };
  }
  if (attrs.amount !== expectedCentavos) return { ok: false, reason: "amount_mismatch" };

  const allowed = attrs.payment_method_allowed;
  if (!Array.isArray(allowed) || !allowed.includes("qrph")) {
    return { ok: false, reason: "qrph_not_allowed" };
  }

  const status = typeof attrs.status === "string" ? attrs.status : "";
  if (status === "") return { ok: false, reason: "status" };

  const clientKey = typeof attrs.client_key === "string" ? attrs.client_key : null;

  return { ok: true, id: id.trim(), status, clientKey };
}

/** The one QR path PayMongo actually documents. */
export function extractQrImage(payload: unknown): string | null {
  const attrs = (payload as { data?: { attributes?: Record<string, unknown> } })
    ?.data?.attributes;
  const nextAction = attrs?.next_action as { code?: { image_url?: unknown } } | undefined;
  const image = nextAction?.code?.image_url;
  return typeof image === "string" && image !== "" ? image : null;
}

/**
 * PROVEN against a genuine PayMongo TEST-mode attach response
 * (2026-09-07). The path is exactly:
 *
 *     data.attributes.next_action.code.test_url        (string)
 *
 * Read from that path only -- no recursive "find any URL" search and no
 * guessed fallbacks. Returned transiently so the client can trigger
 * PayMongo's own simulator; never logged, never persisted.
 *
 * Never scan the generated QR: a test-mode QR Ph code is a real code.
 */
export function extractTestUrl(payload: unknown): string | null {
  const attrs = (payload as { data?: { attributes?: Record<string, unknown> } })
    ?.data?.attributes;
  const nextAction = attrs?.next_action as { code?: { test_url?: unknown } } | undefined;
  const url = nextAction?.code?.test_url;
  return typeof url === "string" && url !== "" ? url : null;
}

/**
 * PROVEN (2026-09-07): when a QR expires, the Payment Intent status does
 * NOT change -- it stays `awaiting_next_action` with `next_action` still
 * populated. The status therefore cannot distinguish a live QR from a
 * dead one; `next_action.code.expires_at` is the only discriminator.
 *
 * Treats an unreadable or absent expiry as expired, so the failure mode
 * is regenerating a QR rather than showing the user one that can never
 * be paid.
 */
export function qrExpired(payload: unknown, now: number = Date.now()): boolean {
  const attrs = (payload as { data?: { attributes?: Record<string, unknown> } })
    ?.data?.attributes;
  const nextAction = attrs?.next_action as { code?: { expires_at?: unknown } } | undefined;
  const raw = nextAction?.code?.expires_at;
  if (typeof raw !== "string" || raw === "") return true;
  const at = Date.parse(raw);
  if (Number.isNaN(at)) return true;
  return at <= now;
}

/* ------------------------------------------------------------------ *
 * Errors and responses
 * ------------------------------------------------------------------ */

class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

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
 * PayMongo client -- server-side only, secret key only.
 *
 * The Authorization header is built per request and never logged. No
 * raw provider body is ever returned to the app.
 * ------------------------------------------------------------------ */

async function paymongo(
  secret: string,
  method: "GET" | "POST",
  path: string,
  body?: unknown,
): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);
  try {
    const res = await fetch(`${PAYMONGO_API}${path}`, {
      method,
      signal: controller.signal,
      headers: {
        // btoa is sufficient: PayMongo keys are ASCII.
        Authorization: `Basic ${btoa(`${secret}:`)}`,
        "content-type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const payload = await res.json().catch(() => null);
    if (!res.ok) {
      // Provider status only. The body may name the account or the key.
      throw new HttpError(502, "provider_rejected", `provider status ${res.status}`);
    }
    return payload;
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(502, "provider_unavailable", "payment provider unavailable");
  } finally {
    clearTimeout(timer);
  }
}

function createIntent(secret: string, centavos: number): Promise<unknown> {
  return paymongo(secret, "POST", "/payment_intents", {
    data: {
      attributes: {
        amount: centavos,
        currency: "PHP",
        payment_method_allowed: ["qrph"],
        description: "SkillMatch booking payment",
      },
    },
  });
}

function retrieveIntent(secret: string, intentId: string): Promise<unknown> {
  // Secret key needs no client_key query parameter, which is why no
  // client_key is ever persisted.
  return paymongo(secret, "GET", `/payment_intents/${encodeURIComponent(intentId)}`);
}

function createQrphPaymentMethod(secret: string): Promise<unknown> {
  // expiry_seconds deliberately omitted -- PayMongo's default (30 min)
  // is taken. No defense benefit justifies customizing it.
  return paymongo(secret, "POST", "/payment_methods", {
    data: { attributes: { type: "qrph" } },
  });
}

function attachPaymentMethod(
  secret: string,
  intentId: string,
  paymentMethodId: string,
): Promise<unknown> {
  return paymongo(
    secret,
    "POST",
    `/payment_intents/${encodeURIComponent(intentId)}/attach`,
    { data: { attributes: { payment_method: paymentMethodId } } },
  );
}

function providerObjectId(payload: unknown): string | null {
  const id = (payload as { data?: { id?: unknown } })?.data?.id;
  return typeof id === "string" && id.trim() !== "" ? id.trim() : null;
}

/* ------------------------------------------------------------------ *
 * Handler
 * ------------------------------------------------------------------ */

type PreparedRow = {
  booking_id: string;
  payment_method: string | null;
  payment_status: string | null;
  paymongo_ref: string | null;
  amount_centavos: number | string;
  currency: string;
};

export async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return fail(405, "method_not_allowed", "POST required");
  }

  if (!SUPABASE_URL || !SUPABASE_CALLER_KEY || !SUPABASE_SERVER_KEY) {
    // Names only -- never the values.
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
    // This is the check that closes the verify_jwt gap: an anon-key JWT
    // satisfies the platform but resolves to no user and stops here.
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
  // Every other field in the body is ignored on purpose. Nothing but the
  // Booking id may influence this request.

  // Checked only AFTER the caller is authenticated and the input is
  // valid, so an unauthenticated probe cannot learn whether the payment
  // provider is configured.
  const paymongoSecret = firstEnv("PAYMONGO_SECRET_KEY");
  if (!paymongoSecret) {
    return fail(500, "server_misconfigured", "payment provider not configured");
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVER_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  async function prepare(): Promise<PreparedRow> {
    const { data, error } = await admin
      .rpc("prepare_booking_qrph", { p_booking_id: bookingId, p_client_id: clientId })
      .maybeSingle();
    if (error) {
      throw new HttpError(
        httpStatusForDbError(error.code),
        "booking_unavailable",
        "this booking is not available for qr ph payment",
      );
    }
    if (!data) {
      throw new HttpError(409, "booking_unavailable", "this booking is not available for qr ph payment");
    }
    return data as PreparedRow;
  }

  try {
    // ---------- 3. Authoritative state and amount ----------
    let prepared = await prepare();
    const centavos = Number(prepared.amount_centavos);
    if (!Number.isInteger(centavos) || centavos < 100) {
      throw new HttpError(409, "booking_unavailable", "this booking is not available for qr ph payment");
    }

    // The reference the rest of this request must obey. After a FRESH
    // bind it is the Intent we just created; after a lost race it is the
    // WINNER's. Every attach below targets this value, never a local one.
    let authoritativeIntentId: string;
    let providerStatus: string;
    let attachPayload: unknown = null;

    if (prepared.paymongo_ref === null) {
      // ---------- FRESH ----------
      const created = await createIntent(paymongoSecret, centavos);
      const check = validateProviderIntent(created, centavos);
      if (!check.ok) {
        throw new HttpError(502, "provider_rejected", "payment provider returned an unusable intent");
      }

      const { data: bound, error: bindError } = await admin
        .rpc("claim_and_bind_booking_qrph", {
          p_booking_id: bookingId,
          p_client_id: clientId,
          p_intent_id: check.id,
          p_amount_centavos: centavos,
          p_currency: "PHP",
        })
        .maybeSingle();

      if (bindError) {
        if (bindError.code !== "SM409") {
          throw new HttpError(
            httpStatusForDbError(bindError.code),
            "booking_unavailable",
            "this booking is not available for qr ph payment",
          );
        }
        // Lost the race (or the Booking moved on). Re-read authoritative
        // state. If another request won, its Intent is now stored and
        // ours becomes an orphan: never attached, therefore never
        // payable. We continue against the winner only.
        prepared = await prepare();
        if (prepared.paymongo_ref === null) {
          throw new HttpError(409, "booking_unavailable", "this booking is not available for qr ph payment");
        }
        authoritativeIntentId = prepared.paymongo_ref;
      } else {
        const boundRef = (bound as { paymongo_ref?: unknown } | null)?.paymongo_ref;
        if (typeof boundRef !== "string" || boundRef === "") {
          throw new HttpError(500, "server_error", "unexpected server error");
        }
        authoritativeIntentId = boundRef;
      }
    } else {
      // ---------- RESUME ----------
      authoritativeIntentId = prepared.paymongo_ref;
    }

    // ---------- 4. Read the authoritative Intent ----------
    const intent = await retrieveIntent(paymongoSecret, authoritativeIntentId);
    const check = validateProviderIntent(intent, centavos);
    if (!check.ok || check.id !== authoritativeIntentId) {
      throw new HttpError(502, "provider_rejected", "stored payment intent failed validation");
    }
    providerStatus = check.status;

    // ---------- 5. Status-driven action ----------
    // No branch here creates a replacement Payment Intent, and none
    // settles anything -- settlement is PM-01C's alone.
    if (providerStatus === "awaiting_payment_method") {
      const method = await createQrphPaymentMethod(paymongoSecret);
      const methodId = providerObjectId(method);
      if (!methodId) {
        throw new HttpError(502, "provider_rejected", "payment provider returned an unusable payment method");
      }
      attachPayload = await attachPaymentMethod(paymongoSecret, authoritativeIntentId, methodId);
      const after = validateProviderIntent(attachPayload, centavos);
      providerStatus = after.ok ? after.status : providerStatus;
    } else if (providerStatus === "awaiting_next_action") {
      // A QR already exists on this Intent -- but it may be a dead one.
      //
      // PROVEN (2026-09-07): an expired QR leaves the Intent status at
      // `awaiting_next_action` with next_action still populated, so the
      // status cannot be trusted to mean "payable". expires_at decides.
      //
      // When it has passed, QR-09 applies exactly as locked: attach a
      // NEW QR Ph Payment Method to the SAME Payment Intent -- proven to
      // return a fresh QR and a new expires_at, with the Intent id
      // unchanged. No replacement Intent is ever created, and
      // paymongo_ref is untouched.
      if (qrExpired(intent)) {
        const method = await createQrphPaymentMethod(paymongoSecret);
        const methodId = providerObjectId(method);
        if (!methodId) {
          throw new HttpError(502, "provider_rejected", "payment provider returned an unusable payment method");
        }
        attachPayload = await attachPaymentMethod(paymongoSecret, authoritativeIntentId, methodId);
        const after = validateProviderIntent(attachPayload, centavos);
        providerStatus = after.ok ? after.status : providerStatus;
      } else {
        attachPayload = intent;
      }
    }
    // processing / succeeded: attach nothing, create nothing, settle
    // nothing. The response reports provider_status so the app can ask
    // the user to refresh; PM-01C owns the paid transition.

    const qrImage = attachPayload ? extractQrImage(attachPayload) : null;

    return json(200, {
      booking_id: prepared.booking_id,
      amount_centavos: centavos,
      currency: "PHP",
      payment_status: prepared.payment_status ?? "pending",
      provider_status: providerStatus,
      qr_image: qrImage,
      // Read from the provider-proven path. Transient only: never logged
      // and never persisted. TEST MODE -- never scan the QR itself.
      test_url: extractTestUrl(attachPayload),
    });
  } catch (err) {
    if (err instanceof HttpError) return fail(err.status, err.code, err.message);
    return fail(500, "server_error", "unexpected server error");
  }
}

// Guarded so the module can be imported for local verification without
// binding a port. The Supabase edge runtime loads this file as the entry
// module, so the server still starts when deployed.
if (import.meta.main) {
  Deno.serve(handleRequest);
}
