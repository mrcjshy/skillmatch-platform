import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PAYMENT_METHOD_DISPLAY_KEYS, PAYMENT_SERIES, ROLES, axisTicks, blockWidths, bookingSplit, describePart, describeSplit,
  fitsInside, formatShare, jobSplit, paymentRows, reportSplit, verificationSplit,
} from './chart-data.js';
import { BOOKING_KEYS, JOB_KEYS, PAYMENT_METHOD_KEYS, PAYMENT_STATUS_KEYS, REPORT_KEYS } from './domain.js';

const summary = {
  totalWorkers: 14, verifiedWorkers: 9, pendingWorkerVerifications: 2, totalClients: 11,
  jobsByStatus: { open: 3, matched: 5, completed: 17, cancelled: 4, unset: 0 },
  bookingsByStatus: { pending: 2, confirmed: 3, completed: 17, cancelled: 4, no_show: 1 },
  reportsByStatus: { submitted: 2, under_review: 1, resolved: 5, dismissed: 3 },
  paymentsByMethodStatus: {
    gcash: { pending: 1, paid: 6, refunded: 0, unset: 0 },
    maya: { pending: 0, paid: 3, refunded: 0, unset: 0 },
    qrph: { pending: 1, paid: 2, refunded: 0, unset: 0 },
    cod: { pending: 2, paid: 7, refunded: 1, unset: 0 },
    unset: { pending: 0, paid: 0, refunded: 0, unset: 4 },
  },
};

test('splits keep the domain order, exact counts and shares that sum to one', () => {
  const bookings = bookingSplit(summary);
  assert.deepEqual(bookings.parts.map((p) => p.key), BOOKING_KEYS);
  assert.equal(bookings.total, 27);
  assert.equal(bookings.parts.find((p) => p.key === 'completed').value, 17);
  assert.ok(Math.abs(bookings.parts.reduce((s, p) => s + p.share, 0) - 1) < 1e-9);
  assert.deepEqual(jobSplit(summary).parts.map((p) => p.key), JOB_KEYS);
  assert.deepEqual(reportSplit(summary).parts.map((p) => p.key), REPORT_KEYS);
});

test('a status keeps one colour role in every chart (colour follows the status, never its rank)', () => {
  assert.equal(ROLES.booking.completed, ROLES.job.completed);
  assert.equal(ROLES.booking.completed, ROLES.report.resolved);
  assert.equal(ROLES.booking.completed, ROLES.payment.paid);
  assert.equal(ROLES.booking.pending, ROLES.job.open);
  assert.equal(ROLES.booking.pending, ROLES.report.submitted);
  assert.equal(ROLES.booking.cancelled, ROLES.report.dismissed);
  assert.equal(ROLES.job.unset, ROLES.payment.unset);
  // Re-sorting the data never repaints a status: roles are looked up by key, not position.
  const reversed = { ...summary, bookingsByStatus: { pending: 17, confirmed: 3, completed: 2, cancelled: 4, no_show: 1 } };
  assert.deepEqual(bookingSplit(reversed).parts.map((p) => p.role), bookingSplit(summary).parts.map((p) => p.role));
});

test('an empty whole has zero shares, not NaN', () => {
  const empty = bookingSplit({ bookingsByStatus: { pending: 0, confirmed: 0, completed: 0, cancelled: 0, no_show: 0 } });
  assert.equal(empty.total, 0);
  assert.ok(empty.parts.every((p) => p.share === 0));
});

