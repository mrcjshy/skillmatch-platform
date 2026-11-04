/**
 * Dashboard chart maths. Pure: no DOM and no colours.
 *
 * Every status maps to one lifecycle role, and admin.css gives each role one hue: waiting (amber),
 * in progress (aqua), done (green), stopped (violet), no-show (red), not set (cool gray). The hues
 * come from the dataviz reference palette and were validated as a set on the white card surface
 * with its six checks, all pairs within each chart, because a zero part makes any two statuses
 * neighbours. Parts stay in the domain's own order, so a status keeps its colour in every chart and
 * on every refresh.
 */
import {
  BOOKING_KEYS, BOOKING_LABELS, JOB_KEYS, JOB_LABELS, PAYMENT_METHOD_LABELS,
  PAYMENT_STATUS_KEYS, PAYMENT_STATUS_LABELS, REPORT_KEYS, REPORT_LABELS, plural,
} from './domain.js';

/**
 * What the Admin dashboard shows, as native Admin (PAYMENT_METHOD_DISPLAY_KEYS in
 * skillmatch-mobile src/lib/admin-analytics.ts): SkillMatch's two methods (QR Ph, Cash) and Not set.
 * The server summary still carries GCash and Maya buckets, and domain.js still parses its full shape.
 */
export const PAYMENT_METHOD_DISPLAY_KEYS = ['qrph', 'cod', 'unset'];

export const ROLES = {
  booking: { pending: 'waiting', confirmed: 'progress', completed: 'done', cancelled: 'stopped', no_show: 'noshow' },
  job: { open: 'waiting', matched: 'progress', completed: 'done', cancelled: 'stopped', unset: 'unset' },
  report: { submitted: 'waiting', under_review: 'progress', resolved: 'done', dismissed: 'stopped' },
  payment: { pending: 'waiting', paid: 'done', refunded: 'stopped', unset: 'unset' },
};

/** One whole split into parts, in the given key order. */
export function splitOf(keys, labels, roles, bucket) {
  const total = keys.reduce((sum, key) => sum + bucket[key], 0);
  return {
    total,
    parts: keys.map((key) => ({
      key, label: labels[key], role: roles[key], value: bucket[key], share: total > 0 ? bucket[key] / total : 0,
    })),
  };
}

export const bookingSplit = (summary) => splitOf(BOOKING_KEYS, BOOKING_LABELS, ROLES.booking, summary.bookingsByStatus);
export const jobSplit = (summary) => splitOf(JOB_KEYS, JOB_LABELS, ROLES.job, summary.jobsByStatus);
export const reportSplit = (summary) => splitOf(REPORT_KEYS, REPORT_LABELS, ROLES.report, summary.reportsByStatus);

const VERIFICATION_LABELS = { verified: 'Verified', waiting: 'Waiting for ID review', rest: 'Not verified' };
/** An ordered scale (furthest along is darkest), so it takes the one-hue ordinal ramp, not status hues. */
const VERIFICATION_ROLES = { verified: 'ord-1', waiting: 'ord-2', rest: 'ord-3' };

/** Workers by verification stage. Clamped so an inconsistent snapshot can never draw a negative part. */
export function verificationSplit(summary) {
  const total = summary.totalWorkers;
  const verified = Math.min(summary.verifiedWorkers, total);
  const waiting = Math.min(summary.pendingWorkerVerifications, total - verified);
  const rest = total - verified - waiting;
  return splitOf(['verified', 'waiting', 'rest'], VERIFICATION_LABELS, VERIFICATION_ROLES, { verified, waiting, rest });
}

/** Payment status series, in the stacking order. */
export const PAYMENT_SERIES = PAYMENT_STATUS_KEYS.map((key) => ({
  key, label: PAYMENT_STATUS_LABELS[key], role: ROLES.payment[key],
}));

/** One stacked bar per displayed payment method: Bookings split by payment status. */
export function paymentRows(summary, methodLabel = (method) => PAYMENT_METHOD_LABELS[method]) {
  return PAYMENT_METHOD_DISPLAY_KEYS.map((method) => ({
    key: method,
    label: methodLabel(method),
    ...splitOf(PAYMENT_STATUS_KEYS, PAYMENT_STATUS_LABELS, ROLES.payment, summary.paymentsByMethodStatus[method]),
  }));
}

/** 63%; "<1%" for a sliver that would otherwise read as nothing. Counts stay exact everywhere. */
export function formatShare(share) {
  if (!(share > 0)) return '0%';
  const pct = share * 100;
  return pct < 1 ? '<1%' : `${Math.round(pct)}%`;
}

/** Clean axis ticks from 0 to at least `max`, stepping 1, 2 or 5 × 10^k, never below 1 (counts). */
export function axisTicks(max, intervals = 5) {
  if (!(max > 0)) return [0, 1];
  const raw = max / intervals;
  const magnitude = 10 ** Math.floor(Math.log10(raw));
  const step = Math.max(1, [1, 2, 5, 10].map((m) => m * magnitude).find((s) => s >= raw));
  const top = Math.ceil(max / step) * step;
  const ticks = [];
  for (let value = 0; value <= top; value += step) ticks.push(value);
  return ticks;
}

/** Widths of the blocks of a segmented bar `trackWidth` wide, with `gap` px of surface between blocks. */
export function blockWidths(values, trackWidth, gap) {
  const total = values.reduce((sum, value) => sum + value, 0);
  const room = Math.max(0, trackWidth - gap * Math.max(0, values.length - 1));
  return values.map((value) => (total > 0 ? (room * value) / total : 0));
}

/** A count prints inside its block only with `padding` px clear on both sides; else hover, focus and the table carry it. */
export const fitsInside = (textWidth, blockWidth, padding = 8) => blockWidth >= textWidth + padding * 2;

/** "Completed: 17 bookings, 63%" — the accessible name of one part. */
export const describePart = (part, noun) => `${part.label}: ${plural(part.value, noun)}, ${formatShare(part.share)}`;

/** The accessible name of a whole bar: its total, then every part in order. */
export function describeSplit(split, noun, title) {
  const parts = split.parts.map((part) => describePart(part, noun)).join('; ');
  return `${title}. ${plural(split.total, noun)} in total. ${parts}.`;
}
