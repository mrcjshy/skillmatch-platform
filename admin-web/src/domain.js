/**
 * Response parsers, labels and copy ported from the native Admin
 * (skillmatch-mobile-rc/src/lib: admin-analytics, admin-directories,
 * admin-user-detail, worker-identity, reports, notifications,
 * admin-presentation, status-presentation). Parity only: no new fields,
 * counts or rules. A malformed response throws instead of rendering.
 */

/* ------------------------------------------------------------------ *
 * Shared helpers
 * ------------------------------------------------------------------ */

export const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
export const isUuid = (value) => typeof value === 'string' && UUID.test(value);

class InvalidResponse extends Error {
  constructor(message = 'The response was incomplete or invalid. Please try again.') {
    super(message);
    this.name = 'InvalidResponse';
  }
}

function record(value) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new InvalidResponse();
  return value;
}

function count(value) {
  const parsed = typeof value === 'number'
    ? value
    : typeof value === 'string' && /^(0|[1-9]\d*)$/.test(value) ? Number(value) : NaN;
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new InvalidResponse();
  return parsed;
}

function text(value) {
  return typeof value === 'string' && value.trim() !== '' ? value : null;
}

function sameKeys(row, keys) {
  const actual = Object.keys(row);
  return actual.length === keys.length && keys.every((key) => actual.includes(key));
}

export function plural(n, singular, many = `${singular}s`) {
  return `${n.toLocaleString()} ${n === 1 ? singular : many}`;
}

/** Device-local display of a stored instant, like native `formatDetailDateTime`. */
export function formatDateTime(iso) {
  if (typeof iso !== 'string') return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
}

/* ------------------------------------------------------------------ *
 * Analytics — get_admin_analytics_summary
 * ------------------------------------------------------------------ */

export const JOB_KEYS = ['open', 'matched', 'completed', 'cancelled', 'unset'];
export const BOOKING_KEYS = ['pending', 'confirmed', 'completed', 'cancelled', 'no_show'];
export const PAYMENT_METHOD_KEYS = ['gcash', 'maya', 'qrph', 'cod', 'unset'];
export const PAYMENT_STATUS_KEYS = ['pending', 'paid', 'refunded', 'unset'];
export const REPORT_KEYS = ['submitted', 'under_review', 'resolved', 'dismissed'];

export const JOB_LABELS = { open: 'Open', matched: 'Matched', completed: 'Completed', cancelled: 'Cancelled', unset: 'Not set' };
export const BOOKING_LABELS = { pending: 'Pending', confirmed: 'Confirmed', completed: 'Completed', cancelled: 'Cancelled', no_show: 'No-show' };
export const PAYMENT_METHOD_LABELS = { gcash: 'GCash', maya: 'Maya', qrph: 'QR Ph', cod: 'Cash', unset: 'Not set' };
export const PAYMENT_STATUS_LABELS = { pending: 'Pending', paid: 'Paid', refunded: 'Refunded', unset: 'Not set' };
export const REPORT_LABELS = { submitted: 'Submitted', under_review: 'Under review', resolved: 'Resolved', dismissed: 'Dismissed' };

function bucket(value, keys) {
  const source = record(value);
  if (Object.keys(source).length !== keys.length) throw new InvalidResponse();
  const result = {};
  for (const key of keys) result[key] = count(source[key]);
  return result;
}

function timestamp(value) {
  if (typeof value !== 'string') throw new InvalidResponse();
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) throw new InvalidResponse();
  const [, y, mo, d, h, mi, s] = match.map(Number);
  const calendar = new Date(Date.UTC(y, mo - 1, d));
  if (calendar.getUTCFullYear() !== y || calendar.getUTCMonth() + 1 !== mo || calendar.getUTCDate() !== d ||
      h > 23 || mi > 59 || s > 59 || !Number.isFinite(Date.parse(value))) {
    throw new InvalidResponse();
  }
  return value;
}

export function sumBucket(values) {
  const total = Object.values(values).reduce((sum, n) => sum + n, 0);
  if (!Number.isSafeInteger(total)) throw new InvalidResponse();
  return total;
}

