// ============================================================
// Lane C: Worker reminder due-time computation (pure, no I/O)
// ============================================================
//
// Asia/Manila is UTC+8 with no daylight saving time, so calendar math
// uses a fixed offset instead of host-timezone Date getters. Every
// function takes epoch milliseconds and never reads the system clock.
//
// The owner decides the times in the approvals file. They are named
// constants here so a decision changes one line.

export const MANILA_OFFSET_MINUTES = 8 * 60;

export type LocalTime = { hour: number; minute: number };

/** Previous-day reminder: this local time on the day before the job's Manila date. */
export const PREVIOUS_DAY_SEND_LOCAL: LocalTime = { hour: 18, minute: 0 };
/** Job-day reminder: this local time on the job's Manila date (or earlier, see lead). */
export const JOB_DAY_SEND_LOCAL: LocalTime = { hour: 7, minute: 0 };
/** Job-day reminder is sent no later than this many minutes before start. */
export const JOB_DAY_MIN_LEAD_MINUTES = 120;
/** Nothing is sent from QUIET_START_LOCAL until QUIET_END_LOCAL (Manila). */
export const QUIET_START_LOCAL: LocalTime = { hour: 21, minute: 0 };
export const QUIET_END_LOCAL: LocalTime = { hour: 5, minute: 0 };
/** A reminder missed by more than this (for example, scheduler outage) is dropped. */
export const MAX_LATENESS_MINUTES = 120;
/** Nothing is sent this close to (or after) the job start. */
export const MIN_LEAD_BEFORE_START_MINUTES = 30;
/** Candidate look-ahead for one scheduler tick. */
export const CANDIDATE_WINDOW_HOURS = 36;
/** Hard cap on reminder sends per scheduler tick. */
export const MAX_SENDS_PER_TICK = 50;
/** Per dedup key, total claim attempts (first send + retries). */
export const MAX_ATTEMPTS_PER_REMINDER = 3;

export type ReminderType = "previous_day" | "job_day";

const MINUTE_MS = 60_000;
const OFFSET_MS = MANILA_OFFSET_MINUTES * MINUTE_MS;

export type ManilaParts = {
  year: number;
  month: number; // 1-12
  day: number;
  hour: number;
  minute: number;
};

export function manilaParts(epochMs: number): ManilaParts {
  const shifted = new Date(epochMs + OFFSET_MS);
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: shifted.getUTCDate(),
    hour: shifted.getUTCHours(),
    minute: shifted.getUTCMinutes(),
  };
}

/** Epoch ms of a Manila wall-clock time. Day overflow/underflow rolls over. */
export function manilaLocalToEpochMs(
  year: number,
  month: number,
  day: number,
  time: LocalTime,
): number {
  return Date.UTC(year, month - 1, day, time.hour, time.minute) - OFFSET_MS;
}

function minutesOfDay(time: LocalTime): number {
  return time.hour * 60 + time.minute;
}

export function isManilaQuietTime(epochMs: number): boolean {
  const p = manilaParts(epochMs);
  const m = p.hour * 60 + p.minute;
  return m >= minutesOfDay(QUIET_START_LOCAL) || m < minutesOfDay(QUIET_END_LOCAL);
}

export type DueReminder = { type: ReminderType; dueMs: number };

/**
 * Logical reminders for one job start, before any "now" or booking-time
 * filtering. A job-day reminder that would fall before QUIET_END_LOCAL on
 * the job's own Manila date is omitted: the previous-day reminder covers
 * early-morning jobs.
 */
