import {
  adminToken,
  classifyProviderResponse,
  httpBaseUrl,
  mintJoinToken,
  revokeCutoff,
  roomService,
  verifyWebhook,
} from "./livekit.ts";

const KEY = "APIlocaltest";
const SECRET = "local-test-secret-not-a-real-livekit-secret-0123456789";
const NOW = 1_800_000_000;

Deno.test("room service: malformed successful JSON remains unknown", async () => {
  const svc = roomService({ url: "wss://example.livekit.cloud", apiKey: KEY, apiSecret: SECRET,
    fetch: () => Promise.resolve(new Response("{", { status: 200 })), nowSeconds: () => NOW });
  assert((await svc.listRooms(["call_x"])).kind === "unknown", "malformed rooms listing counted as absence");
  assert((await svc.listParticipants("call_x")).kind === "unknown", "malformed presence counted as absence");
  assert((await svc.createRoom("call_x")).kind === "unknown", "malformed creation counted as success");
});

function decode(token: string): { header: Record<string, unknown>; claims: Record<string, unknown> } {
  const [h, p] = token.split(".");
  const dec = (s: string) => JSON.parse(atob(s.replace(/-/g, "+").replace(/_/g, "/")));
  return { header: dec(h), claims: dec(p) };
}

async function hs256Valid(token: string, secret: string): Promise<boolean> {
  const [h, p, s] = token.split(".");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const sig = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  return crypto.subtle.verify("HMAC", key, sig, new TextEncoder().encode(`${h}.${p}`));
}

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

Deno.test("join token: one room, one identity, camera+mic only, data publication disabled", async () => {
  const token = await mintJoinToken({ apiKey: KEY, apiSecret: SECRET, identity: "user-1", room: "call_x", nowSeconds: NOW });
  const { header, claims } = decode(token);
  assert(header.alg === "HS256" && header.typ === "JWT", "header");
  assert(await hs256Valid(token, SECRET), "signature does not verify");
  assert(claims.iss === KEY && claims.sub === "user-1", "issuer/subject");
  assert(claims.nbf === NOW && claims.exp === NOW + 300, `lifetime ${claims.nbf}..${claims.exp}`);
  const video = claims.video as Record<string, unknown>;
  assert(video.room === "call_x" && video.roomJoin === true, "room grant");
  assert(video.canPublish === true && video.canSubscribe === true, "media grants");
  assert(video.canPublishData === false, "data publication must be explicitly disabled");
  assert(JSON.stringify(video.canPublishSources) === JSON.stringify(["camera", "microphone"]), "sources");
  assert(video.canUpdateOwnMetadata === false, "metadata updates must be disabled");
  for (const forbidden of ["roomCreate", "roomList", "roomAdmin", "recorder", "ingressAdmin", "hidden"]) {
    assert(!(forbidden in video), `join token must not carry ${forbidden}`);
  }
});

Deno.test("join token lifetime is capped at 300 s and identity/room are required", async () => {
  let threw = 0;
  for (const bad of [{ ttlSeconds: 301 }, { identity: "" }, { room: "" }]) {
    try {
      await mintJoinToken({ apiKey: KEY, apiSecret: SECRET, identity: "u", room: "r", nowSeconds: NOW, ...bad });
    } catch {
      threw++;
    }
  }
  assert(threw === 3, `expected 3 rejections, got ${threw}`);
});

Deno.test("admin token is short-lived and only for server use", async () => {
  const { claims } = decode(await adminToken({ apiKey: KEY, apiSecret: SECRET, nowSeconds: NOW }));
  const video = claims.video as Record<string, unknown>;
  assert(video.roomCreate === true && video.roomAdmin === true && video.roomList === true, "admin grants");
  assert(claims.exp === NOW + 60, "admin token must expire in 60 s");
});

Deno.test("revocation cutoff is one second ahead so same-second tokens are also revoked", () => {
  assert(revokeCutoff(NOW) === NOW + 1, "cutoff");
});

Deno.test("provider results: definitive rejection vs unknown vs absent", () => {
  assert(classifyProviderResponse(200).kind === "ok", "200");
  assert(classifyProviderResponse(400).kind === "rejected", "400");
  assert(classifyProviderResponse(401).kind === "rejected", "401");
  assert(classifyProviderResponse(404).kind === "absent", "404 absent");
  assert(classifyProviderResponse(408).kind === "unknown", "408");
  assert(classifyProviderResponse(429).kind === "unknown", "429");
  assert(classifyProviderResponse(503).kind === "unknown", "503");
});

