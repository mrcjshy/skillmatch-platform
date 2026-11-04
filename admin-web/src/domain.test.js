// Parsers and rules ported from the native Admin (skillmatch-mobile-rc/src/lib).
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PAYMENT_METHOD_KEYS,
  PAYMENT_METHOD_LABELS,
  allowedReviewStatuses,
  formatNotificationLabel,
  formatBirthDate,
  formatHomeAddress,
  formatSkillExperience,
  isUnread,
  moderationActionCopy,
  normaliseModerationReason,
  parseAccountProfile,
  parseAnalytics,
  parseDirectoryPage,
  parseDisciplineState,
  parseIdentityForReview,
  parseModeration,
  parseModerationResult,
  parsePendingReviews,
  parseUserDetail,
  strikeSummary,
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

// MOD-01 account moderation
const MOD_ID = '12345678-1234-1234-1234-123456789abc';
const modRead = { is_active: false, strike_count: 3, last_action: null, last_reason: null, last_action_at: null };
const modBan = { is_active: false, strike_count: null, last_action: 'ban', last_reason: 'Abuse', last_action_at: '2026-11-03T12:00:00Z' };

test('MOD-01 moderation read accepts one exact row and rejects anything else', () => {
  assert.deepEqual(parseModeration([modRead]), modRead);
  assert.deepEqual(parseModeration([modBan]), modBan);
  for (const bad of [
    [{ ...modRead, email: 'x@example.test' }], [modRead, modRead], [], modRead, null,
    [{ ...modRead, strike_count: 4 }], [{ ...modRead, strike_count: -1 }],
    [{ ...modBan, last_action: 'warn' }], [{ ...modBan, last_reason: null }],
  ]) assert.throws(() => parseModeration(bad));
});

test('MOD-01 write result must name the requested account', () => {
  const row = { user_id: MOD_ID, is_active: true, strike_count: 0, changed: true };
  assert.deepEqual(parseModerationResult([row], MOD_ID), row);
  assert.throws(() => parseModerationResult([{ ...row, user_id: '12345678-1234-1234-1234-123456789abd' }], MOD_ID));
  assert.throws(() => parseModerationResult([{ ...row, changed: 1 }], MOD_ID));
});

test('MOD-01 reason, strike copy and error copy', () => {
  assert.equal(normaliseModerationReason('  Abuse '), 'Abuse');
  assert.equal(normaliseModerationReason('   '), null);
  assert.equal(normaliseModerationReason('a'.repeat(501)), null);
  assert.equal(strikeSummary(2), '2 of 3');
  assert.equal(strikeSummary(null), 'No Worker profile');
  assert.match(moderationActionCopy({ code: 'SM409' }), /cannot be moderated/);
  assert.match(moderationActionCopy({ code: '22023' }), /reason/);
  assert.match(moderationActionCopy({ code: 'XX000', message: 'raw' }), /Unable to update/);
  assert.equal(formatNotificationLabel('account_reinstated'), 'Account reinstated');
});

// REG-01 account profile / Worker resume
const REG_ID = '12345678-1234-1234-1234-123456789abc';
const regClient = {
  user_id: REG_ID, role: 'client', full_name: 'Ana Santos', first_name: 'Ana', middle_name: null, last_name: 'Santos',
  name_suffix: null, email: 'ana@example.test', phone: '+639171234567', address_street: '5 B. Morcilla',
  address_barangay: 'Poblacion', address_city: 'Pateros', address_province: 'Metro Manila',
  client_account_type: 'business', business_name: 'Santos Bakery', profile_completed_at: '2026-11-03T00:00:00Z',
};
const regWorker = {
  ...regClient, role: 'worker', client_account_type: null, business_name: null, birth_date: '1990-05-21',
  education_level: 'vocational', school_name: null, resume_completed_at: null,
  work_history: [{ employer: 'ABC', role: 'Carpenter', start_year: 2018, end_year: null }],
  skills: [{ name: 'Carpentry', proficiency: 'expert', years: 7 }],
};

test('REG-01 profile parser accepts exact Client and Worker objects only', () => {
  assert.deepEqual(parseAccountProfile(regClient, REG_ID), regClient);
  assert.deepEqual(parseAccountProfile(regWorker, REG_ID), regWorker);
  for (const bad of [
    { ...regClient, password: 'x' }, { ...regClient, birth_date: null }, { ...regWorker, education_level: 'phd' },
    { ...regWorker, education_level: 'toString' }, { ...regWorker, skills: [{ name: 'X', proficiency: null, years: 'many' }] },
    { ...regClient, user_id: '12345678-1234-1234-1234-123456789abd' }, { ...regClient, role: 'administrator' }, [regClient], null,
  ]) assert.throws(() => parseAccountProfile(bad, REG_ID));
});

test('REG-01 profile formatting', () => {
  assert.equal(formatHomeAddress(regClient), '5 B. Morcilla, Brgy. Poblacion, Pateros, Metro Manila');
  assert.equal(formatBirthDate('1990-05-21', new Date('2026-11-03T04:00:00Z')), 'May 21, 1990 (age 36)');
  // No skill level anywhere (owner, 2026-11-05): a stored level is ignored, years stay.
  assert.equal(formatSkillExperience({ proficiency: 'expert', years: 7 }), '7 years');
  assert.equal(formatSkillExperience({ proficiency: 'beginner', years: 1 }), '1 year');
  assert.equal(formatSkillExperience({ proficiency: 'intermediate', years: null }), 'Not provided');
  assert.equal(formatSkillExperience({ proficiency: null, years: null }), 'Not provided');
});
