// Runs under `node --test` (Node 22.6+ type stripping) and `deno test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ANDROID_CHANNEL_ID,
  buildReminderMessages,
  EXPO_PUSH_URL,
  handleReminderTick,
  parseTickPayload,
  planTick,
} from "./handler.ts";
import type { CandidateRow, ReminderDeps } from "./handler.ts";
import { MAX_SENDS_PER_TICK } from "./schedule.ts";

const SECRET = "lane-c-local-dispatch-secret";
const B1 = "11111111-1111-4111-8111-111111111111";
const B2 = "33333333-3333-4333-8333-333333333333";
const W = "22222222-2222-4222-8222-222222222222";
function M(y: number, mo: number, d: number, h: number, mi = 0): number {
  return Date.UTC(y, mo - 1, d, h - 8, mi);
}
const NOW = M(2026, 10, 14, 18, 5);
const START = M(2026, 10, 15, 9);

function row(bookingId = B1, start = START, bookedAt = M(2026, 10, 10, 9)): CandidateRow {
  return {
    booking_id: bookingId,
    worker_id: W,
    booked_at: new Date(bookedAt).toISOString(),
    // PostgREST-style offset form; keys must canonicalize it.
    scheduled_at: new Date(start).toISOString().replace(".000Z", "+00:00"),
  };
}

type Harness = {
  deps: ReminderDeps;
  ledger: Map<string, { status: string; attempts: number; error: string | null }>;
  fetchCalls: Array<{ url: string; body: unknown[] }>;
  tokenCalls: Array<[string, string, string]>;
};

function harness(opts: {
  rows?: CandidateRow[];
  tokens?: string[] | Error;
  fetchStatus?: number | "throw";
  enabled?: string;
  expo?: string;
} = {}): Harness {
  const ledger = new Map<string, { status: string; attempts: number; error: string | null }>();
  const fetchCalls: Array<{ url: string; body: unknown[] }> = [];
  const tokenCalls: Array<[string, string, string]> = [];
  const deps: ReminderDeps = {
    env: { webhookSecret: SECRET, expoAccessToken: opts.expo ?? "expo-token", enabled: "enabled" in opts ? opts.enabled : "true" },
    now: () => NOW,
    listCandidates: async () => opts.rows ?? [row()],
    getPushTokens: async (b, w, s) => {
      tokenCalls.push([b, w, s]);
      if (opts.tokens instanceof Error) throw opts.tokens;
      return opts.tokens ?? ["ExponentPushToken[abc]"];
    },
    // Mirrors the proposed claim_outbound_dispatch semantics.
    claim: async (key, _b, max) => {
      const cur = ledger.get(key);
      if (!cur) {
        ledger.set(key, { status: "claimed", attempts: 1, error: null });
        return true;
      }
      if (cur.status === "failed" && cur.attempts < max) {
        cur.status = "claimed";
        cur.attempts++;
        return true;
      }
      return false;
    },
    finish: async (key, sent, error) => {
      const cur = ledger.get(key)!;
      cur.status = sent ? "sent" : "failed";
      cur.error = error;
    },
    fetchImpl: (async (url: string, init: RequestInit) => {
      fetchCalls.push({ url, body: JSON.parse(String(init.body)) });
      if (opts.fetchStatus === "throw") throw new Error("network");
      return new Response("{}", { status: opts.fetchStatus ?? 200 });
    }) as unknown as typeof fetch,
  };
  return { deps, ledger, fetchCalls, tokenCalls };
}