export function computeReminderDueTimes(startMs: number): DueReminder[] {
  const p = manilaParts(startMs);
  const out: DueReminder[] = [];

  const previousDay = manilaLocalToEpochMs(p.year, p.month, p.day - 1, PREVIOUS_DAY_SEND_LOCAL);
  if (startMs - previousDay >= MIN_LEAD_BEFORE_START_MINUTES * MINUTE_MS) {
    out.push({ type: "previous_day", dueMs: previousDay });
  }

  const jobDayFixed = manilaLocalToEpochMs(p.year, p.month, p.day, JOB_DAY_SEND_LOCAL);
  const jobDayLead = startMs - JOB_DAY_MIN_LEAD_MINUTES * MINUTE_MS;
  const jobDay = Math.min(jobDayFixed, jobDayLead);
  const quietEndOnJobDate = manilaLocalToEpochMs(p.year, p.month, p.day, QUIET_END_LOCAL);
  if (jobDay >= quietEndOnJobDate) {
    out.push({ type: "job_day", dueMs: jobDay });
  }
  return out;
}

export type ReminderCandidate = {
  bookingId: string;
  workerId: string;
  /** bookings.created_at; bookings are created already confirmed at Worker accept. */
  bookedAtMs: number;
  startMs: number;
};

export type PlannedReminder = {
  bookingId: string;
  workerId: string;
  startMs: number;
  type: ReminderType;
  dueMs: number;
  dedupKey: string;
};

/** Canonical ISO so "+00:00" vs "Z" or microsecond formatting cannot fork keys. */
export function canonicalIso(epochMs: number): string {
  return new Date(epochMs).toISOString();
}

export function buildReminderDedupKey(
  bookingId: string,
  workerId: string,
  startMs: number,
  type: ReminderType,
): string {
  return `worker-reminder:${bookingId}:${workerId}:${canonicalIso(startMs)}:${type}`;
}

/**
 * Reminders that are due at `nowMs` for one candidate. Rules:
 *  - not before the due time;
 *  - skipped if the due time had already passed when the booking was made;
 *  - dropped once more than MAX_LATENESS_MINUTES late;
 *  - never within MIN_LEAD_BEFORE_START_MINUTES of (or after) the start;
 *  - never during Manila quiet hours.
 * Booking status, assignment and schedule are re-checked at dispatch.
 */
export function dueRemindersAt(candidate: ReminderCandidate, nowMs: number): PlannedReminder[] {
  if (!Number.isFinite(candidate.startMs) || !Number.isFinite(nowMs)) return [];
  if (isManilaQuietTime(nowMs)) return [];
  const startCutoff = candidate.startMs - MIN_LEAD_BEFORE_START_MINUTES * MINUTE_MS;
  const out: PlannedReminder[] = [];
  for (const due of computeReminderDueTimes(candidate.startMs)) {
    if (Number.isFinite(candidate.bookedAtMs) && due.dueMs < candidate.bookedAtMs) continue;
    if (nowMs < due.dueMs) continue;
    const cutoff = Math.min(due.dueMs + MAX_LATENESS_MINUTES * MINUTE_MS, startCutoff);
    if (nowMs >= cutoff) continue;
    out.push({
      bookingId: candidate.bookingId,
      workerId: candidate.workerId,
      startMs: candidate.startMs,
      type: due.type,
      dueMs: due.dueMs,
      dedupKey: buildReminderDedupKey(
        candidate.bookingId,
        candidate.workerId,
        candidate.startMs,
        due.type,
      ),
    });
  }
  return out;
}

/** "9:00 AM" in Manila time. Deterministic; does not depend on host ICU. */
export function formatManilaClock(epochMs: number): string {
  const p = manilaParts(epochMs);
  const suffix = p.hour < 12 ? "AM" : "PM";
  const h12 = p.hour % 12 === 0 ? 12 : p.hour % 12;
  return `${h12}:${String(p.minute).padStart(2, "0")} ${suffix}`;
}

export const REMINDER_COPY: Record<ReminderType, { title: string; when: string }> = {
  previous_day: { title: "Job tomorrow", when: "tomorrow" },
  job_day: { title: "Job today", when: "today" },
};

/** Lock-screen-safe copy: no address, Client name, job title or contact. */
export function reminderCopy(type: ReminderType, startMs: number): { title: string; body: string } {
  const copy = REMINDER_COPY[type];
  return {
    title: copy.title,
    body: `You have a SkillMatch job ${copy.when} at ${formatManilaClock(startMs)}. Open SkillMatch for details.`,
  };
}
