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
const DIR_WORKER_KEYS = ['user_id', 'full_name', 'is_active', 'created_at', 'has_profile', 'is_verified', 'availability_status'];
const DIR_CLIENT_KEYS = ['user_id', 'full_name', 'is_active', 'created_at'];

export function prepareDirectorySearch(value) {
  const search = value.trim();
  return { search, tooLong: [...search].length > 100 };
}

export function directoryEmptyMessage(page, kind, search) {
  if (page.total_count > 0) {
    return page.page > 1 ? 'No items on this page. Go to the previous page.' : 'No items on this page.';
  }
  const title = kind === 'worker' ? 'workers' : 'clients';
  return search ? `No ${title} match that name.` : `No ${title} found.`;
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
          (!item.has_profile && (item.is_verified !== null || item.availability_status !== null))))) {
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
  payment_received: 'Payment received',
  worker_verified: 'Profile verified',
  report_submitted: 'Report submitted',
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

/** Admin activation: a report notification opens the report list (rows carry no trusted report id). */
export const notificationHref = (type) => (type === 'report_submitted' ? '/reports' : null);
