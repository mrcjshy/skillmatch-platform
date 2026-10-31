import { handleWebhook, type WebhookDeps } from "./handler.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const KEY = "APIwebhooktest";
const SECRET = "webhook-test-secret-not-real-0123456789abcdef";
const NOW = 1_800_000_000;

async function sign(body: string, secret = SECRET) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body)));
  const enc = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  const h = enc({ alg: "HS256", typ: "JWT" });
  const p = enc({ iss: KEY, nbf: NOW - 1, exp: NOW + 300, sha256: btoa(String.fromCharCode(...digest)) });
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${h}.${p}`)));
  return `${h}.${p}.${btoa(String.fromCharCode(...sig)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")}`;
}

function harness(knownRoom: string | null) {
  const log: string[] = [];
  const deps: WebhookDeps = {
    env: { LIVEKIT_API_KEY: KEY, LIVEKIT_API_SECRET: SECRET },
    lookupCall: (room) => {
      log.push(`lookup:${room}`);
      return Promise.resolve(room === knownRoom ? "11111111-1111-4111-8111-111111111111" : null);
    },
    reconcile: () => {
      log.push("reconcile");
      return Promise.resolve();
    },
    nowSeconds: () => NOW,
  };
  return { deps, log };
}

const post = (body: string, auth: string | null) => new Request("http://fn/livekit-webhook", {
  method: "POST",
  headers: { "content-type": "application/webhook+json", ...(auth ? { authorization: auth } : {}) },
  body,
});

Deno.test("unsigned or tampered webhook is 401 and triggers nothing", async () => {
  const body = JSON.stringify({ event: "room_finished", id: "EV1", room: { name: "call_a" } });
  for (const [auth, b] of [[null, body], [await sign(body), body.replace("call_a", "call_b")], [await sign(body, "other-secret-value-0123456789abcd"), body]] as const) {
    const h = harness("call_a");
    const res = await handleWebhook(post(b, auth), h.deps);
    assert(res.status === 401 && h.log.length === 0, `${res.status} ${h.log}`);
  }
});

Deno.test("signed room_finished for a known call triggers reconciliation (a hint, not proof)", async () => {
  const body = JSON.stringify({ event: "room_finished", id: "EV1", room: { name: "call_a" } });
  const h = harness("call_a");
  const res = await handleWebhook(post(body, await sign(body)), h.deps);
  assert(res.status === 200 && h.log.includes("reconcile"), h.log.join(","));
});

Deno.test("signed event for an unknown room or an unrelated event is a 200 no-op", async () => {
  for (const ev of [{ event: "room_finished", room: { name: "call_zzz" } }, { event: "track_published", room: { name: "call_a" } }]) {
    const body = JSON.stringify(ev);
    const h = harness("call_a");
    const res = await handleWebhook(post(body, await sign(body)), h.deps);
    assert(res.status === 200 && !h.log.includes("reconcile"), `${JSON.stringify(ev)} ${h.log}`);
  }
});
