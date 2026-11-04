/**
 * Thin wrappers over the existing administrator-checked RPCs, the private
 * `worker-identity` bucket and the `report-outcome-email` Edge Function.
 * Names and arguments mirror the native Admin (skillmatch-mobile-rc/src/lib).
 * Every failure throws ApiError with `.code` (SQLSTATE / PostgREST / Auth code)
 * and `.status` (HTTP), so the session guard can classify it. Raw backend text
 * is never shown to the user.
 *
 * Deliberately absent: verify_worker (approval goes only through
 * approve_worker_identity), any direct table write, any role change.
 * Account state changes only through MOD-01 admin_set_account_banned.
 */
import { supabase } from './supabase.js';
import {
  DIRECTORY_PAGE_SIZE,
  parseAnalytics,
  parseBookingMessages,
  parseDirectoryPage,
  parseDisciplineState,
  parseIdentityForReview,
  parseAccountProfile,
  parseModeration,
  parseModerationResult,
  parseNotifications,
  parsePendingReviews,
  parseReportDetail,
  parseReportList,
  parseUserDetail,
  normaliseModerationReason,
  validateRejectionReason,
} from './domain.js';

export const ID_IMAGE_BUCKET = 'worker-identity';
export const ID_IMAGE_URL_SECONDS = 120;

export class ApiError extends Error {
  constructor(message, { code = null, status = null, name } = {}) {
    super(message || 'The request failed.');
    this.name = name || 'ApiError';
    this.code = code;
    this.status = status;
  }
}

function toApiError(error, status) {
  const httpStatus = typeof status === 'number' && status > 0
    ? status
    : typeof error?.status === 'number' ? error.status
      : typeof error?.statusCode === 'string' && /^\d+$/.test(error.statusCode) ? Number(error.statusCode) : null;
  return new ApiError(error?.message, {
    code: typeof error?.code === 'string' ? error.code : null,
    status: httpStatus,
    name: error?.name,
  });
}

async function rpc(name, args) {
  const { data, error, status } = await supabase.rpc(name, args);
  if (error) throw toApiError(error, status);
  return data;
}

/* ---------------- Session / role ---------------- */

/** Server-validated user id (GET /auth/v1/user), not just the cached token. */
export async function getUserId() {
  const { data, error } = await supabase.auth.getUser();
  if (error) throw toApiError(error);
  return data?.user?.id ?? null;
}

/** Same own-row read as the native AccountProvider (users, eq id, maybeSingle). */
export async function fetchOwnRoleRow(userId) {
  const { data, error, status } = await supabase
    .from('users')
    .select('role,is_active')
    .eq('id', userId)
    .maybeSingle();
  return { data, error: error ? toApiError(error, status) : null };
}

/* ---------------- Analytics, directories, user detail ---------------- */

export async function loadAnalytics() {
  return parseAnalytics(await rpc('get_admin_analytics_summary'));
}

export async function loadDirectory(kind, search, page) {
  const name = kind === 'worker' ? 'get_admin_worker_directory' : 'get_admin_client_directory';
  const data = await rpc(name, { p_search: search, p_page: page, p_page_size: DIRECTORY_PAGE_SIZE });
  return parseDirectoryPage(data, kind);
}

export async function loadUserDetail(kind, userId) {
  const data = await rpc('get_admin_user_detail', { p_user_id: userId, p_expected_role: kind });
  return parseUserDetail(data, kind, userId);
}

/* ---------------- REG-01 account profile / Worker resume ---------------- */

export async function loadAccountProfile(userId) {
  return parseAccountProfile(await rpc('get_admin_account_profile', { p_user_id: userId }), userId);
}

/* ---------------- MOD-01 account moderation ---------------- */

export async function loadModeration(userId) {
  return parseModeration(await rpc('get_admin_account_moderation', { p_user_id: userId }));
}

/** Ban (banned = true) or reinstate. A blank or over-long reason never reaches the server. */
export async function setAccountBanned(userId, banned, reason) {
  const trimmed = normaliseModerationReason(reason);
  if (trimmed === null) throw new ApiError('invalid reason', { code: '22023' });
  const data = await rpc('admin_set_account_banned', { p_user_id: userId, p_banned: banned, p_reason: trimmed });
  return parseModerationResult(data, userId);
}

/* ---------------- Identity review ---------------- */

export async function listPendingIdReviews() {
  return parsePendingReviews(await rpc('list_workers_pending_id_review'));
}

export async function getIdentityForReview(workerUserId) {
  return parseIdentityForReview(await rpc('get_worker_identity_for_review', { p_worker_user_id: workerUserId }));
}

/**
 * A short-lived (120 s) signed URL, created only when the detail view opens.
 * It is held in component state and never persisted. It limits link reuse;
 * it does not stop an authorized administrator from saving the image.
 */
export async function createIdImageUrl(storagePath) {
  const path = storagePath.trim();
  if (path === '') return null;
  const { data, error } = await supabase.storage.from(ID_IMAGE_BUCKET).createSignedUrl(path, ID_IMAGE_URL_SECONDS);
  if (error) throw toApiError(error);
  return typeof data?.signedUrl === 'string' && data.signedUrl !== '' ? data.signedUrl : null;
}

export async function approveIdentity(workerUserId) {
  await rpc('approve_worker_identity', { p_worker_user_id: workerUserId });
}

export async function rejectIdentity(workerUserId, reason) {
  const invalid = validateRejectionReason(reason);
  if (invalid !== null) throw new ApiError(invalid, { code: '22023' });
  await rpc('reject_worker_identity', { p_worker_user_id: workerUserId, p_reason: reason.trim() });
}

/* ---------------- Reports ---------------- */

export async function listReports() {
  return parseReportList(await rpc('list_reports'));
}

export async function getReport(reportId) {
  const detail = parseReportDetail(await rpc('get_report', { p_report_id: reportId }));
  if (detail === null) throw new ApiError('this report is not available', { code: 'SM409' });
  return detail;
}

export async function getDisciplineState(reportId) {
  return parseDisciplineState(await rpc('get_report_discipline_state', { p_report_id: reportId }));
}

export async function getBookingMessages(reportId) {
  return parseBookingMessages(await rpc('get_report_booking_messages', { p_report_id: reportId }));
}

export async function reviewReport(reportId, status, adminResponse) {
  await rpc('review_report', { p_report_id: reportId, p_status: status, p_admin_response: adminResponse });
}

export async function resolveWithStrike(reportId, adminResponse) {
  await rpc('resolve_no_show_report_with_strike', { p_report_id: reportId, p_admin_response: adminResponse });
}

/** Same call and success test as native: delivered only when the function says so. */
export async function sendOutcomeEmail(reportId) {
  try {
    const result = await supabase.functions.invoke('report-outcome-email', { body: { report_id: reportId } });
    return result.error === null && result.data?.delivered === true;
  } catch {
    return false;
  }
}

/* ---------------- Notifications ---------------- */

/** Recipient-only RLS scopes the rows; no user id is sent. */
export async function listNotifications() {
  const { data, error, status } = await supabase
    .from('notifications')
    .select('id, type, message, is_read, created_at')
    .order('created_at', { ascending: false, nullsFirst: false });
  if (error) throw toApiError(error, status);
  return parseNotifications(data);
}

export async function markNotificationRead(notificationId) {
  await rpc('mark_my_notification_read', { p_notification_id: notificationId });
}
