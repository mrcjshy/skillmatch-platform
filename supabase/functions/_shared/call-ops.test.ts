import { cleanupCall, provisionCall, reconcileTick, type CallDeps, type Rpc } from "./call-ops.ts";
import { roomService, type ProviderResult, type RoomService } from "./livekit.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const ok = (body: Record<string, unknown> = {}): ProviderResult => ({ kind: "ok", status: 200, body });
const unknown: ProviderResult = { kind: "unknown", status: null };
const rejected: ProviderResult = { kind: "rejected", status: 400 };
const absent: ProviderResult = { kind: "absent", status: 404 };

function fakeRooms(script: Partial<Record<keyof RoomService, ProviderResult[]>>, log: string[]): RoomService {
  const next = (name: keyof RoomService, ...args: unknown[]) => {
    log.push(`${name}(${args.map(String).join(",")})`);
    const q = script[name] ?? [];
    return Promise.resolve(q.length > 1 ? q.shift()! : q[0] ?? ok());
  };
  return {
    createRoom: (n) => next("createRoom", n),
    deleteRoom: (r) => next("deleteRoom", r),
    listRooms: (n) => next("listRooms", n.join("|")),
    listParticipants: (r) => next("listParticipants", r),
    removeParticipant: (r, i, t) => next("removeParticipant", r, i, t),
  };
}

function fakeRpc(log: string[], answers: Record<string, unknown> = {}): Rpc {
  return (fn, args) => {
    log.push(`${fn}(${JSON.stringify(args)})`);
    return Promise.resolve({ data: answers[fn] ?? null, error: null });
  };
}

const CALL = {
  call_id: "11111111-1111-4111-8111-111111111111",
  room_name: "call_11111111-1111-4111-8111-111111111111",
  caller_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  callee_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  provision_attempts: 0,
};

Deno.test("cleanup: a stale provider snapshot rejected by SQL is not confirmed", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ listRooms: [ok({ rooms: [] })] }, log);
  assert(!(await cleanupCall(deps(rooms, fakeRpc(log, { rf02_call_mark_cleanup: "stale_provisioning" })), CALL)),
    "reported confirmation despite a newer provisioning outcome");
});

Deno.test("cleanup: present invalid room collections and entries remain unknown", async () => {
  for (const body of [{ rooms: "invalid" }, { rooms: null }, { rooms: {} },
    { rooms: [null] }, { rooms: [{}] }, { rooms: [{ name: 7 }] }]) {
    const log: string[] = [];
    const rooms = fakeRooms({ listRooms: [ok(body)] }, log);
    assert(!(await cleanupCall(deps(rooms, fakeRpc(log, { rf02_call_mark_cleanup: "confirmed" })), CALL)),
      `invalid listing confirmed absence: ${JSON.stringify(body)}`);
  }
});

Deno.test("cleanup: protobuf's omitted empty room collection is valid", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ listRooms: [ok({})] }, log);
  assert(await cleanupCall(deps(rooms, fakeRpc(log, { rf02_call_mark_cleanup: "confirmed" })), CALL),
    "valid omitted repeated field was rejected");
});

Deno.test("presence: a present invalid participant collection never implies absence", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ listParticipants: [ok({ participants: "invalid" })] }, log);
  await reconcileTick(deps(rooms, fakeRpc(log, { rf02_call_reconcile_batch: { presence: [CALL] } })));
  assert(!log.some((line) => line.includes("rf02_call_record_presence")), "malformed presence inferred absence");
});

Deno.test("cleanup: malformed HTTP 200 ListRooms cannot confirm cleanup", async () => {
  const log: string[] = [];
  const rooms = roomService({ url: "wss://example.livekit.cloud", apiKey: "test-key", apiSecret: "test-secret",
    fetch: (input) => Promise.resolve(new Response(String(input).endsWith("ListRooms") ? "{" : "{}", { status: 200 })) });
  assert(!(await cleanupCall(deps(rooms, fakeRpc(log)), CALL)), "malformed provider response confirmed cleanup");
  assert(log.some((line) => line.includes('"p_ok":false')), "uncertain cleanup was not retained");
});

function deps(rooms: RoomService, rpc: Rpc): CallDeps {
  return { rooms, rpc, nowSeconds: () => 1_800_000_000 };
}

Deno.test("provision: ok -> ready", async () => {
  const log: string[] = [];
  const r = await provisionCall(deps(fakeRooms({ createRoom: [ok()] }, log), fakeRpc(log)), CALL);
  assert(r === "ready", r);
  assert(log.some((l) => l.includes("rf02_call_record_provisioning") && l.includes('"p_result":"ready"')), log.join("\n"));
});