export function parseAnalytics(data) {
  if (!Array.isArray(data) || data.length !== 1) throw new InvalidResponse();
  const source = record(data[0]);
  const methods = record(source.payments_by_method_status);
  if (Object.keys(methods).length !== PAYMENT_METHOD_KEYS.length) throw new InvalidResponse();
  const payments = {};
  for (const method of PAYMENT_METHOD_KEYS) payments[method] = bucket(methods[method], PAYMENT_STATUS_KEYS);
  const result = {
    asOf: timestamp(source.as_of),
    totalWorkers: count(source.total_workers),
    verifiedWorkers: count(source.verified_workers),
    pendingWorkerVerifications: count(source.pending_worker_verifications),
    totalClients: count(source.total_clients),
    jobsByStatus: bucket(source.jobs_by_status, JOB_KEYS),
    bookingsByStatus: bucket(source.bookings_by_status, BOOKING_KEYS),
    completedBookings: count(source.completed_bookings),
    paymentsByMethodStatus: payments,
    reportsByStatus: bucket(source.reports_by_status, REPORT_KEYS),
    reportsNeedingAttention: count(source.reports_needing_attention),
  };
  sumBucket(result.jobsByStatus);
  sumBucket(result.bookingsByStatus);
  sumBucket(result.reportsByStatus);
  let paymentTotal = 0;
  for (const method of PAYMENT_METHOD_KEYS) paymentTotal += sumBucket(payments[method]);
  if (!Number.isSafeInteger(paymentTotal)) throw new InvalidResponse();
  return result;
}

export function idReviewAttention(summary) {
  if (!summary) return 'Count loading';
  const n = summary.pendingWorkerVerifications;
  return n === 0 ? 'No Workers waiting' : `${plural(n, 'Worker')} waiting for review`;
}

export function reportAttention(summary) {
  if (!summary) return 'Count loading';
  const n = summary.reportsNeedingAttention;
  return n === 0 ? 'Nothing needs attention' : `${plural(n, 'report')} need${n === 1 ? 's' : ''} attention`;
}

/* ------------------------------------------------------------------ *
 * Directories — get_admin_worker_directory / get_admin_client_directory
 * ------------------------------------------------------------------ */

export const DIRECTORY_PAGE_SIZE = 20;
// ADM-01 (owner 2026-11-06): the _v2 directory reads add strike_count to Worker rows and a status filter.
const DIR_WORKER_KEYS = ['user_id', 'full_name', 'is_active', 'created_at', 'has_profile', 'is_verified', 'availability_status', 'strike_count'];

/** Directory status filter values, sent as p_status. "Inactive" is banned or suspended at three strikes. */
export const DIRECTORY_STATUSES = [
  ['all', 'All'],
  ['active', 'Active'],
  ['inactive', 'Inactive'],
];

export function readDirectoryStatus(value) {
  return DIRECTORY_STATUSES.some(([key]) => key === value) ? value : 'all';
}

/** "1 of 3" for a Worker with a profile; null when there is no profile yet. */
export function strikeLabel(item) {
  return item.has_profile && Number.isSafeInteger(item.strike_count) ? `${item.strike_count} of 3` : null;
}
const DIR_CLIENT_KEYS = ['user_id', 'full_name', 'is_active', 'created_at'];

export function prepareDirectorySearch(value) {
  const search = value.trim();
  return { search, tooLong: [...search].length > 100 };
}

export function directoryEmptyMessage(page, kind, search, status = 'all') {
  if (page.total_count > 0) {
    return page.page > 1 ? 'No items on this page. Go to the previous page.' : 'No items on this page.';
  }
  const title = kind === 'worker' ? 'workers' : 'clients';
  const which = status === 'active' ? `active ${title}` : status === 'inactive' ? `inactive ${title}` : title;
  return search ? `No ${which} match that name.` : `No ${which} found.`;
}

