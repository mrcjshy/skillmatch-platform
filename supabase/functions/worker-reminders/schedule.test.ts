// Runs under `node --test` (Node 22.6+ type stripping) and `deno test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildReminderDedupKey,
  canonicalIso,
  computeReminderDueTimes,
  dueRemindersAt,
  formatManilaClock,
  isManilaQuietTime,
  manilaParts,
  reminderCopy,
} from "./schedule.ts";
import type { ReminderCandidate } from "./schedule.ts";

const MIN = 60_000;
/** Synthetic Manila wall clock to epoch ms (UTC+8, no DST). */
function M(y: number, mo: number, d: number, h: number, mi = 0): number {
  return Date.UTC(y, mo - 1, d, h - 8, mi);
}
const B = "11111111-1111-4111-8111-111111111111";
const W = "22222222-2222-4222-8222-222222222222";

function cand(startMs: number, bookedAtMs: number): ReminderCandidate {
  return { bookingId: B, workerId: W, startMs, bookedAtMs };
}
function types(list: Array<{ type: string }>): string[] {
  return list.map((r) => r.type);
}

test("manila parts cross the UTC date boundary", () => {
  // 2026-10-14T23:30Z is 2026-10-15 07:30 in Manila.
  const p = manilaParts(Date.UTC(2026, 9, 14, 23, 30));
  assert.deepEqual(p, { year: 2026, month: 10, day: 15, hour: 7, minute: 30 });
});

test("standard 09:00 job: previous day 18:00 and job day 07:00", () => {
  const start = M(2026, 10, 15, 9);
  assert.deepEqual(computeReminderDueTimes(start), [
    { type: "previous_day", dueMs: M(2026, 10, 14, 18) },
    { type: "job_day", dueMs: M(2026, 10, 15, 7) },
  ]);
});

test("job day reminder moves to start minus 2h for an 08:00 job", () => {
  const start = M(2026, 10, 15, 8);
  const due = computeReminderDueTimes(start);
  assert.equal(due[1].dueMs, M(2026, 10, 15, 6));
});

test("early-morning job (06:30) gets only the previous-day reminder", () => {
  const due = computeReminderDueTimes(M(2026, 10, 15, 6, 30));
  assert.deepEqual(types(due), ["previous_day"]);
});

test("07:00 job keeps a 05:00 job-day reminder (quiet end is inclusive)", () => {
  const due = computeReminderDueTimes(M(2026, 10, 15, 7));
  assert.deepEqual(due[1], { type: "job_day", dueMs: M(2026, 10, 15, 5) });
});

test("00:30 job: previous-day 18:00 only; job-day would be before 05:00", () => {
  const due = computeReminderDueTimes(M(2026, 10, 15, 0, 30));
  assert.deepEqual(due, [{ type: "previous_day", dueMs: M(2026, 10, 14, 18) }]);
});

test("month boundary: 1 Nov job reminds on 31 Oct", () => {
  const due = computeReminderDueTimes(M(2026, 11, 1, 10));
  assert.equal(due[0].dueMs, M(2026, 10, 31, 18));
  assert.equal(manilaParts(due[0].dueMs).day, 31);
});

test("year boundary: 1 Jan job reminds on 31 Dec of the previous year", () => {
  const due = computeReminderDueTimes(M(2027, 1, 1, 9));
  assert.deepEqual(manilaParts(due[0].dueMs), {
    year: 2026, month: 12, day: 31, hour: 18, minute: 0,
  });
});

test("leap day boundaries", () => {
  assert.equal(computeReminderDueTimes(M(2028, 3, 1, 9))[0].dueMs, M(2028, 2, 29, 18));
  assert.equal(computeReminderDueTimes(M(2028, 2, 29, 9))[0].dueMs, M(2028, 2, 28, 18));
});

test("not yet due before the due time; due at exactly the due time", () => {
  const c = cand(M(2026, 10, 15, 9), M(2026, 10, 10, 9));
  assert.deepEqual(dueRemindersAt(c, M(2026, 10, 14, 17, 59)), []);
  assert.deepEqual(types(dueRemindersAt(c, M(2026, 10, 14, 18))), ["previous_day"]);
});

test("late within the lateness window still sends; beyond it drops", () => {
  const c = cand(M(2026, 10, 15, 9), M(2026, 10, 10, 9));
  assert.deepEqual(types(dueRemindersAt(c, M(2026, 10, 14, 19, 59))), ["previous_day"]);
  assert.deepEqual(dueRemindersAt(c, M(2026, 10, 14, 20)), []);
});

