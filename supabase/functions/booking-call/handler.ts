// ============================================================
// RF-02 / D-011 — booking-call: the participant-facing call API
// ============================================================
//
// Boundary: the signed-in participant's JWT (verify_jwt = true, and the
// handler resolves the real user, because a project key also satisfies
// verify_jwt). Participant authorization is enforced in SQL (rf02_start /
// rf02_act); this function never decides who may act.
//
// Request: POST {action, booking_id?, call_id?} with exactly the keys the
// action needs.
//   start {booking_id}   status {booking_id?}
//   accept|decline|cancel|end|away|back|rejoin {call_id}
// Response: {ok?, reason?, call, token?, url?, server_now}
//
// Tokens are minted only after authorized acceptance, through accept/rejoin.
// Starting an invitation never gives either participant a media token.
// The invitation push is sent at most once per call (rf02_call_claim_invite)
// and only after the room is known to exist.

import { cleanupCall, provisionCall, RpcFailure, rpcData, type CallDeps, type Rpc } from "../_shared/call-ops.ts";
import { mintJoinToken, type RoomService } from "../_shared/livekit.ts";

export type PushMessage = {
  to: string;
  title: string;
  body: string;
  data: { kind: "call"; booking_id: string; call_id: string };
  ttl: number;
  priority: "high";
  channelId: string;
};

export type BookingCallDeps = {
  env: Record<string, string | undefined>;
  resolveUser: (jwt: string) => Promise<string | null>;
  rpc: Rpc;
  rooms: RoomService;
  sendPush: (messages: PushMessage[]) => Promise<boolean>;
  nowSeconds: () => number;
};