export function parseDirectoryPage(data, kind) {
  if (!Array.isArray(data) || data.length !== 1) throw new InvalidResponse();
  const row = record(data[0]);
  const total = count(row.total_count);
  if (!sameKeys(row, ['total_count', 'page', 'page_size', 'items']) ||
      !Number.isSafeInteger(row.page) || row.page < 1 ||
      !Number.isSafeInteger(row.page_size) || row.page_size < 1 || row.page_size > 50 ||
      !Array.isArray(row.items) || row.items.length > row.page_size) {
    throw new InvalidResponse();
  }
  const keys = kind === 'worker' ? DIR_WORKER_KEYS : DIR_CLIENT_KEYS;
  for (const item of row.items) {
    if (!item || typeof item !== 'object' || Array.isArray(item) || !sameKeys(item, keys) ||
        typeof item.user_id !== 'string' || typeof item.full_name !== 'string' ||
        typeof item.is_active !== 'boolean' ||
        (item.created_at !== null && typeof item.created_at !== 'string') ||
        (kind === 'worker' && (typeof item.has_profile !== 'boolean' ||
          (item.is_verified !== null && typeof item.is_verified !== 'boolean') ||
          (item.availability_status !== null && typeof item.availability_status !== 'string') ||
          (item.strike_count !== null && (!Number.isSafeInteger(item.strike_count) || item.strike_count < 0)) ||
          (!item.has_profile && (item.is_verified !== null || item.availability_status !== null || item.strike_count !== null))))) {
      throw new InvalidResponse();
    }
  }
  return { ...row, total_count: total };
}

/* ------------------------------------------------------------------ *
 * User detail — get_admin_user_detail
 * ------------------------------------------------------------------ */

const DETAIL_COMMON = ['user_id', 'full_name', 'is_active', 'created_at'];
const DETAIL_WORKER = [...DETAIL_COMMON, 'has_profile', 'is_verified', 'availability_status', 'completed_bookings_count'];
const DETAIL_CLIENT = [...DETAIL_COMMON, 'posted_jobs_count'];

export function parseUserDetail(value, kind, targetUserId) {
  if (!isUuid(targetUserId)) throw new InvalidResponse('Invalid user detail target');
  if (value === null) return null;
  const row = record(value);
  if (!sameKeys(row, kind === 'worker' ? DETAIL_WORKER : DETAIL_CLIENT) ||
      !isUuid(row.user_id) || row.user_id.toLowerCase() !== targetUserId.toLowerCase() ||
      typeof row.full_name !== 'string' || typeof row.is_active !== 'boolean' ||
      (row.created_at !== null && typeof row.created_at !== 'string')) {
    throw new InvalidResponse();
  }
  if (kind === 'worker') {
    if (typeof row.has_profile !== 'boolean' ||
        (row.is_verified !== null && typeof row.is_verified !== 'boolean') ||
        (row.availability_status !== null && typeof row.availability_status !== 'string') ||
        (!row.has_profile && (row.is_verified !== null || row.availability_status !== null))) {
      throw new InvalidResponse();
    }
    return { ...row, completed_bookings_count: count(row.completed_bookings_count) };
  }
  return { ...row, posted_jobs_count: count(row.posted_jobs_count) };
}

export function accountStatus(isActive) {
  return isActive ? { label: 'Active', tone: 'positive' } : { label: 'Inactive', tone: 'danger' };
}

export function accountStatusExplanation(isActive) {
  return isActive
    ? 'This account can sign in and use SkillMatch.'
    : 'This account is inactive. Signing in shows the inactive-account screen instead of the app.';
}

/* ------------------------------------------------------------------ *
 * MOD-01 account moderation (ban / reinstate, no-show strikes)
 * ------------------------------------------------------------------ */

export const MAX_STRIKES = 3;
export const MODERATION_REASON_MAX = 500;
const MODERATION_READ = ['is_active', 'strike_count', 'last_action', 'last_reason', 'last_action_at'];
const MODERATION_WRITE = ['user_id', 'is_active', 'strike_count', 'changed'];

function strikes(value) {
  if (value === null) return null;
  if (!Number.isInteger(value) || value < 0 || value > MAX_STRIKES) throw new InvalidResponse();
  return value;
}

function onlyRow(data) {
  if (!Array.isArray(data) || data.length !== 1) throw new InvalidResponse();
  return record(data[0]);
}