Deno.test("provision: ambiguous create, room actually exists -> ready (late success)", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ createRoom: [unknown], listRooms: [ok({ rooms: [{ name: CALL.room_name }] })] }, log);
  assert(await provisionCall(deps(rooms, fakeRpc(log)), CALL) === "ready", log.join("\n"));
});

Deno.test("provision: ambiguous create and ambiguous listing -> unknown (never failed, never ready)", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ createRoom: [unknown], listRooms: [unknown] }, log);
  assert(await provisionCall(deps(rooms, fakeRpc(log)), CALL) === "unknown", log.join("\n"));
  assert(log.some((l) => l.includes('"p_result":"unknown"')), "unknown not recorded");
});

Deno.test("provision: definitive rejection with room provably absent -> rejected", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ createRoom: [rejected], listRooms: [ok({ rooms: [] })] }, log);
  assert(await provisionCall(deps(rooms, fakeRpc(log)), CALL) === "rejected", log.join("\n"));
});

Deno.test("cleanup: revoke both identities with cutoff BEFORE deleting, then confirm absence", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ removeParticipant: [absent, ok()], deleteRoom: [ok()], listRooms: [ok({ rooms: [] })] }, log);
  const confirmed = await cleanupCall(deps(rooms, fakeRpc(log, { rf02_call_mark_cleanup: "confirmed" })), CALL);
  assert(confirmed, log.join("\n"));
  const order = log.filter((l) => !l.startsWith("rf02_")).map((l) => l.split("(")[0]);
  assert(JSON.stringify(order) === JSON.stringify(["removeParticipant", "removeParticipant", "deleteRoom", "listRooms"]), order.join(","));
  assert(log[0].includes(`${CALL.caller_id},1800000001`) && log[1].includes(`${CALL.callee_id},1800000001`), "cutoff = now + 1 for both identities");
  assert(log.some((l) => l.includes("rf02_call_mark_cleanup") && l.includes('"p_ok":true')), "not marked ok");
});

Deno.test("cleanup: room deleted but revocation unknown -> NOT confirmed (token revocation is independent of room absence)", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ removeParticipant: [unknown, ok()], deleteRoom: [ok()], listRooms: [ok({ rooms: [] })] }, log);
  const confirmed = await cleanupCall(deps(rooms, fakeRpc(log)), CALL);
  assert(!confirmed, "confirmed despite unknown revocation");
  assert(log.some((l) => l.includes("rf02_call_mark_cleanup") && l.includes('"p_ok":false')), "failure not recorded");
});

Deno.test("cleanup: delete accepted but room still listed -> NOT confirmed", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ deleteRoom: [ok()], listRooms: [ok({ rooms: [{ name: CALL.room_name }] })] }, log);
  assert(!(await cleanupCall(deps(rooms, fakeRpc(log)), CALL)), "confirmed while room still listed");
});

Deno.test("cleanup: listing unknown -> NOT confirmed (a queued or accepted request is not proof)", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ deleteRoom: [ok()], listRooms: [unknown] }, log);
  assert(!(await cleanupCall(deps(rooms, fakeRpc(log)), CALL)), "confirmed without a listing");
});

Deno.test("reconcile tick: presence, provisioning retry and cleanup work items", async () => {
  const log: string[] = [];
  const batch = {
    presence: [{ ...CALL }],
    provisioning: [{ call_id: CALL.call_id, room_name: CALL.room_name }],
    cleanup: [{ ...CALL }],
  };
  const rooms = fakeRooms({
    listParticipants: [ok({ participants: [{ identity: CALL.caller_id }, { identity: "not-a-uuid" }] })],
    createRoom: [ok()],
    listRooms: [ok({ rooms: [] })],
  }, log);
  const summary = await reconcileTick(deps(rooms, fakeRpc(log, { rf02_call_reconcile_batch: batch, rf02_call_mark_cleanup: "confirmed" })));
  assert(summary.presence === 1 && summary.provisioned === 1 && summary.cleaned === 1, JSON.stringify(summary));
  assert(log.some((l) => l.includes("rf02_call_record_presence") && l.includes(CALL.caller_id) && !l.includes("not-a-uuid")),
    "presence must pass only uuid identities");
});

Deno.test("reconcile tick: unknown participant listing records no presence change", async () => {
  const log: string[] = [];
  const rooms = fakeRooms({ listParticipants: [unknown] }, log);
  await reconcileTick(deps(rooms, fakeRpc(log, { rf02_call_reconcile_batch: { presence: [CALL], provisioning: [], cleanup: [] } })));
  assert(!log.some((l) => l.includes("rf02_call_record_presence")), "absence inferred from an unknown listing");
});
