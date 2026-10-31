// ============================================================
// RF-02 / D-011 — booking-call-reconcile: scheduler/maintenance boundary
// ============================================================
//
// Caller: pg_cron -> pg_net every minute ({tick:true}) and the termination
// fast path ({call_id}). verify_jwt = false; the boundary is the Vault-held
// x-skillmatch-dispatch-secret (same posture as R5B). No participant
// authorization: maintenance must still work after Booking termination or
// account deactivation. Responses carry counts only.

import { reconcileTick, type Rpc } from "../_shared/call-ops.ts";
import type { RoomService } from "../_shared/livekit.ts";
import { timingSafeEqual } from "../_shared/secret.ts";

export type ReconcileDeps = {
  env: Record<string, string | undefined>;
  rpc: Rpc;
  rooms: RoomService;
  nowSeconds: () => number;
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export function isValidReconcileBody(payload: unknown): boolean {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return false;
  const r = payload as Record<string, unknown>;
  const keys = Object.keys(r);
  if (keys.length !== 1) return false;
  return (keys[0] === "tick" && r.tick === true) ||
    (keys[0] === "call_id" && typeof r.call_id === "string" && UUID_RE.test(r.call_id));
}

export async function handleReconcile(req: Request, deps: ReconcileDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "POST required" });
  const expected = deps.env.RF02_CALL_RECONCILE_SECRET;
  const supplied = req.headers.get("x-skillmatch-dispatch-secret");
  if (!expected || !supplied || !timingSafeEqual(supplied, expected)) return json(401, { error: "unauthorized" });

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "invalid request" });
  }
  if (!isValidReconcileBody(payload)) return json(400, { error: "invalid request" });
  if (!deps.env.LIVEKIT_URL || !deps.env.LIVEKIT_API_KEY || !deps.env.LIVEKIT_API_SECRET) {
    return json(503, { error: "provider unavailable" });
  }

  try {
    // ponytail: a {call_id} hint runs the same full pass; idempotent and
    // small at this scale. Targeted passes if batches ever grow.
    const summary = await reconcileTick({ rpc: deps.rpc, rooms: deps.rooms, nowSeconds: deps.nowSeconds });
    return json(200, summary);
  } catch {
    return json(500, { error: "reconcile failed" });
  }
}