export function parseModeration(data) {
  const row = onlyRow(data);
  const action = row.last_action;
  if (!sameKeys(row, MODERATION_READ) || typeof row.is_active !== 'boolean' ||
      (action !== null && action !== 'ban' && action !== 'reinstate') ||
      (row.last_reason !== null && typeof row.last_reason !== 'string') ||
      (row.last_action_at !== null && typeof row.last_action_at !== 'string') ||
      (action === null) !== (row.last_reason === null) || (action === null) !== (row.last_action_at === null)) {
    throw new InvalidResponse();
  }
  return { ...row, strike_count: strikes(row.strike_count) };
}

export function parseModerationResult(data, targetUserId) {
  const row = onlyRow(data);
  if (!sameKeys(row, MODERATION_WRITE) || !isUuid(row.user_id) ||
      row.user_id.toLowerCase() !== targetUserId.toLowerCase() ||
      typeof row.is_active !== 'boolean' || typeof row.changed !== 'boolean') {
    throw new InvalidResponse();
  }
  return { ...row, strike_count: strikes(row.strike_count) };
}

/** The trimmed reason, or null when it is empty or over the server limit. */
export function normaliseModerationReason(reason) {
  const trimmed = String(reason ?? '').trim();
  return trimmed.length > 0 && trimmed.length <= MODERATION_REASON_MAX ? trimmed : null;
}

export const strikeSummary = (count) => (count === null ? 'No Worker profile' : `${count} of ${MAX_STRIKES}`);

export const MODERATION_COPY = {
  reasonRequired: `Enter a reason of 1 to ${MODERATION_REASON_MAX} characters.`,
  unavailable: 'This account cannot be moderated.',
  failed: 'Unable to update the account. Please try again.',
  loadFailed: 'Unable to load moderation. Please try again.',
  unchanged: 'No change: the account was already in that state.',
  banned: 'Account banned. It stays suspended until an Administrator reinstates it.',
  reinstatedWorker: 'Account reinstated. No-show strikes were reset to 0.',
  reinstated: 'Account reinstated.',
};

/** Copy for a non-permission failure (permission is handled by the session guard). */
export function moderationActionCopy(error) {
  if (error?.code === 'SM409') return MODERATION_COPY.unavailable;
  if (error?.code === '22023') return MODERATION_COPY.reasonRequired;
  return MODERATION_COPY.failed;
}

/* ------------------------------------------------------------------ *
 * REG-01 account profile / Worker resume (get_admin_account_profile)
 * ------------------------------------------------------------------ */

export const EDUCATION_LABELS = {
  none: 'No formal schooling', elementary: 'Elementary', high_school: 'High school', senior_high: 'Senior high school',
  vocational: 'Vocational / TESDA', college_undergrad: 'Some college', college_graduate: 'College graduate',
  postgraduate: 'Postgraduate',
};
const PROFILE_COMMON = [
  'user_id', 'role', 'full_name', 'first_name', 'middle_name', 'last_name', 'name_suffix', 'email', 'phone',
  'address_street', 'address_barangay', 'address_city', 'address_province', 'client_account_type', 'business_name',
  'profile_completed_at',
];
const PROFILE_WORKER = [...PROFILE_COMMON, 'birth_date', 'education_level', 'school_name', 'work_history', 'resume_completed_at', 'skills'];
const PROFILE_NULLABLE_TEXT = ['first_name', 'middle_name', 'last_name', 'name_suffix', 'address_street', 'address_barangay',
  'address_city', 'address_province', 'business_name', 'profile_completed_at'];
const nullableText = (v) => v === null || typeof v === 'string';
const nullableInt = (v) => v === null || Number.isInteger(v);

