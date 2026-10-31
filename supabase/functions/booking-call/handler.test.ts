import { handleBookingCall, type BookingCallDeps } from "./handler.ts";
import type { ProviderResult, RoomService } from "../_shared/livekit.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const ACTOR = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const BOOKING = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const CALL_ID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const ROOM = `call_${CALL_ID}`;
const SECRET = "local-livekit-secret-for-tests-only-0123456789";

Deno.test("accept/rejoin: delayed authorization responses cannot mint newer credentials after cleanup", async () => {
  for (const action of ["accept", "rejoin"]) {
    const h = harness();
    const authorizedAt = 1_800_000_000;
    let now = authorizedAt;
    let release!: () => void;
    let entered!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const started = new Promise<void>((resolve) => { entered = resolve; });
    h.deps.nowSeconds = () => now;
    h.deps.rpc = async () => {
      entered();
      await gate;
      return { data: { ok: true, call: view({ state: "accepted" }) }, error: null };
    };
    const pending = handleBookingCall(req({ action, call_id: CALL_ID }), h.deps);
    await started;
    // Another request terminates the call and revokes tokens through this cutoff.
    const cleanupCutoff = authorizedAt + 1;
    now = authorizedAt + 10;
    release();
    const body = await (await pending).json();
    const claims = JSON.parse(atob(body.token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    assert(claims.nbf < cleanupCutoff, `${action} minted after revocation: ${claims.nbf}`);
    assert(claims.exp === authorizedAt + 300, "delayed delivery extended token lifetime");
  }
});

function view(over: Record<string, unknown> = {}) {
  return { call_id: CALL_ID, booking_id: BOOKING, room_name: ROOM, role: "caller", state: "ringing",
    provision_state: "pending", provision_attempts: 0, server_now: "2026-10-15T00:00:00Z", ...over };
}

type Setup = {
  rpc?: Record<string, unknown | ((args: Record<string, unknown>) => unknown)>;
  rooms?: Partial<Record<keyof RoomService, ProviderResult>>;
  user?: string | null;
};

function harness(setup: Setup = {}) {
  const log: string[] = [];
  const pushes: unknown[] = [];
  const ok: ProviderResult = { kind: "ok", status: 200, body: { rooms: [] } };
  const room = (name: keyof RoomService) => (...args: unknown[]) => {
    log.push(`room:${name}(${args.join(",")})`);
    return Promise.resolve(setup.rooms?.[name] ?? ok);
  };
  const deps: BookingCallDeps = {
    env: { LIVEKIT_URL: "wss://example.livekit.cloud", LIVEKIT_API_KEY: "APIkey", LIVEKIT_API_SECRET: SECRET, EXPO_ACCESS_TOKEN: "expo-token" },
    resolveUser: (jwt) => Promise.resolve(jwt === "good-jwt" ? (setup.user === undefined ? ACTOR : setup.user) : null),
    rpc: (fn, args) => {
      log.push(`rpc:${fn}`);
      const a = setup.rpc?.[fn];
      const data = typeof a === "function" ? (a as (x: Record<string, unknown>) => unknown)(args) : a;
      if (data instanceof Error) return Promise.resolve({ data: null, error: { code: data.message } });
      return Promise.resolve({ data: data ?? null, error: null });
    },
    rooms: {
      createRoom: room("createRoom"), deleteRoom: room("deleteRoom"), listRooms: room("listRooms"),
      listParticipants: room("listParticipants"), removeParticipant: room("removeParticipant"),
    },
    sendPush: (messages) => {
      pushes.push(...messages);
      return Promise.resolve(true);
    },
    nowSeconds: () => 1_800_000_000,
  };
  return { deps, log, pushes };
}

function req(body: unknown, jwt: string | null = "good-jwt") {
  return new Request("http://fn/booking-call", {
    method: "POST",
    headers: { "content-type": "application/json", ...(jwt ? { authorization: `Bearer ${jwt}` } : {}) },
    body: JSON.stringify(body),
  });
}

Deno.test("auth: missing or invalid JWT is 401 before any RPC", async () => {
  for (const jwt of [null, "bad-jwt"]) {
    const h = harness();
    const res = await handleBookingCall(req({ action: "status" }, jwt), h.deps);
    assert(res.status === 401, `status ${res.status}`);
    assert(!h.log.some((l) => l.startsWith("rpc:")), "rpc ran before auth");
  }
});

Deno.test("validation: unknown action or extra/malformed keys are 400", async () => {
  for (const body of [{ action: "record" }, { action: "start", booking_id: "nope" }, { action: "start", booking_id: BOOKING, room: "x" }, { action: "accept" }]) {
    const res = await handleBookingCall(req(body), harness().deps);
    assert(res.status === 400, `${JSON.stringify(body)} -> ${res.status}`);
  }
});

Deno.test("start: call row exists BEFORE the provider is asked, one push, no token before acceptance", async () => {
  const h = harness({ rpc: {
    rf02_call_start: { created: true, call: view() },
    rf02_call_claim_invite: true,
    rf02_call_push_targets: [{ expo_push_token: "ExponentPushToken[callee]" }],
    rf02_call_current: { call: view({ provision_state: "ready" }), server_now: "2026-10-15T00:00:00Z" },
  } });
  const res = await handleBookingCall(req({ action: "start", booking_id: BOOKING }), h.deps);
  const body = await res.json();
  assert(res.status === 200, `status ${res.status}`);
  assert(h.log.indexOf("rpc:rf02_call_start") < h.log.findIndex((l) => l.startsWith("room:createRoom")), h.log.join("\n"));
  assert(h.pushes.length === 1, `pushes ${h.pushes.length}`);
  const push = h.pushes[0] as Record<string, unknown>;
  assert(push.title === "Incoming video call" && push.body === "Open SkillMatch to answer.", "fixed copy");
  assert(push.ttl === 45 && push.priority === "high", "ttl/priority");
  assert(JSON.stringify(push.data) === JSON.stringify({ kind: "call", booking_id: BOOKING, call_id: CALL_ID }), JSON.stringify(push.data));
  assert(body.token === undefined && body.url === undefined, "no caller token before authorized acceptance");
  assert(!JSON.stringify(body).includes(SECRET), "secret leaked");
});

Deno.test("start retry does not resend the invitation once it was claimed", async () => {
  const h = harness({ rpc: {
    rf02_call_start: { created: false, call: view({ provision_state: "ready" }) },
    rf02_call_claim_invite: false, // already claimed by the first start
    rf02_call_current: { call: view({ provision_state: "ready" }) },
  } });
  await handleBookingCall(req({ action: "start", booking_id: BOOKING }), h.deps);
  assert(h.pushes.length === 0, "push resent on retry");
});

Deno.test("start retry after an earlier unknown provisioning invites exactly once", async () => {
  const h = harness({ rpc: {
    rf02_call_start: { created: false, call: view({ provision_state: "unknown" }) },
    rf02_call_claim_invite: true,
    rf02_call_push_targets: [{ expo_push_token: "ExponentPushToken[callee]" }],
    rf02_call_current: { call: view({ provision_state: "ready" }) },
  } });
  await handleBookingCall(req({ action: "start", booking_id: BOOKING }), h.deps);
  assert(h.pushes.length === 1, `pushes ${h.pushes.length}`);
});

Deno.test("callee's start on an incoming call never invites the caller", async () => {
  const h = harness({ rpc: {
    rf02_call_start: { created: false, call: view({ role: "callee", provision_state: "ready" }) },
    rf02_call_claim_invite: true,
    rf02_call_push_targets: [{ expo_push_token: "ExponentPushToken[x]" }],
    rf02_call_current: { call: view({ role: "callee", provision_state: "ready" }) },
  } });
  const body = await (await handleBookingCall(req({ action: "start", booking_id: BOOKING }), h.deps)).json();
  assert(h.pushes.length === 0 && body.token === undefined && body.call.role === "callee", JSON.stringify(body));
});

Deno.test("start: provider timeout leaves the call reconcilable, no push, no token", async () => {
  const unknown: ProviderResult = { kind: "unknown", status: null };
  const h = harness({
    rpc: { rf02_call_start: { created: true, call: view() }, rf02_call_current: { call: view({ provision_state: "unknown" }) } },
    rooms: { createRoom: unknown, listRooms: unknown },
  });
  const res = await handleBookingCall(req({ action: "start", booking_id: BOOKING }), h.deps);
  const body = await res.json();
  assert(res.status === 200 && body.call.provision_state === "unknown", JSON.stringify(body));
  assert(body.token === undefined, "token issued for an unprovisioned room");
  assert(h.pushes.length === 0, "invited before the room was known to exist");
});

Deno.test("start: definitive provider rejection -> no push, failed call returned", async () => {
  const h = harness({
    rpc: { rf02_call_start: { created: true, call: view() }, rf02_call_current: { call: view({ state: "failed" }) } },
    rooms: { createRoom: { kind: "rejected", status: 400 }, listRooms: { kind: "ok", status: 200, body: { rooms: [] } } },
  });
  const body = await (await handleBookingCall(req({ action: "start", booking_id: BOOKING }), h.deps)).json();
  assert(body.call.state === "failed" && h.pushes.length === 0, JSON.stringify(body));
});

Deno.test("accept: token only after a successful accept", async () => {
  const denied = harness({ rpc: { rf02_call_act: { ok: false, reason: "not_ringing", call: view({ state: "cancelled" }) } } });
  const b1 = await (await handleBookingCall(req({ action: "accept", call_id: CALL_ID }), denied.deps)).json();
  assert(b1.token === undefined && b1.ok === false && b1.reason === "not_ringing", JSON.stringify(b1));

  const granted = harness({ rpc: { rf02_call_act: { ok: true, call: view({ state: "accepted", role: "callee" }) } } });
  const b2 = await (await handleBookingCall(req({ action: "accept", call_id: CALL_ID }), granted.deps)).json();
  assert(typeof b2.token === "string", "no token after accept");
  const claims = JSON.parse(atob(b2.token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  assert(claims.sub === ACTOR && claims.video.room === ROOM && claims.video.canPublishData === false, JSON.stringify(claims));
});

Deno.test("accept while provisioning: provisions once, then retries accept", async () => {
  let n = 0;
  const h = harness({ rpc: {
    rf02_call_act: () => (n++ === 0 ? { ok: false, reason: "provisioning", call: view({ role: "callee" }) }
      : { ok: true, call: view({ state: "accepted", role: "callee" }) }),
  } });
  const body = await (await handleBookingCall(req({ action: "accept", call_id: CALL_ID }), h.deps)).json();
  assert(body.ok === true && typeof body.token === "string", JSON.stringify(body));
  assert(h.log.filter((l) => l === "rpc:rf02_call_act").length === 2, h.log.join("\n"));
});

Deno.test("end: terminal transition runs revoke + delete cleanup inline", async () => {
  const h = harness({ rpc: { rf02_call_act: { ok: true, call: view({ state: "ended", caller_id: ACTOR, callee_id: OTHER }) }, rf02_call_mark_cleanup: "confirmed" } });
  // the handler needs participant ids for revocation: it reads them from the cleanup work item
  const res = await handleBookingCall(req({ action: "end", call_id: CALL_ID }), h.deps);
  assert(res.status === 200, `status ${res.status}`);
  assert(h.log.some((l) => l.startsWith("room:removeParticipant")) && h.log.some((l) => l.startsWith("room:deleteRoom")), h.log.join("\n"));
});

Deno.test("rejoin denied after termination maps 42501 to 403 with no token", async () => {
  const h = harness({ rpc: { rf02_call_act: new Error("42501") } });
  const res = await handleBookingCall(req({ action: "rejoin", call_id: CALL_ID }), h.deps);
  const body = await res.json();
  assert(res.status === 403 && body.token === undefined, `${res.status} ${JSON.stringify(body)}`);
});

Deno.test("missing provider configuration is 503 and never mints tokens", async () => {
  const h = harness({ rpc: { rf02_call_act: { ok: true, call: view({ state: "accepted" }) } } });
  h.deps.env = { ...h.deps.env, LIVEKIT_API_SECRET: undefined };
  const res = await handleBookingCall(req({ action: "accept", call_id: CALL_ID }), h.deps);
  assert(res.status === 503, `status ${res.status}`);
});