function tick(body: unknown = { tick: true }, secret = SECRET, method = "POST"): Request {
  return new Request("http://localhost/worker-reminders", {
    method,
    headers: { "content-type": "application/json", "x-skillmatch-dispatch-secret": secret },
    body: method === "GET" ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function call(req: Request, h: Harness) {
  const res = await handleReminderTick(req, h.deps);
  return { status: res.status, body: await res.json() as Record<string, unknown> };
}

test("tick payload carries no authority", () => {
  assert.equal(parseTickPayload({ tick: true }), true);
  assert.equal(parseTickPayload({ tick: true, booking_id: B1 }), false);
  assert.equal(parseTickPayload({ tick: "true" }), false);
  assert.equal(parseTickPayload([]), false);
  assert.equal(parseTickPayload(null), false);
});

test("non-POST 405, missing secret config 500, wrong secret 401, bad body 400", async () => {
  assert.equal((await call(tick({}, SECRET, "GET"), harness())).status, 405);
  const noSecret = harness();
  noSecret.deps.env.webhookSecret = undefined;
  assert.equal((await call(tick(), noSecret)).status, 500);
  const h = harness();
  assert.equal((await call(tick({ tick: true }, "wrong"), h)).status, 401);
  assert.equal((await call(tick("{"), h)).status, 400);
  assert.equal((await call(tick({ tick: true, recipient: "x" }), h)).status, 400);
  assert.equal(h.fetchCalls.length, 0);
});

test("dry run unless WORKER_REMINDERS_ENABLED is exactly true", async () => {
  for (const enabled of [undefined, "", "TRUE", "1"]) {
    const h = harness({ enabled });
    const got = await call(tick(), h);
    assert.deepEqual(got.body, { dry_run: true, due: 1 });
    assert.equal(h.fetchCalls.length, 0);
    assert.equal(h.ledger.size, 0);
  }
});

test("due reminder is claimed, re-checked with canonical schedule, and sent once", async () => {
  const h = harness();
  const first = await call(tick(), h);
  assert.deepEqual(first.body, { due: 1, sent: 1, skipped: 0, failed: 0 });
  assert.deepEqual(h.tokenCalls, [[B1, W, new Date(START).toISOString()]]);
  assert.equal(h.fetchCalls[0].url, EXPO_PUSH_URL);
  const msg = h.fetchCalls[0].body[0] as Record<string, unknown>;
  assert.equal(msg.title, "Job tomorrow");
  assert.equal(msg.channelId, ANDROID_CHANNEL_ID);
  assert.deepEqual(msg.data, { kind: "booking_reminder", booking_id: B1 });

  // Replayed tick inside the same window: ledger says sent, nothing re-sent.
  const second = await call(tick(), h);
  assert.deepEqual(second.body, { due: 1, sent: 0, skipped: 1, failed: 0 });
  assert.equal(h.fetchCalls.length, 1);
});

test("cancelled / rescheduled / reassigned booking (no eligible target) is not pushed", async () => {
  const h = harness({ tokens: [] });
  const got = await call(tick(), h);
  assert.deepEqual(got.body, { due: 1, sent: 0, skipped: 1, failed: 0 });
  assert.equal(h.fetchCalls.length, 0);
  assert.equal([...h.ledger.values()][0].error, "no_eligible_target");
});

test("provider failure is recorded and retried at most MAX attempts", async () => {
  const h = harness({ fetchStatus: 500 });
  for (let i = 0; i < 5; i++) await call(tick(), h);
  assert.equal(h.fetchCalls.length, 3);
  const entry = [...h.ledger.values()][0];
  assert.equal(entry.status, "failed");
  assert.equal(entry.attempts, 3);
  assert.equal(entry.error, "http_500");
});

test("network error and target lookup error count as failed without throwing", async () => {
  const net = harness({ fetchStatus: "throw" });
  assert.deepEqual((await call(tick(), net)).body, { due: 1, sent: 0, skipped: 0, failed: 1 });
  const rpc = harness({ tokens: new Error("rpc down") });
  assert.deepEqual((await call(tick(), rpc)).body, { due: 1, sent: 0, skipped: 0, failed: 1 });
  assert.equal(rpc.fetchCalls.length, 0);
});

test("candidate query failure is 503 and sends nothing", async () => {
  const h = harness();
  h.deps.listCandidates = async () => {
    throw new Error("down");
  };
  assert.equal((await call(tick(), h)).status, 503);
  assert.equal(h.fetchCalls.length, 0);
});

test("missing Expo token when enabled is a configuration error", async () => {
  const h = harness();
  h.deps.env.expoAccessToken = undefined;
  assert.equal((await call(tick(), h)).status, 500);
});

test("planTick drops malformed rows, dedups duplicates, and caps per tick", () => {
  const bad: CandidateRow[] = [
    { booking_id: "not-a-uuid", worker_id: W, booked_at: null, scheduled_at: row().scheduled_at },
    { booking_id: B1, worker_id: W, booked_at: null, scheduled_at: "garbage" },
    { booking_id: B1, worker_id: W, booked_at: null, scheduled_at: null },
  ];
  assert.equal(planTick(bad, NOW).length, 0);
  assert.equal(planTick([row(), row()], NOW).length, 1);
  assert.equal(planTick([row(B1), row(B2)], NOW).length, 2);

  const many: CandidateRow[] = [];
  for (let i = 0; i < MAX_SENDS_PER_TICK + 20; i++) {
    const id = `44444444-4444-4444-8444-${String(i).padStart(12, "0")}`;
    many.push(row(id));
  }
  assert.equal(planTick(many, NOW).length, MAX_SENDS_PER_TICK);
});

test("messages carry no address, client or job content", () => {
  const [plan] = planTick([row()], NOW);
  const [msg] = buildReminderMessages(plan, ["ExponentPushToken[abc]"]);
  assert.deepEqual(Object.keys(msg).sort(), ["body", "channelId", "data", "sound", "title", "to"]);
  assert.equal(msg.body, "You have a SkillMatch job tomorrow at 9:00 AM. Open SkillMatch for details.");
});
