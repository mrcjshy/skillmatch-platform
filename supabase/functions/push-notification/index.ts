// ============================================================
// R5B: PUSH NOTIFICATION DISPATCH (Edge Function)
// ============================================================
//
// Webhook-only. verify_jwt is false because the caller is pg_net,
// not a signed-in user. The boundary is x-skillmatch-push-secret
// compared to R5B_PUSH_WEBHOOK_SECRET.
//
// The request body is an identifier only. Recipients, tokens, and
// copy are re-read from public.get_notification_push_targets.
//
// Push is a delivery hint. Provider failure must not imply a
// business rollback — the notification row already exists.

import { createClient } from "npm:@supabase/supabase-js@2";

const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";
const PROVIDER_TIMEOUT_MS = 15_000;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const TYPE_TITLES: Record<string, string> = {
  booking_request: "Booking request",
  booking_confirmed: "Booking confirmed",
  booking_cancelled: "Booking cancelled",
  booking_completed: "Booking completed",
  no_show_strike: "Attendance update",
  account_suspended: "Account update",
  payment_received: "Payment received",
  worker_verified: "Verification update",
};

export type PushTarget = {
  notification_id: string;
  notification_type: string;
  notification_message: string;
  expo_push_token: string;
};

export type HandlerOverrides = {
  fetchImpl?: typeof fetch;
  adminRpc?: (
    fn: string,
    args: Record<string, unknown>,
  ) => Promise<{ data: PushTarget[] | null; error: { message?: string } | null }>;
  env?: Record<string, string | undefined>;
};

function firstEnv(
  env: Record<string, string | undefined> | undefined,
  ...names: string[]
): string | undefined {
  const read = (name: string): string | undefined => {
    if (env && Object.prototype.hasOwnProperty.call(env, name)) {
      const raw = env[name];
      if (raw == null) return undefined;
      const value = raw.trim();
      return value === "" ? undefined : value;
    }
    const raw = Deno.env.get(name);
    if (!raw) return undefined;
    const value = raw.trim();
    return value === "" ? undefined : value;
  };

  for (const name of names) {
    const value = read(name);
    if (!value) continue;
    if (value.startsWith("[")) {
      try {
        const parsed = JSON.parse(value);
        if (Array.isArray(parsed) && typeof parsed[0] === "string") {
          return parsed[0].trim();
        }
      } catch {
        // use the raw value
      }
    }
    if (name.endsWith("_KEYS") && value.includes(",")) {
      return value.split(",")[0].trim();
    }
    return value;
  }
  return undefined;
}

export function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const len = Math.max(x.length, y.length);
  for (let i = 0; i < len; i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

export function notificationTitle(type: string): string {
  return TYPE_TITLES[type] ?? "SkillMatch";
}

export function parseNotificationId(payload: unknown):
  | { ok: true; notificationId: string }
  | { ok: false; reason: string } {
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
    return { ok: false, reason: "shape" };
  }
  const keys = Object.keys(payload as Record<string, unknown>);
  if (keys.length !== 1 || keys[0] !== "notification_id") {
    return { ok: false, reason: "fields" };
  }
  const id = (payload as { notification_id?: unknown }).notification_id;
  if (typeof id !== "string" || !UUID_RE.test(id)) {
    return { ok: false, reason: "uuid" };
  }
  return { ok: true, notificationId: id };
}

export function buildExpoMessages(targets: PushTarget[]): Array<{
  to: string;
  sound: "default";
  title: string;
  body: string;
  data: { notification_id: string };
}> {
  return targets.map((row) => ({
    to: row.expo_push_token,
    sound: "default" as const,
    title: notificationTitle(row.notification_type),
    body: row.notification_message,
    data: { notification_id: row.notification_id },
  }));
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function denied(): Response {
  return json(401, {
    error: { code: "unauthorized", message: "request not authorized" },
  });
}

export async function handleRequest(
  req: Request,
  overrides: HandlerOverrides = {},
): Promise<Response> {
  if (req.method !== "POST") {
    return json(405, { error: { code: "method_not_allowed", message: "POST required" } });
  }

  const env = overrides.env;
  const webhookSecret = firstEnv(env, "R5B_PUSH_WEBHOOK_SECRET");
  const expoAccessToken = firstEnv(env, "EXPO_ACCESS_TOKEN");
  const supabaseUrl = firstEnv(env, "SUPABASE_URL");
  const supabaseServerKey = firstEnv(
    env,
    "SUPABASE_SERVICE_ROLE_KEY",
    "SUPABASE_SECRET_KEY",
    "SUPABASE_SECRET_KEYS",
  );

  if (!webhookSecret) {
    return json(500, {
      error: { code: "server_misconfigured", message: "server configuration incomplete" },
    });
  }

  const supplied = req.headers.get("x-skillmatch-push-secret");
  if (typeof supplied !== "string" || !timingSafeEqual(supplied, webhookSecret)) {
    return denied();
  }

  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return json(400, { error: { code: "invalid_request", message: "json required" } });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(await req.text());
  } catch {
    return json(400, { error: { code: "invalid_request", message: "malformed body" } });
  }

  const parsed = parseNotificationId(payload);
  if (!parsed.ok) {
    return json(400, { error: { code: "invalid_request", message: "invalid notification_id" } });
  }

  if (!overrides.adminRpc && (!supabaseUrl || !supabaseServerKey)) {
    return json(500, {
      error: { code: "server_misconfigured", message: "server configuration incomplete" },
    });
  }

  let targets: PushTarget[] = [];
  try {
    const rpc = overrides.adminRpc
      ?? (async (fn: string, args: Record<string, unknown>) => {
        const admin = createClient(supabaseUrl!, supabaseServerKey!, {
          auth: { persistSession: false, autoRefreshToken: false },
        });
        return await admin.rpc(fn, args);
      });
    const { data, error } = await rpc("get_notification_push_targets", {
      p_notification_id: parsed.notificationId,
    });
    if (error) {
      return json(503, { error: { code: "unavailable", message: "try again" } });
    }
    targets = Array.isArray(data) ? data : [];
  } catch {
    return json(503, { error: { code: "unavailable", message: "try again" } });
  }

  if (targets.length === 0) {
    return json(200, { received: true, delivered: 0 });
  }

  if (!expoAccessToken) {
    return json(500, {
      error: { code: "server_misconfigured", message: "server configuration incomplete" },
    });
  }

  const messages = buildExpoMessages(targets);
  const fetchImpl = overrides.fetchImpl ?? fetch;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);
    try {
      const res = await fetchImpl(EXPO_PUSH_URL, {
        method: "POST",
        signal: controller.signal,
        headers: {
          "content-type": "application/json",
          Authorization: `Bearer ${expoAccessToken}`,
        },
        body: JSON.stringify(messages),
      });
      if (!res.ok) {
        return json(200, { received: true, delivered: false });
      }
    } finally {
      clearTimeout(timer);
    }
    return json(200, { received: true, delivered: messages.length });
  } catch {
    return json(200, { received: true, delivered: false });
  }
}

if (import.meta.main) {
  Deno.serve((req) => handleRequest(req));
}