test("job day reminder window on the job date", () => {
  const c = cand(M(2026, 10, 15, 9), M(2026, 10, 10, 9));
  assert.deepEqual(dueRemindersAt(c, M(2026, 10, 15, 6, 59)), []);
  assert.deepEqual(types(dueRemindersAt(c, M(2026, 10, 15, 7, 15))), ["job_day"]);
  // Start cutoff (start - 30 min = 08:30) is earlier than due + 2h (09:00).
  assert.deepEqual(dueRemindersAt(c, M(2026, 10, 15, 8, 30)), []);
});

test("booking confirmed after the previous-day window: skip it, keep job day", () => {
  const c = cand(M(2026, 10, 15, 10), M(2026, 10, 14, 19));
  assert.deepEqual(dueRemindersAt(c, M(2026, 10, 14, 19, 15)), []);
  assert.deepEqual(types(dueRemindersAt(c, M(2026, 10, 15, 7))), ["job_day"]);
});

test("same-day booking after both windows gets nothing", () => {
  const c = cand(M(2026, 10, 15, 14), M(2026, 10, 15, 9));
  for (const now of [M(2026, 10, 15, 9, 15), M(2026, 10, 15, 11), M(2026, 10, 15, 13)]) {
    assert.deepEqual(dueRemindersAt(c, now), []);
  }
});

test("booking made at 17:59 for tomorrow still gets the 18:00 reminder", () => {
  const c = cand(M(2026, 10, 15, 9), M(2026, 10, 14, 17, 59));
  assert.deepEqual(types(dueRemindersAt(c, M(2026, 10, 14, 18))), ["previous_day"]);
});

test("past-start job never sends", () => {
  const c = cand(M(2026, 10, 15, 9), M(2026, 10, 10, 9));
  assert.deepEqual(dueRemindersAt(c, M(2026, 10, 15, 9, 1)), []);
  assert.deepEqual(dueRemindersAt(c, M(2026, 10, 16, 7)), []);
});

test("quiet hours suppress everything", () => {
  assert.equal(isManilaQuietTime(M(2026, 10, 14, 21)), true);
  assert.equal(isManilaQuietTime(M(2026, 10, 15, 4, 59)), true);
  assert.equal(isManilaQuietTime(M(2026, 10, 15, 5)), false);
  assert.equal(isManilaQuietTime(M(2026, 10, 14, 20, 59)), false);
});

test("a tick sweep over a whole day yields each logical reminder in exactly one window", () => {
  // Every 15 min from 2 days before the start until the start: dedup keys are stable.
  const start = M(2026, 10, 15, 8);
  const c = cand(start, M(2026, 10, 1, 8));
  const seen = new Map<string, number>();
  for (let t = start - 48 * 60 * MIN; t <= start; t += 15 * MIN) {
    for (const r of dueRemindersAt(c, t)) {
      seen.set(r.dedupKey, (seen.get(r.dedupKey) ?? 0) + 1);
    }
  }
  assert.deepEqual([...seen.keys()].map((k) => k.split(":").pop()), ["previous_day", "job_day"]);
  // Both windows are open for several ticks: the ledger, not timing, enforces once.
  for (const count of seen.values()) assert.ok(count >= 2);
});

test("dedup key is canonical and changes when the schedule changes", () => {
  const a = buildReminderDedupKey(B, W, Date.parse("2026-10-15T01:00:00+00:00"), "job_day");
  const b = buildReminderDedupKey(B, W, Date.parse("2026-10-15T01:00:00.000Z"), "job_day");
  const moved = buildReminderDedupKey(B, W, Date.parse("2026-10-15T02:00:00Z"), "job_day");
  assert.equal(a, b);
  assert.notEqual(a, moved);
  assert.equal(canonicalIso(Date.parse("2026-10-15T01:00:00+00:00")), "2026-10-15T01:00:00.000Z");
});

test("clock and copy are Manila-based and lock-screen safe", () => {
  assert.equal(formatManilaClock(M(2026, 10, 15, 0, 5)), "12:05 AM");
  assert.equal(formatManilaClock(M(2026, 10, 15, 12)), "12:00 PM");
  assert.equal(formatManilaClock(M(2026, 10, 15, 13, 30)), "1:30 PM");
  const copy = reminderCopy("previous_day", M(2026, 10, 15, 9));
  assert.equal(copy.title, "Job tomorrow");
  assert.equal(copy.body, "You have a SkillMatch job tomorrow at 9:00 AM. Open SkillMatch for details.");
  assert.equal(reminderCopy("job_day", M(2026, 10, 15, 9)).title, "Job today");
});