test('verification is verified, waiting and the rest, clamped so no part goes negative', () => {
  const split = verificationSplit(summary);
  assert.deepEqual(split.parts.map((p) => [p.key, p.value]), [['verified', 9], ['waiting', 2], ['rest', 3]]);
  assert.equal(split.total, 14);
  assert.deepEqual(split.parts.map((p) => p.role), ['ord-1', 'ord-2', 'ord-3']);
  const odd = verificationSplit({ totalWorkers: 5, verifiedWorkers: 7, pendingWorkerVerifications: 3 });
  assert.deepEqual(odd.parts.map((p) => p.value), [5, 0, 0]);
  const pendingHeavy = verificationSplit({ totalWorkers: 5, verifiedWorkers: 2, pendingWorkerVerifications: 9 });
  assert.deepEqual(pendingHeavy.parts.map((p) => p.value), [2, 3, 0]);
});

test('payments show only QR Ph, Cash and Not set, as native Admin; GCash and Maya are never drawn', () => {
  const rows = paymentRows(summary, (m) => (m === 'qrph' ? 'QR Ph (TEST)' : m));
  assert.deepEqual(PAYMENT_METHOD_DISPLAY_KEYS, ['qrph', 'cod', 'unset']);
  assert.deepEqual(rows.map((r) => r.key), ['qrph', 'cod', 'unset']);
  assert.ok(!rows.some((r) => r.key === 'gcash' || r.key === 'maya'));
  assert.equal(rows.find((r) => r.key === 'qrph').label, 'QR Ph (TEST)');
  assert.deepEqual(rows.find((r) => r.key === 'cod').parts.map((p) => p.value), [2, 7, 1, 0]);
  assert.equal(rows.reduce((s, r) => s + r.total, 0), 17);
  assert.deepEqual(PAYMENT_SERIES.map((s) => s.key), PAYMENT_STATUS_KEYS);
  // The server's full five-method shape still parses (domain.js is unchanged).
  assert.deepEqual(PAYMENT_METHOD_KEYS, ['gcash', 'maya', 'qrph', 'cod', 'unset']);
});

test('shares read as whole percents, with a visible sliver', () => {
  assert.equal(formatShare(17 / 27), '63%');
  assert.equal(formatShare(0), '0%');
  assert.equal(formatShare(0.004), '<1%');
  assert.equal(formatShare(1), '100%');
});

test('axis ticks are clean, start at zero and reach the largest value', () => {
  assert.deepEqual(axisTicks(10), [0, 2, 4, 6, 8, 10]);
  assert.deepEqual(axisTicks(3), [0, 1, 2, 3]);
  assert.deepEqual(axisTicks(7), [0, 2, 4, 6, 8]);
  assert.deepEqual(axisTicks(0), [0, 1]);
  assert.deepEqual(axisTicks(1240), [0, 500, 1000, 1500]);
  for (const max of [1, 4, 9, 13, 27, 99, 101, 640]) {
    const ticks = axisTicks(max);
    assert.equal(ticks[0], 0);
    assert.ok(ticks.at(-1) >= max, `top tick covers ${max}`);
    assert.ok(ticks.length <= 7, `few ticks for ${max}`);
  }
});

test('block widths share the track after the surface gaps; labels print only where they fit', () => {
  const widths = blockWidths([2, 3, 17, 4, 1], 308, 2);
  assert.ok(Math.abs(widths.reduce((s, w) => s + w, 0) - 300) < 1e-9);
  assert.ok(Math.abs(widths[2] - (300 * 17) / 27) < 1e-9);
  assert.deepEqual(blockWidths([0, 0], 100, 2), [0, 0]);
  assert.equal(fitsInside(16, 32), true);
  assert.equal(fitsInside(16, 31.9), false);
});

test('accessible names carry every part, in order, with counts and shares', () => {
  const split = bookingSplit(summary);
  assert.equal(describePart(split.parts[2], 'booking'), 'Completed: 17 bookings, 63%');
  assert.equal(describePart(split.parts[4], 'booking'), 'No-show: 1 booking, 4%');
  const text = describeSplit(split, 'booking', 'Bookings by status');
  assert.ok(text.startsWith('Bookings by status. 27 bookings in total. Pending: 2 bookings, 7%;'));
  assert.ok(text.endsWith('No-show: 1 booking, 4%.'));
});
