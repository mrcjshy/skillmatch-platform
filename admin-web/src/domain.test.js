// Parsers and rules ported from the native Admin (skillmatch-mobile-rc/src/lib).
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PAYMENT_METHOD_KEYS,
  PAYMENT_METHOD_LABELS,
  allowedReviewStatuses,
  formatNotificationLabel,
  isUnread,
  parseAnalytics,
  parseDirectoryPage,
  parseDisciplineState,
  parseIdentityForReview,
  parsePendingReviews,
  parseUserDetail,
  validateAdminResponse,
  validateRejectionReason,
} from './domain.js';

const bucket = (keys) => Object.fromEntries(keys.map((k) => [k, 1]));
const PAY = bucket(['pending', 'paid', 'refunded', 'unset']);
const analyticsRow = () => ({
  as_of: '2026-10-14T01:02:03.456Z',
  total_workers: 5,
  verified_workers: '3',
  pending_worker_verifications: 2,
  total_clients: 4,
  jobs_by_status: bucket(['open', 'matched', 'completed', 'cancelled', 'unset']),
  bookings_by_status: bucket(['pending', 'confirmed', 'completed', 'cancelled', 'no_show']),
  completed_bookings: 1,
  payments_by_method_status: { gcash: PAY, maya: PAY, qrph: PAY, cod: PAY, unset: PAY },
  reports_by_status: bucket(['submitted', 'under_review', 'resolved', 'dismissed']),
  reports_needing_attention: 2,
});

test('parseAnalytics accepts the exact summary shape', () => {
  const summary = parseAnalytics([analyticsRow()]);
  assert.equal(summary.verifiedWorkers, 3);
  assert.equal(summary.paymentsByMethodStatus.qrph.paid, 1);
});

test('all five payment methods keep their identifiers, and GCash and Maya are not labelled legacy', () => {
  assert.deepEqual(PAYMENT_METHOD_KEYS, ['gcash', 'maya', 'qrph', 'cod', 'unset']);
  assert.deepEqual(PAYMENT_METHOD_LABELS, { gcash: 'GCash', maya: 'Maya', qrph: 'QR Ph', cod: 'Cash', unset: 'Not set' });
});

test('parseAnalytics rejects a wrong row count, extra bucket key or negative count', () => {
  assert.throws(() => parseAnalytics([]));
  assert.throws(() => parseAnalytics([analyticsRow(), analyticsRow()]));
  const extra = analyticsRow();
  extra.jobs_by_status.surprise = 1;
  assert.throws(() => parseAnalytics([extra]));
  const negative = analyticsRow();
  negative.total_clients = -1;
  assert.throws(() => parseAnalytics([negative]));
  const badDate = analyticsRow();
  badDate.as_of = '2026-02-30T00:00:00Z';
  assert.throws(() => parseAnalytics([badDate]));
});

const workerItem = {
  user_id: '11111111-1111-4111-8111-111111111111', full_name: 'Ana', is_active: true,
  created_at: null, has_profile: true, is_verified: false, availability_status: 'available',
};

test('parseDirectoryPage validates page envelope and item keys', () => {
  const page = parseDirectoryPage([{ total_count: '1', page: 1, page_size: 20, items: [workerItem] }], 'worker');
  assert.equal(page.total_count, 1);
  assert.throws(() => parseDirectoryPage([{ total_count: 1, page: 1, page_size: 20, items: [workerItem] }], 'client'));
  assert.throws(() => parseDirectoryPage([{ total_count: 1, page: 0, page_size: 20, items: [] }], 'worker'));
  assert.throws(() => parseDirectoryPage([{ total_count: 1, page: 1, page_size: 20, items: [], x: 1 }], 'worker'));
  assert.throws(() => parseDirectoryPage(
    [{ total_count: 1, page: 1, page_size: 20, items: [{ ...workerItem, has_profile: false }] }], 'worker'));
});

test('parseUserDetail returns null for no row and rejects a mismatched id', () => {
  const id = '22222222-2222-4222-8222-222222222222';
  assert.equal(parseUserDetail(null, 'client', id), null);
  const row = { user_id: id, full_name: 'Bo', is_active: true, created_at: null, posted_jobs_count: '3' };
  assert.equal(parseUserDetail(row, 'client', id).posted_jobs_count, 3);
  assert.throws(() => parseUserDetail({ ...row, user_id: workerItem.user_id }, 'client', id));
  assert.throws(() => parseUserDetail(row, 'worker', id));
});

test('identity review parsers drop malformed rows and require a storage path', () => {
  const row = {
    user_id: 'u', document_id: 'd', full_name: 'Cy', phone: '', barangay: 'Sto. Rosario', city: null,
    id_type: 'passport', submitted_at: '2026-10-01T00:00:00Z', skills: ['Plumbing', 3],
  };
  const rows = parsePendingReviews([row, { ...row, id_type: 'library_card' }]);
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].skills, ['Plumbing']);
  assert.equal(rows[0].phone, null);
  assert.equal(parseIdentityForReview([row]), null);
  assert.equal(parseIdentityForReview([{ ...row, storage_path: 'p/x.jpg' }]).storagePath, 'p/x.jpg');
  assert.equal(parseIdentityForReview([]), null);
});

test('rejection reason must be 1-500 characters after trimming', () => {
  assert.notEqual(validateRejectionReason('   '), null);
  assert.notEqual(validateRejectionReason('x'.repeat(501)), null);
  assert.equal(validateRejectionReason(' blurry photo '), null);
});

test('report review targets and response rules match native Admin', () => {
  assert.deepEqual(allowedReviewStatuses('submitted'), ['under_review', 'resolved', 'dismissed']);
  assert.deepEqual(allowedReviewStatuses('under_review'), ['resolved', 'dismissed']);
  assert.deepEqual(allowedReviewStatuses('resolved'), []);
  assert.deepEqual(validateAdminResponse('under_review', '  '), { ok: true, response: null });
  assert.deepEqual(validateAdminResponse('resolved', '  '), { ok: false, reason: 'empty' });
  assert.deepEqual(validateAdminResponse('dismissed', ' ok '), { ok: true, response: 'ok' });
  assert.deepEqual(validateAdminResponse('resolved', 'x'.repeat(2001)), { ok: false, reason: 'too_long' });
});

test('parseDisciplineState enforces the strike-count range', () => {
  assert.deepEqual(parseDisciplineState([{ eligible: true, current_strike_count: 2, would_suspend: true }]),
    { eligible: true, currentStrikeCount: 2, wouldSuspend: true });
  assert.deepEqual(parseDisciplineState([{ eligible: false, current_strike_count: null, would_suspend: false }]),
    { eligible: false, currentStrikeCount: null, wouldSuspend: false });
  assert.throws(() => parseDisciplineState([{ eligible: true, current_strike_count: 4, would_suspend: true }]));
  assert.throws(() => parseDisciplineState([]));
});

test('notification labels never leak a raw type, and NULL is unread', () => {
  assert.equal(formatNotificationLabel('report_submitted'), 'Report submitted');
  assert.equal(formatNotificationLabel('raw_db_value'), 'Notification');
  assert.equal(isUnread(null), true);
  assert.equal(isUnread(false), true);
  assert.equal(isUnread(true), false);
});
