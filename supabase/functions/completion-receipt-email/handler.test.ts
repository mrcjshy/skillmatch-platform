// Runs under `node --test` (Node 22.6+ type stripping) and `deno test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleReceiptRequest, MAX_ATTEMPTS_PER_RECEIPT, RESEND_URL } from "./handler.ts";
import type { ReceiptDeps } from "./handler.ts";

const SECRET = "lane-c-local-dispatch-secret";
const BID = "abcdef12-1111-4111-8111-111111111111";

const CONTEXT = {
  booking_id: BID,
  booking_status: "completed",
  completed_at: "2026-10-14T03:05:12+00:00",
  payment_method: "qrph",
  payment_status: "paid",
  job_title: "Fix kitchen sink",
  job_barangay: "Santa Ana",
  job_city: "Manila",
  job_budget: 1500,
  client_full_name: "Juan Dela Cruz",
  client_email: "client@example.test",
};

type Harness = {
  deps: ReceiptDeps;
  ledger: Map<string, { status: string; attempts: number; ref: string | null; error: string | null }>;
  sends: Array<{ url: string; headers: Record<string, string>; body: Record<string, unknown> }>;
  contextCalls: string[];
};

function harness(opts: {
  context?: unknown;
  contextError?: boolean;
  ledgerDown?: boolean;
  status?: number | "throw";
  enabled?: string;
} = {}): Harness {
  const ledger: Harness["ledger"] = new Map();
  const sends: Harness["sends"] = [];
  const contextCalls: string[] = [];
  const deps: ReceiptDeps = {
    env: {
      webhookSecret: SECRET,
      resendApiKey: "re_local_test",
      from: "SkillMatch <receipts@example.test>",
      enabled: "enabled" in opts ? opts.enabled : "true",
    },
    getContext: async (id) => {
      contextCalls.push(id);
      if (opts.contextError) throw new Error("rpc down");
      return "context" in opts ? opts.context : CONTEXT;
    },
    claim: async (key, _b, max) => {
      if (opts.ledgerDown) throw new Error("ledger missing");
      const cur = ledger.get(key);
      if (!cur) {
        ledger.set(key, { status: "claimed", attempts: 1, ref: null, error: null });
        return true;
      }
      if (cur.status === "failed" && cur.attempts < max) {
        cur.status = "claimed";
        cur.attempts++;
        return true;
      }
      return false;
    },
    finish: async (key, sent, ref, error) => {
      const cur = ledger.get(key)!;
      cur.status = sent ? "sent" : "failed";
      cur.ref = ref;
      cur.error = error;
    },
    fetchImpl: (async (url: string, init: RequestInit) => {
      sends.push({
        url,
        headers: init.headers as Record<string, string>,
        body: JSON.parse(String(init.body)),
      });
      if (opts.status === "throw") throw new Error("network");
      const status = opts.status ?? 200;
      return new Response(JSON.stringify(status === 200 ? { id: "resend-msg-1" } : { message: "x" }), { status });
    }) as unknown as typeof fetch,
  };
  return { deps, ledger, sends, contextCalls };
}

function post(body: unknown = { booking_id: BID }, secret = SECRET, method = "POST"): Request {
  return new Request("http://localhost/completion-receipt-email", {
    method,
    headers: { "content-type": "application/json", "x-skillmatch-dispatch-secret": secret },
    body: method === "GET" ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function call(req: Request, h: Harness) {
  const res = await handleReceiptRequest(req, h.deps);
  return { status: res.status, body: await res.json() as Record<string, unknown> };
}

test("boundary: 405, 500 without secret config, 401 wrong secret, 400 bad body", async () => {
  const h = harness();
  assert.equal((await call(post(undefined, SECRET, "GET"), h)).status, 405);
  const noSecret = harness();
  noSecret.deps.env.webhookSecret = undefined;
  assert.equal((await call(post(), noSecret)).status, 500);
  assert.equal((await call(post({ booking_id: BID }, "wrong"), h)).status, 401);
  assert.equal((await call(post("{"), h)).status, 400);
  assert.equal((await call(post({ booking_id: BID, to: "x@y.z" }), h)).status, 400);
  assert.equal(h.contextCalls.length, 0);
  assert.equal(h.sends.length, 0);
});

test("disabled unless COMPLETION_RECEIPT_ENABLED is exactly true", async () => {
  for (const enabled of [undefined, "1", "TRUE"]) {
    const h = harness({ enabled });
    assert.deepEqual((await call(post(), h)).body, { sent: false, reason: "disabled" });
    assert.equal(h.sends.length, 0);
  }
});

test("missing provider config is 503 and sends nothing", async () => {
  const h = harness();
  h.deps.env.from = undefined;
  assert.deepEqual((await call(post(), h)), { status: 503, body: { sent: false, reason: "not_configured" } });
  assert.equal(h.sends.length, 0);
});

test("sends once to the server-derived verified email with the dedup idempotency key", async () => {
  const h = harness();
  assert.deepEqual((await call(post(), h)).body, { sent: true });
  assert.equal(h.sends.length, 1);
  const s = h.sends[0];
  assert.equal(s.url, RESEND_URL);
  assert.equal(s.headers["idempotency-key"], `completion-receipt:${BID}`);
  assert.deepEqual(s.body.to, ["client@example.test"]);
  assert.equal(s.body.from, "SkillMatch <receipts@example.test>");
  assert.match(String(s.body.text), /PayMongo TEST MODE/);
  const entry = h.ledger.get(`completion-receipt:${BID}`)!;
  assert.deepEqual(entry, { status: "sent", attempts: 1, ref: "resend-msg-1", error: null });
});

test("replayed completion event does not send a second email", async () => {
  const h = harness();
  await call(post(), h);
  assert.deepEqual((await call(post(), h)).body, { sent: false, reason: "duplicate" });
  assert.deepEqual((await call(post({ booking_id: BID.toUpperCase() }), h)).body, { sent: false, reason: "duplicate" });
  assert.equal(h.sends.length, 1);
});

test("not completed / unverified email / unknown booking collapse to not_eligible", async () => {
  for (const context of [null, { ...CONTEXT, booking_status: "confirmed" }, { ...CONTEXT, client_email: "" }]) {
    const h = harness({ context });
    assert.deepEqual((await call(post(), h)).body, { sent: false, reason: "not_eligible" });
    assert.equal(h.sends.length, 0);
    assert.equal(h.ledger.size, 0);
  }
});

test("ledger unavailable fails closed (no send without durable dedup)", async () => {
  const h = harness({ ledgerDown: true });
  assert.equal((await call(post(), h)).status, 503);
  assert.equal(h.sends.length, 0);
});

test("context read failure is 503", async () => {
  const h = harness({ contextError: true });
  assert.equal((await call(post(), h)).status, 503);
});

test("provider failure is recorded, never thrown, and retries are capped", async () => {
  const h = harness({ status: 422 });
  for (let i = 0; i < 5; i++) {
    const got = await call(post(), h);
    assert.equal(got.status, 200);
  }
  assert.equal(h.sends.length, MAX_ATTEMPTS_PER_RECEIPT);
  const entry = h.ledger.get(`completion-receipt:${BID}`)!;
  assert.equal(entry.status, "failed");
  assert.equal(entry.error, "http_422");
});

test("network failure reports provider_unreachable and keeps the key retryable", async () => {
  const h = harness({ status: "throw" });
  assert.deepEqual((await call(post(), h)).body, { sent: false, reason: "provider_unreachable" });
  assert.equal(h.ledger.get(`completion-receipt:${BID}`)!.status, "failed");
});