export function parseAccountProfile(value, targetUserId) {
  const row = record(value);
  const keys = row.role === 'worker' ? PROFILE_WORKER : row.role === 'client' ? PROFILE_COMMON : null;
  if (!keys || !sameKeys(row, keys) || !isUuid(row.user_id) || row.user_id.toLowerCase() !== targetUserId.toLowerCase() ||
      typeof row.full_name !== 'string' || typeof row.email !== 'string' || typeof row.phone !== 'string' ||
      !PROFILE_NULLABLE_TEXT.every((k) => nullableText(row[k])) ||
      !(row.client_account_type === null || row.client_account_type === 'individual' || row.client_account_type === 'business')) {
    throw new InvalidResponse();
  }
  if (row.role === 'worker') {
    if (!nullableText(row.birth_date) || !(row.education_level === null || Object.hasOwn(EDUCATION_LABELS, row.education_level)) ||
        !nullableText(row.school_name) || !nullableText(row.resume_completed_at) ||
        !Array.isArray(row.work_history) || !Array.isArray(row.skills) ||
        !row.work_history.every((j) => j && typeof j.employer === 'string' && typeof j.role === 'string' &&
          Number.isInteger(j.start_year) && nullableInt(j.end_year)) ||
        !row.skills.every((s) => s && typeof s.name === 'string' && nullableText(s.proficiency) && nullableInt(s.years))) {
      throw new InvalidResponse();
    }
  }
  return row;
}

export function formatHomeAddress(p) {
  const parts = [p.address_street, p.address_barangay ? `Brgy. ${p.address_barangay}` : null, p.address_city, p.address_province].filter(Boolean);
  return parts.length ? parts.join(', ') : null;
}

/** Whole years on today's Manila date; null when the date is missing or malformed. */
export function ageOn(birthDate, today = new Date()) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(birthDate ?? '');
  if (!m) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const manila = new Date(today.getTime() + 8 * 3600 * 1000);
  const [ty, tm, td] = [manila.getUTCFullYear(), manila.getUTCMonth() + 1, manila.getUTCDate()];
  return ty - y - (tm < mo || (tm === mo && td < d) ? 1 : 0);
}