Deno.test("room service sends Twirp requests with exact bodies and a bearer admin token", async () => {
  const calls: Array<{ url: string; body: Record<string, unknown>; auth: string | null }> = [];
  const fakeFetch = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({
      url: String(url),
      body: JSON.parse(String(init?.body)),
      auth: new Headers(init?.headers).get("authorization"),
    });
    return new Response(JSON.stringify({ rooms: [], participants: [] }), { status: 200 });
  }) as typeof fetch;
  const svc = roomService({ url: "wss://example.livekit.cloud", apiKey: KEY, apiSecret: SECRET, fetch: fakeFetch, nowSeconds: () => NOW });
  await svc.createRoom("call_x");
  await svc.removeParticipant("call_x", "user-1", NOW + 1);
  await svc.deleteRoom("call_x");
  await svc.listRooms(["call_x"]);
  await svc.listParticipants("call_x");
  const base = "https://example.livekit.cloud/twirp/livekit.RoomService/";
  assert(calls[0].url === base + "CreateRoom", calls[0].url);
  assert(JSON.stringify(calls[0].body) === JSON.stringify({ name: "call_x", empty_timeout: 60, departure_timeout: 20, max_participants: 2 }), JSON.stringify(calls[0].body));
  assert(calls[1].url === base + "RemoveParticipant", calls[1].url);
  assert(JSON.stringify(calls[1].body) === JSON.stringify({ room: "call_x", identity: "user-1", revoke_token_ts: NOW + 1 }), JSON.stringify(calls[1].body));
  assert(calls[2].url === base + "DeleteRoom" && calls[2].body.room === "call_x", "delete");
  assert(calls[3].url === base + "ListRooms" && JSON.stringify(calls[3].body.names) === '["call_x"]', "list rooms");
  assert(calls[4].url === base + "ListParticipants" && calls[4].body.room === "call_x", "list participants");
  for (const c of calls) assert(c.auth?.startsWith("Bearer ") === true, "bearer admin token");
  assert(!JSON.stringify(calls).includes(SECRET), "API secret must never be sent");
});

Deno.test("room service maps network failure and timeout to unknown, never to success", async () => {
  const boom = (() => Promise.reject(new TypeError("network down"))) as unknown as typeof fetch;
  const svc = roomService({ url: "https://example.livekit.cloud", apiKey: KEY, apiSecret: SECRET, fetch: boom, nowSeconds: () => NOW });
  const r = await svc.createRoom("call_x");
  assert(r.kind === "unknown", `network failure classified ${r.kind}`);
});

Deno.test("httpBaseUrl converts ws(s) to http(s) and strips trailing slash", () => {
  assert(httpBaseUrl("wss://a.livekit.cloud/") === "https://a.livekit.cloud", "wss");
  assert(httpBaseUrl("ws://127.0.0.1:7880") === "http://127.0.0.1:7880", "ws");
});

async function signWebhook(body: string, overrides: Record<string, unknown> = {}, secret = SECRET) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body)));
  const sha = btoa(String.fromCharCode(...digest));
  const enc = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  const head = enc({ alg: "HS256", typ: "JWT" });
  const payload = enc({ iss: KEY, nbf: NOW - 5, exp: NOW + 300, sha256: sha, ...overrides });
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${head}.${payload}`)));
  return `${head}.${payload}.${btoa(String.fromCharCode(...sig)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")}`;
}

Deno.test("webhook: valid signature and body hash accepted", async () => {
  const body = JSON.stringify({ event: "room_finished", id: "EV_1", room: { name: "call_x" } });
  const event = await verifyWebhook({ apiKey: KEY, apiSecret: SECRET, authHeader: await signWebhook(body), body, nowSeconds: NOW });
  assert(event?.event === "room_finished", "valid webhook rejected");
});

Deno.test("webhook: tampered body, wrong secret, wrong issuer, expired and missing header are rejected", async () => {
  const body = JSON.stringify({ event: "room_finished", id: "EV_1", room: { name: "call_x" } });
  const good = await signWebhook(body);
  const cases: Array<[string, string | null, string]> = [
    ["tampered body", good, body.replace("call_x", "call_y")],
    ["wrong secret", await signWebhook(body, {}, "another-secret-value-0123456789abcdef"), body],
    ["wrong issuer", await signWebhook(body, { iss: "APIother" }), body],
    ["expired", await signWebhook(body, { exp: NOW - 11 }), body],
    ["missing header", null, body],
    ["garbage header", "abc.def", body],
  ];
  for (const [name, header, b] of cases) {
    const event = await verifyWebhook({ apiKey: KEY, apiSecret: SECRET, authHeader: header, body: b, nowSeconds: NOW });
    assert(event === null, `${name} was accepted`);
  }
});