type CallView = {
  call_id: string;
  booking_id: string;
  room_name: string;
  caller_id?: string;
  callee_id?: string;
  role: "caller" | "callee";
  state: string;
  provision_state: string;
  provision_attempts: number;
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CALL_ACTIONS = ["accept", "decline", "cancel", "end", "away", "back", "rejoin"] as const;
type Parsed =
  | { action: "start"; bookingId: string }
  | { action: "status"; bookingId: string | null }
  | { action: typeof CALL_ACTIONS[number]; callId: string };

export function parseCallRequest(payload: unknown): Parsed | null {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return null;
  const r = payload as Record<string, unknown>;
  const keys = Object.keys(r).sort().join(",");
  const id = (v: unknown) => typeof v === "string" && UUID_RE.test(v) ? v : null;
  if (r.action === "start" && keys === "action,booking_id" && id(r.booking_id)) {
    return { action: "start", bookingId: id(r.booking_id)! };
  }
  if (r.action === "status" && keys === "action") return { action: "status", bookingId: null };
  if (r.action === "status" && keys === "action,booking_id" && id(r.booking_id)) {
    return { action: "status", bookingId: id(r.booking_id)! };
  }
  if ((CALL_ACTIONS as readonly unknown[]).includes(r.action) && keys === "action,call_id" && id(r.call_id)) {
    return { action: r.action as typeof CALL_ACTIONS[number], callId: id(r.call_id)! };
  }
  return null;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

const TERMINAL = new Set(["declined", "cancelled", "missed", "ended", "failed"]);

export async function handleBookingCall(req: Request, deps: BookingCallDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "POST required" });
  const auth = req.headers.get("authorization");
  if (!auth?.startsWith("Bearer ")) return json(401, { error: "unauthorized" });
  const actor = await deps.resolveUser(auth.slice(7)).catch(() => null);
  if (!actor) return json(401, { error: "unauthorized" });

  let parsed: Parsed | null;
  try {
    parsed = parseCallRequest(await req.json());
  } catch {
    parsed = null;
  }
  if (parsed === null) return json(400, { error: "invalid request" });

  const { LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET } = deps.env;
  const providerReady = Boolean(LIVEKIT_URL && LIVEKIT_API_KEY && LIVEKIT_API_SECRET);
  if (!providerReady && parsed.action !== "status") return json(503, { error: "calling unavailable" });

  const ops: CallDeps = { rpc: deps.rpc, rooms: deps.rooms, nowSeconds: deps.nowSeconds };
  // Capture before the authorizing RPC. A delayed accepted response must not
  // issue credentials newer than a concurrent termination's revocation cutoff.
  const authorizationStartedAt = deps.nowSeconds();
  const token = (call: CallView) => mintJoinToken({
    apiKey: LIVEKIT_API_KEY!, apiSecret: LIVEKIT_API_SECRET!, identity: actor, room: call.room_name,
    nowSeconds: authorizationStartedAt,
  });

  try {
    if (parsed.action === "status") {
      return json(200, await rpcData(ops, "rf02_call_current", { p_actor: actor, p_booking_id: parsed.bookingId }));
    }

    if (parsed.action === "start") {
      const started = await rpcData<{ created: boolean; call: CallView }>(ops, "rf02_call_start",
        { p_actor: actor, p_booking_id: parsed.bookingId });
      let provision = started.call.provision_state;
      if (started.call.state === "ringing" && provision !== "ready") {
        provision = await provisionCall(ops, started.call);
      }
      // The atomic claim, not `created`, guarantees a single invitation: a
      // retry after an earlier 'unknown' provisioning still invites once, and
      // any later retry finds the claim taken.
      if (started.call.state === "ringing" && provision === "ready" && started.call.role === "caller") {
        await invite(deps, ops, started.call);
      }
      const current = await rpcData<{ call: CallView; server_now: string }>(ops, "rf02_call_current",
        { p_actor: actor, p_booking_id: parsed.bookingId });
      const call = current?.call ?? started.call;
      return json(200, {
        created: started.created,
        call,
        server_now: current?.server_now,
      });
    }

    let result = await rpcData<{ ok: boolean; reason?: string; call: CallView }>(ops, "rf02_call_act",
      { p_actor: actor, p_call_id: parsed.callId, p_action: parsed.action });
    if (parsed.action === "accept" && !result.ok && result.reason === "provisioning") {
      if (await provisionCall(ops, result.call) === "ready") {
        result = await rpcData(ops, "rf02_call_act", { p_actor: actor, p_call_id: parsed.callId, p_action: "accept" });
      }
    }

    if (result.ok && TERMINAL.has(result.call.state)) {
      // Inline best effort; the reconciler retries anything not confirmed.
      await cleanupCall(ops, result.call).catch(() => false);
    }

    const joinable = result.ok && (parsed.action === "accept" || parsed.action === "rejoin") &&
      result.call.state === "accepted";
    return json(200, {
      ok: result.ok,
      ...(result.reason ? { reason: result.reason } : {}),
      call: result.call,
      ...(joinable ? { token: await token(result.call), url: LIVEKIT_URL } : {}),
    });
  } catch (error) {
    if (error instanceof RpcFailure) {
      if (error.code === "42501") return json(403, { error: "forbidden" });
      if (error.code === "22023") return json(400, { error: "invalid request" });
    }
    return json(500, { error: "call request failed" });
  }
}

async function invite(deps: BookingCallDeps, ops: CallDeps, call: CallView): Promise<void> {
  const claimed = await rpcData<boolean>(ops, "rf02_call_claim_invite", { p_call_id: call.call_id });
  if (!claimed) return;
  const targets = await rpcData<Array<{ expo_push_token: string }>>(ops, "rf02_call_push_targets",
    { p_call_id: call.call_id }) ?? [];
  if (targets.length === 0) return;
  await deps.sendPush(targets.map((t) => ({
    to: t.expo_push_token,
    title: "Incoming video call",
    body: "Open SkillMatch to answer.",
    data: { kind: "call", booking_id: call.booking_id, call_id: call.call_id },
    ttl: 45,
    priority: "high",
    channelId: "skillmatch_alerts_v1",
  }))).catch(() => false);
}
