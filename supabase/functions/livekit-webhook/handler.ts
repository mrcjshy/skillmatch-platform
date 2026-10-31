// ============================================================
// RF-02 / D-011 — livekit-webhook: provider-signed hint boundary
// ============================================================
//
// verify_jwt = false (the caller is LiveKit). The boundary is the provider's
// HS256-signed Authorization JWT plus its sha256 body claim. Delivery is not
// guaranteed and may repeat, so an event is only a hint: it triggers the
// same idempotent reconciliation pass and never changes call state itself.

import { verifyWebhook } from "../_shared/livekit.ts";

export type WebhookDeps = {
  env: Record<string, string | undefined>;
  lookupCall: (roomName: string) => Promise<string | null>;
  reconcile: () => Promise<void>;
  nowSeconds: () => number;
};

const HINT_EVENTS = new Set(["room_finished", "participant_left", "participant_connection_aborted"]);

export async function handleWebhook(req: Request, deps: WebhookDeps): Promise<Response> {
  if (req.method !== "POST") return new Response(null, { status: 405 });
  const { LIVEKIT_API_KEY, LIVEKIT_API_SECRET } = deps.env;
  if (!LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) return new Response(null, { status: 503 });
  const body = await req.text();
  const event = await verifyWebhook({
    apiKey: LIVEKIT_API_KEY,
    apiSecret: LIVEKIT_API_SECRET,
    authHeader: req.headers.get("authorization"),
    body,
    nowSeconds: deps.nowSeconds(),
  });
  if (event === null) return new Response(null, { status: 401 });

  const room = (event.room as { name?: unknown } | undefined)?.name;
  if (typeof event.event === "string" && HINT_EVENTS.has(event.event) && typeof room === "string") {
    if (await deps.lookupCall(room)) await deps.reconcile();
  }
  return new Response(null, { status: 200 });
}