export function formatBirthDate(birthDate, today = new Date()) {
  if (!birthDate) return null;
  const [y, m, d] = birthDate.split('-').map(Number);
  const label = new Intl.DateTimeFormat('en-PH', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' })
    .format(new Date(Date.UTC(y, m - 1, d)));
  const age = ageOn(birthDate, today);
  return age === null ? label : `${label} (age ${age})`;
}

export const formatJobYears = (job) => `${job.start_year} – ${job.end_year ?? 'Present'}`;
/** Years of experience only: skill levels (Beginner / Intermediate / Expert) are not shown (owner, 2026-11-05). */
export function formatSkillExperience(skill) {
  if (skill.years === null || skill.years === undefined) return 'Not provided';
  return skill.years === 1 ? '1 year' : `${skill.years} years`;
}

export function workerVerificationStatus(worker) {
  if (!worker.has_profile) return { label: 'No profile', tone: 'neutral' };
  if (worker.is_verified === true) return { label: 'Verified', tone: 'positive' };
  if (worker.is_verified === false) return { label: 'Unverified', tone: 'warning' };
  return { label: 'Verification not set', tone: 'neutral' };
}

export function directoryRowStatus(kind, item) {
  if (!item.is_active) return accountStatus(false);
  return kind === 'worker' ? workerVerificationStatus(item) : accountStatus(true);
}

export function availabilityLabel(status) {
  if (!status) return 'Availability not set';
  const words = status.replace(/_/g, ' ').trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/* ------------------------------------------------------------------ *
 * Worker identity review
 * ------------------------------------------------------------------ */

export const ID_TYPE_LABELS = {
  national_id: 'PhilSys National ID / ePhilID',
  drivers_license: "LTO Driver's License",
  passport: 'Philippine Passport',
  umid: 'UMID',
  postal_id: 'Postal ID',
};

export const IDENTITY_COPY = {
  reviewLoadFailed: 'Unable to load the ID review queue. Please try again.',
  reviewForbidden: "You don't have permission to review identity documents.",
  reviewUnavailable: 'This identity submission is no longer pending review.',
  approveFailed: "We couldn't approve this ID. Please try again.",
  rejectFailed: "We couldn't reject this ID. Please try again.",
  rejectReasonRequired: 'Please enter a rejection reason (1–500 characters).',
  approvedNotice: 'Your identity document was approved.',
  rejectedNotice: 'Identity submission rejected.',
};

export const identityTypeLabel = (value) => ID_TYPE_LABELS[value] ?? 'Valid ID';

function toPendingReview(row) {
  if (typeof row !== 'object' || row === null) return null;
  const idType = Object.hasOwn(ID_TYPE_LABELS, row.id_type) ? row.id_type : null;
  if (typeof row.user_id !== 'string' || typeof row.document_id !== 'string' ||
      typeof row.full_name !== 'string' || idType === null) {
    return null;
  }
  return {
    userId: row.user_id,
    documentId: row.document_id,
    fullName: row.full_name,
    phone: text(row.phone),
    barangay: text(row.barangay),
    city: text(row.city),
    idType,
    submittedAt: text(row.submitted_at),
    skills: Array.isArray(row.skills) ? row.skills.filter((s) => typeof s === 'string' && s.trim() !== '') : [],
  };
}

export function parsePendingReviews(data) {
  return (Array.isArray(data) ? data : []).map(toPendingReview).filter((row) => row !== null);
}

/** get_worker_identity_for_review projects no skills; native shows none on this screen either. */
export function parseIdentityForReview(data) {
  const rows = Array.isArray(data) ? data : data ? [data] : [];
  const review = toPendingReview(rows[0] ?? null);
  if (review === null) return null;
  const storagePath = text(rows[0].storage_path);
  if (storagePath === null) return null;
  return { ...review, skills: [], storagePath };
}

export function validateRejectionReason(reason) {
  const trimmed = reason.trim();
  return trimmed.length < 1 || trimmed.length > 500 ? IDENTITY_COPY.rejectReasonRequired : null;
}

/** Copy for a non-permission failure (permission is handled by the session guard). */
export function identityActionCopy(error, action) {
  if (error?.code === 'SM409') return IDENTITY_COPY.reviewUnavailable;
  if (error?.code === '22023' && action === 'reject') return IDENTITY_COPY.rejectReasonRequired;
  return action === 'reject' ? IDENTITY_COPY.rejectFailed : IDENTITY_COPY.approveFailed;
}

/* ------------------------------------------------------------------ *
 * Reports
 * ------------------------------------------------------------------ */

export const REPORT_DESCRIPTION_MAX = 2000;

const CATEGORY_LABEL = {
  behavior: 'Behavior', 'no-show': 'No-show', harassment: 'Harassment', safety: 'Safety',
  payment: 'Payment', incorrect_details: 'Incorrect details', fraud: 'Fraud', app_issue: 'App issue', other: 'Other',
};

export const formatReportCategory = (category) => CATEGORY_LABEL[category] ?? 'Report';
export const formatReportStatus = (status) => REPORT_LABELS[status] ?? 'Report';
export const reportContextLabel = (bookingId) => (bookingId === null ? 'App issue' : 'Booking report');
export const isOpenReport = (status) => status === 'submitted' || status === 'under_review';

export function reportStatusTone(status) {
  if (status === 'submitted') return 'warning';
  if (status === 'under_review') return 'info';
  if (status === 'resolved') return 'positive';
  return 'neutral';
}

export function allowedReviewStatuses(status) {
  if (status === 'submitted') return ['under_review', 'resolved', 'dismissed'];
  if (status === 'under_review') return ['resolved', 'dismissed'];
  return [];
}

export function validateAdminResponse(targetStatus, raw) {
  const response = raw.trim();
  if (response.length > REPORT_DESCRIPTION_MAX) return { ok: false, reason: 'too_long' };
  if (targetStatus === 'under_review') return { ok: true, response: response === '' ? null : response };
  if (response === '') return { ok: false, reason: 'empty' };
  return { ok: true, response };
}

export const REPORT_COPY = {
  adminLoadFailed: 'Unable to load reports. Please try again.',
  adminEmpty: 'No reports have been submitted.',
  adminDetailLoadFailed: 'Unable to load this report. Please try again.',
  unavailable: 'This report is unavailable.',
  noAdminResponse: 'No response yet',
  responseLabel: 'Admin response',
  responsePlaceholder: 'Response to the reporter',
  responseRequired: 'Enter a response between 1 and 2000 characters.',
  responseTooLong: 'Admin response must be between 1 and 2000 characters.',
  markUnderReview: 'Mark under review',
  resolve: 'Resolve',
  dismiss: 'Dismiss',
  reviewing: 'Saving…',
  reviewSaved: 'Review saved.',
  emailFailed: 'Review saved. Email could not be sent.',
  emailSent: 'Outcome email sent.',
  retryEmail: 'Send or retry outcome email',
  emailing: 'Sending email…',
  strikeAction: 'Resolve and apply strike',
  striking: 'Applying strike…',
  strikeConfirmTitle: 'Apply reviewed no-show strike?',
  strikeConfirmBody: 'This resolves the report and adds one no-show strike to the reported Worker.',
  strikeSuspendBody: 'This resolves the report, adds the third no-show strike, and suspends the Worker account.',
  strikeSaved: 'No-show strike applied.',
  reviewInvalid: 'Check the review status and response and try again.',
  reviewConflict: 'This report is not available for review.',
  reviewGeneric: "We couldn't save this review. Please try again.",
  refreshFailed: 'That worked, but the report could not be refreshed. Reload to see the latest state.',
  evidenceTitle: 'Historical booking messages',
  evidenceLoading: 'Loading messages…',
  evidenceEmpty: 'No messages were recorded for this booking.',
};

export const REVIEW_LABEL = {
  under_review: REPORT_COPY.markUnderReview,
  resolved: REPORT_COPY.resolve,
  dismissed: REPORT_COPY.dismiss,
};

export function reviewActionCopy(error) {
  if (error?.code === '22023') return REPORT_COPY.reviewInvalid;
  if (error?.code === 'SM409') return REPORT_COPY.reviewConflict;
  return REPORT_COPY.reviewGeneric;
}

export function parseReportList(data) {
  return (Array.isArray(data) ? data : []).map((r) => {
    if (typeof r !== 'object' || r === null) return null;
    const row = {
      report_id: text(r.report_id), reporter_id: text(r.reporter_id), reporter_full_name: text(r.reporter_full_name),
      reported_user_id: text(r.reported_user_id), reported_full_name: text(r.reported_full_name),
      booking_id: text(r.booking_id), category: text(r.category), status: text(r.status), created_at: text(r.created_at),
    };
    return row.report_id && row.reporter_id && row.reporter_full_name && row.category && row.status ? row : null;
  }).filter((row) => row !== null);
}

export function parseReportDetail(data) {
  const r = Array.isArray(data) && data.length > 0 ? data[0] : null;
  if (typeof r !== 'object' || r === null) return null;
  const row = {
    report_id: text(r.report_id), reporter_id: text(r.reporter_id), reporter_full_name: text(r.reporter_full_name),
    reported_user_id: text(r.reported_user_id), reported_full_name: text(r.reported_full_name),
    booking_id: text(r.booking_id), job_title: text(r.job_title), category: text(r.category),
    description: typeof r.description === 'string' ? r.description : null, status: text(r.status),
    admin_response: text(r.admin_response), reviewed_at: text(r.reviewed_at), created_at: text(r.created_at),
  };
  return row.report_id && row.reporter_id && row.reporter_full_name && row.category &&
    row.description !== null && row.status ? row : null;
}

export function parseDisciplineState(data) {
  const raw = Array.isArray(data) ? data[0] : undefined;
  if (raw === undefined || raw === null || typeof raw !== 'object' ||
      typeof raw.eligible !== 'boolean' || typeof raw.would_suspend !== 'boolean' ||
      !(raw.current_strike_count === null || (Number.isInteger(raw.current_strike_count) &&
        raw.current_strike_count >= 0 && raw.current_strike_count <= 3))) {
    throw new InvalidResponse('this report discipline state is unavailable');
  }
  return { eligible: raw.eligible, currentStrikeCount: raw.current_strike_count, wouldSuspend: raw.would_suspend };
}

export function parseBookingMessages(data) {
  return (Array.isArray(data) ? data : []).map((r) => {
    if (typeof r !== 'object' || r === null) return null;
    const id = text(r.message_id);
    const role = text(r.sender_role);
    if (id === null || typeof r.content !== 'string' || (role !== 'worker' && role !== 'client')) return null;
    return { message_id: id, sender_role: role, content: r.content, created_at: text(r.created_at) };
  }).filter((row) => row !== null);
}

/* ------------------------------------------------------------------ *
 * Notifications
 * ------------------------------------------------------------------ */

const NOTIFICATION_LABEL = {
  booking_request: 'Booking request',
  booking_confirmed: 'Booking confirmed',
  booking_cancelled: 'Booking cancelled',
  booking_completed: 'Booking completed',
  no_show_strike: 'No-show recorded',
  account_suspended: 'Account suspended',
  account_reinstated: 'Account reinstated',
  payment_received: 'Payment received',
  worker_verified: 'Profile verified',
  report_submitted: 'Report submitted',
  // NTF-01 (owner 2026-11-06): Administrator alerts.
  identity_submitted: 'ID submitted for review',
  worker_registered: 'New Worker registered',
  client_registered: 'New Client registered',
};

export const NOTIFICATION_COPY = {
  loadGeneric: "We couldn't load your notifications. Please refresh and try again.",
  empty: 'You have no notifications yet.',
  loading: 'Loading your notifications…',
  intro: 'Updates about your bookings and account.',
  markGeneric: "We couldn't mark that notification as read. Please try again.",
  markRefreshFailed:
    'That notification was marked as read, but the list could not be refreshed. Refresh to see the latest state.',
  unread: 'Unread',
};

export const formatNotificationLabel = (type) => NOTIFICATION_LABEL[type] ?? 'Notification';
export const isUnread = (isRead) => isRead !== true;

export function parseNotifications(data) {
  return (Array.isArray(data) ? data : []).map((r) => {
    if (typeof r !== 'object' || r === null) return null;
    if (typeof r.id !== 'string' || typeof r.type !== 'string' || typeof r.message !== 'string') return null;
    return {
      id: r.id, type: r.type, message: r.message,
      is_read: typeof r.is_read === 'boolean' ? r.is_read : null,
      created_at: text(r.created_at),
    };
  }).filter((row) => row !== null);
}

/**
 * Admin activation: each alert opens its list (rows carry no trusted record id). NTF-01 adds ID
 * reviews and the two directories.
 */
const NOTIFICATION_DESTINATIONS = {
  report_submitted: ['/reports', 'Reports'],
  identity_submitted: ['/id-reviews', 'ID reviews'],
  worker_registered: ['/workers', 'Workers'],
  client_registered: ['/clients', 'Clients'],
};
export const notificationHref = (type) => NOTIFICATION_DESTINATIONS[type]?.[0] ?? null;
export const notificationDestination = (type) => NOTIFICATION_DESTINATIONS[type]?.[1] ?? null;

/* ---------------- Settings (owner 2026-11-06) ---------------- */

/** Same minimum as the app's password screens. */
export const PASSWORD_MIN_LENGTH = 6;

export const SETTINGS_COPY = {
  notificationsIntro:
    'New reports and ID reviews appear in Notifications here. Alerts on your phone come from the SkillMatch mobile app.',
  passwordIntro: 'This changes the password you use to sign in here and in the SkillMatch app.',
  passwordTooShort: `Password must be at least ${PASSWORD_MIN_LENGTH} characters.`,
  passwordMismatch: 'The two passwords do not match.',
  passwordSaved: 'Your password was changed.',
  passwordSame: 'Choose a password different from your current one.',
  passwordWeak: 'Choose a stronger password.',
  passwordReauth: 'For your security, sign out, sign in again, then change your password.',
  passwordGeneric: "We couldn't change your password. Please try again.",
};

/** The message to show, or null when the new password can be sent. */
export function checkNewPassword(password, confirm) {
  if (typeof password !== 'string' || password.length < PASSWORD_MIN_LENGTH) return SETTINGS_COPY.passwordTooShort;
  if (password !== confirm) return SETTINGS_COPY.passwordMismatch;
  return null;
}

/** Plain wording for Supabase Auth password errors; raw backend text is never shown. */
export function passwordErrorCopy(code) {
  if (code === 'same_password') return SETTINGS_COPY.passwordSame;
  if (code === 'weak_password') return SETTINGS_COPY.passwordWeak;
  if (code === 'reauthentication_needed' || code === 'reauthentication_not_valid') return SETTINGS_COPY.passwordReauth;
  return SETTINGS_COPY.passwordGeneric;
}
