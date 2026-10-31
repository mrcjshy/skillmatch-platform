// ============================================================
// Lane C: Worker reminder dispatcher (I/O injected; no Deno/npm imports)
// ============================================================
//
// Caller: pg_cron -> pg_net every 15 minutes, body exactly {"tick":true},
// header x-skillmatch-dispatch-secret. verify_jwt is false for this
// function; the shared secret is the boundary (same posture as R5B).
//
// Flow per tick:
//   1. read confirmed bookings starting in (now, now + 36 h]
//   2. pure due-time rules (schedule.ts) pick the reminders due now
//   3. per reminder: claim the dedup key in the durable ledger, re-check
//      status/assignment/schedule/start/active Worker server-side while
//      reading the Worker's active Expo tokens, then send fixed copy
// A push is a delivery hint; nothing here mutates a Booking.

import {
  CANDIDATE_WINDOW_HOURS,
  canonicalIso,
  dueRemindersAt,
  MAX_ATTEMPTS_PER_REMINDER,
  MAX_SENDS_PER_TICK,
  reminderCopy,
} from "./schedule.ts";
import type { PlannedReminder, ReminderCandidate } from "./schedule.ts";

export const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";
/** Same versioned Android channel as push-notification (R5B/W7). */
export const ANDROID_CHANNEL_ID = "skillmatch_alerts_v1";
const PROVIDER_TIMEOUT_MS = 15_000;
const CANDIDATE_QUERY_LIMIT = 200;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type CandidateRow = {
  booking_id: unknown;
  worker_id: unknown;
  booked_at: unknown;
  scheduled_at: unknown;
};

export type ReminderDeps = {
  env: {
    webhookSecret?: string;
    expoAccessToken?: string;
    /** Must be exactly "true" to send. Anything else is a dry run. */
    enabled?: string;
  };
  now: () => number;
  listCandidates: (fromIso: string, toIso: string, limit: number) => Promise<CandidateRow[]>;
  /** Server re-check; returns active Expo tokens only while still eligible. */
  getPushTokens: (bookingId: string, workerId: string, scheduledAtIso: string) => Promise<string[]>;
  claim: (dedupKey: string, bookingId: string, maxAttempts: number) => Promise<boolean>;
  finish: (dedupKey: string, sent: boolean, error: string | null) => Promise<void>;
  fetchImpl?: typeof fetch;
};

export function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const len = Math.max(x.length, y.length);
  for (let i = 0; i < len; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/** The tick body carries no authority: exactly {"tick": true}. */
export function parseTickPayload(payload: unknown): boolean {
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) return false;
  const keys = Object.keys(payload);
  return keys.length === 1 && keys[0] === "tick" && (payload as { tick: unknown }).tick === true;
}

/** Drops malformed rows instead of trusting them. */
export function toCandidate(row: CandidateRow): ReminderCandidate | null {
  if (typeof row.booking_id !== "string" || !UUID_RE.test(row.booking_id)) return null;
  if (typeof row.worker_id !== "string" || !UUID_RE.test(row.worker_id)) return null;
  if (typeof row.scheduled_at !== "string") return null;
  const startMs = Date.parse(row.scheduled_at);
  if (!Number.isFinite(startMs)) return null;
  const bookedAtMs = typeof row.booked_at === "string" ? Date.parse(row.booked_at) : NaN;
  return { bookingId: row.booking_id, workerId: row.worker_id, startMs, bookedAtMs };
}

export function planTick(rows: CandidateRow[], nowMs: number): PlannedReminder[] {
  const planned: PlannedReminder[] = [];
  const keys = new Set<string>();
  for (const row of rows) {
    const c = toCandidate(row);
    if (!c) continue;
    for (const r of dueRemindersAt(c, nowMs)) {
      if (keys.has(r.dedupKey)) continue;
      keys.add(r.dedupKey);
      planned.push(r);
    }
  }
  planned.sort((a, b) => a.dueMs - b.dueMs || a.dedupKey.localeCompare(b.dedupKey));
  return planned.slice(0, MAX_SENDS_PER_TICK);
}

export function buildReminderMessages(reminder: PlannedReminder, tokens: string[]) {
  const copy = reminderCopy(reminder.type, reminder.startMs);
  return tokens.map((to) => ({
    to,
    sound: "default" as const,
    title: copy.title,
    body: copy.body,
    channelId: ANDROID_CHANNEL_ID,
    data: { kind: "booking_reminder" as const, booking_id: reminder.bookingId },
  }));
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleReminderTick(req: Request, deps: ReminderDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "POST required" });
  const secret = deps.env.webhookSecret?.trim();
  if (!secret) return json(500, { error: "server configuration incomplete" });
  const supplied = req.headers.get("x-skillmatch-dispatch-secret");
  if (typeof supplied !== "string" || !timingSafeEqual(supplied, secret)) {
    return json(401, { error: "unauthorized" });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(await req.text());
  } catch {
    return json(400, { error: "invalid request" });
  }
  if (!parseTickPayload(payload)) return json(400, { error: "invalid request" });

  const nowMs = deps.now();
  let rows: CandidateRow[];
  try {
    rows = await deps.listCandidates(
      canonicalIso(nowMs),
      canonicalIso(nowMs + CANDIDATE_WINDOW_HOURS * 3_600_000),
      CANDIDATE_QUERY_LIMIT,
    );
  } catch {
    return json(503, { error: "unavailable" });
  }
  const planned = planTick(Array.isArray(rows) ? rows : [], nowMs);

  if (deps.env.enabled !== "true") {
    return json(200, { dry_run: true, due: planned.length });
  }
  const expoToken = deps.env.expoAccessToken?.trim();
  if (!expoToken) return json(500, { error: "server configuration incomplete" });

  const fetchImpl = deps.fetchImpl ?? fetch;
  let sent = 0;
  let skipped = 0;
  let failed = 0;
  for (const reminder of planned) {
    let claimed: boolean;
    try {
      claimed = await deps.claim(reminder.dedupKey, reminder.bookingId, MAX_ATTEMPTS_PER_REMINDER);
    } catch {
      failed++;
      continue;
    }
    if (!claimed) {
      skipped++;
      continue;
    }

    let tokens: string[];
    try {
      tokens = await deps.getPushTokens(
        reminder.bookingId,
        reminder.workerId,
        canonicalIso(reminder.startMs),
      );
    } catch {
      await deps.finish(reminder.dedupKey, false, "targets_unavailable").catch(() => {});
      failed++;
      continue;
    }
    if (tokens.length === 0) {
      // Cancelled, completed, rescheduled, reassigned, past start, inactive
      // Worker, or no registered device. Bounded retries via the ledger.
      await deps.finish(reminder.dedupKey, false, "no_eligible_target").catch(() => {});
      skipped++;
      continue;
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);
    try {
      const res = await fetchImpl(EXPO_PUSH_URL, {
        method: "POST",
        signal: controller.signal,
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${expoToken}`,
        },
        body: JSON.stringify(buildReminderMessages(reminder, tokens)),
      });
      if (res.ok) {
        await deps.finish(reminder.dedupKey, true, null).catch(() => {});
        sent++;
      } else {
        await deps.finish(reminder.dedupKey, false, `http_${res.status}`).catch(() => {});
        failed++;
      }
    } catch {
      await deps.finish(reminder.dedupKey, false, "network").catch(() => {});
      failed++;
    } finally {
      clearTimeout(timer);
    }
  }
  return json(200, { due: planned.length, sent, skipped, failed });
}
