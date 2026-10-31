import { handleReconcile, type ReconcileDeps } from "./handler.ts";
import type { ProviderResult, RoomService } from "../_shared/livekit.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const SECRET = "rf02-local-dispatch-secret-0123456789";

function harness(batch: unknown = { presence: [], provisioning: [], cleanup: [] }) {
  const log: string[] = [];
  const ok: ProviderResult = { kind: "ok", status: 200, body: { rooms: [] } };
  const room = (n: keyof RoomService) => () => {
    log.push(`room:${n}`);
    return Promise.resolve(ok);
  };
  const deps: ReconcileDeps = {
    env: { RF02_CALL_RECONCILE_SECRET: SECRET, LIVEKIT_URL: "wss://x", LIVEKIT_API_KEY: "k", LIVEKIT_API_SECRET: "s" },
    rpc: (fn) => {
      log.push(`rpc:${fn}`);
      return Promise.resolve({ data: fn === "rf02_call_reconcile_batch" ? batch : "confirmed", error: null });
    },
    rooms: { createRoom: room("createRoom"), deleteRoom: room("deleteRoom"), listRooms: room("listRooms"),
      listParticipants: room("listParticipants"), removeParticipant: room("removeParticipant") },
    nowSeconds: () => 1_800_000_000,
  };
  return { deps, log };
}

const post = (body: unknown, secret: string | null = SECRET) => new Request("http://fn/booking-call-reconcile", {
  method: "POST",
  headers: { "content-type": "application/json", ...(secret === null ? {} : { "x-skillmatch-dispatch-secret": secret }) },
  body: JSON.stringify(body),
});

Deno.test("scheduler secret required; wrong, missing or unconfigured secret is 401 before any RPC", async () => {
  for (const [secret, configured] of [[null, true], ["wrong", true], [SECRET, false]] as const) {
    const h = harness();
    if (!configured) h.deps.env = { ...h.deps.env, RF02_CALL_RECONCILE_SECRET: undefined };
    const res = await handleReconcile(post({ tick: true }, secret), h.deps);
    assert(res.status === 401, `${secret}/${configured} -> ${res.status}`);
    assert(h.log.length === 0, "work ran without the scheduler secret");
  }
});

Deno.test("body must be exactly {tick:true} or {call_id}", async () => {
  for (const body of [{}, { tick: false }, { tick: true, x: 1 }, { call_id: "nope" }]) {
    const res = await handleReconcile(post(body), harness().deps);
    assert(res.status === 400, `${JSON.stringify(body)} -> ${res.status}`);
  }
});

Deno.test("tick runs one reconcile pass and reports counts only", async () => {
  const h = harness({ presence: [], provisioning: [], cleanup: [{
    call_id: "11111111-1111-4111-8111-111111111111", room_name: "call_1",
    caller_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", callee_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" }] });
  const res = await handleReconcile(post({ tick: true }), h.deps);
  const body = await res.json();
  assert(res.status === 200 && body.cleaned === 1, JSON.stringify(body));
  assert(h.log.includes("rpc:rf02_call_reconcile_batch"), h.log.join(","));
});

Deno.test("a call_id hint also runs a full pass (idempotent)", async () => {
  const h = harness();
  const res = await handleReconcile(post({ call_id: "11111111-1111-4111-8111-111111111111" }), h.deps);
  assert(res.status === 200 && h.log.includes("rpc:rf02_call_reconcile_batch"), h.log.join(","));
});
