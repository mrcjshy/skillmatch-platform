/**
 * Session and permission contract for the Administrator web console
 * (D-009 amendment RF-A). Pure: no Supabase import, no DOM, no timers of its
 * own. Every side effect is injected so `node --test` can prove the rules.
 *
 * The rules:
 * - A denied action (42501 / HTTP 403) re-checks the role. The console signs
 *   out ONLY when the re-check proves the account is no longer an active
 *   administrator. Otherwise the session stays and a permission message shows.
 * - An invalid session (401, expired/invalid JWT, failed refresh) signs out
 *   locally and returns to sign-in.
 * - Ordinary sign-out is browser-local. Global sign-out is a separate,
 *   explicit action.
 * - 15 minutes without activity signs out locally.
 */

export const ADMIN_ONLY_MESSAGE = 'This console is for SkillMatch administrators only.';
export const PERMISSION_MESSAGE = "You don't have permission for that action.";
export const SESSION_ENDED_MESSAGE = 'Your session has ended. Please sign in again.';
export const IDLE_MESSAGE = 'You were signed out after 15 minutes of inactivity.';
export const IDLE_TIMEOUT_MS = 15 * 60 * 1000;

/** GoTrue error codes that mean the session itself is unusable. */
const AUTH_SESSION_CODES = new Set([
  'bad_jwt',
  'no_authorization',
  'session_not_found',
  'session_expired',
  'refresh_token_not_found',
  'refresh_token_already_used',
  'user_not_found',
]);

/** PostgREST JWT error codes (PGRST301 decode failure, PGRST302 missing, PGRST303 expired/claims). */
const POSTGREST_JWT_CODES = new Set(['PGRST301', 'PGRST302', 'PGRST303']);

const JWT_MESSAGE = /\bjwt\b.*\b(expired|invalid|malformed)\b|\binvalid\b.*\bjwt\b|jws(error|invalid)/i;

/**
 * @returns {'denied' | 'session_invalid' | 'other'}
 */
export function classifyError(err) {
  if (err === null || typeof err !== 'object') return 'other';
  const code = typeof err.code === 'string' ? err.code : null;
  const status = typeof err.status === 'number' ? err.status : null;
  const name = typeof err.name === 'string' ? err.name : '';
  const message = typeof err.message === 'string' ? err.message : '';

  // Session problems first: GoTrue answers a bad bearer with 403 + bad_jwt,
  // which must not be mistaken for a role denial.
  if (code !== null && AUTH_SESSION_CODES.has(code)) return 'session_invalid';
  if (name === 'AuthSessionMissingError' || name === 'AuthInvalidTokenResponseError') return 'session_invalid';
  if (code !== null && POSTGREST_JWT_CODES.has(code)) return 'session_invalid';

  if (code === '42501' || status === 403) return 'denied';
  if (status === 401) return 'session_invalid';
  if (JWT_MESSAGE.test(message)) return 'session_invalid';
  return 'other';
}

/** The caller's own `users` row must say administrator AND active, exactly. */
export function isActiveAdministrator(row) {
  return (
    row !== null &&
    typeof row === 'object' &&
    !Array.isArray(row) &&
    row.role === 'administrator' &&
    row.is_active === true
  );
}

/**
 * Re-reads the caller's own role.
 * @param {{ getUserId: () => Promise<string|null>, fetchOwnRow: (id: string) => Promise<{data: unknown, error: unknown}> }} deps
 * @returns {Promise<'admin' | 'not_admin' | 'session_invalid' | 'unknown'>}
 */
export async function recheckRole({ getUserId, fetchOwnRow }) {
  let userId;
  try {
    userId = await getUserId();
  } catch (error) {
    return classifyError(error) === 'session_invalid' ? 'session_invalid' : 'unknown';
  }
  if (typeof userId !== 'string' || userId === '') return 'session_invalid';

  let result;
  try {
    result = await fetchOwnRow(userId);
  } catch (error) {
    return classifyError(error) === 'session_invalid' ? 'session_invalid' : 'unknown';
  }
  if (result?.error) {
    return classifyError(result.error) === 'session_invalid' ? 'session_invalid' : 'unknown';
  }
  // A missing row (RLS hides it, or it was removed) is a definite "not an admin".
  return isActiveAdministrator(result?.data ?? null) ? 'admin' : 'not_admin';
}

/**
 * Sign out. Browser-local unless `allDevices === true` (strictly).
 * A failed local sign-out still clears this browser's stored session.
 */
export async function signOut(auth, { allDevices = false, clearLocalSession } = {}) {
  const scope = allDevices === true ? 'global' : 'local';
  let result;
  try {
    result = await auth.signOut({ scope });
  } catch (error) {
    result = { error };
  }
  const error = result?.error ?? null;
  if (error && scope === 'local') {
    clearLocalSession?.();
    return { error: null };
  }
  return { error };
}

/**
 * After a denied (42501 / 403) action.
 * @returns {Promise<{ outcome: 'kept' | 'signed_out' | 'session_invalid', message: string }>}
 */
export async function afterDenied({ recheckRole: recheck, signOut: doSignOut }) {
  let verdict;
  try {
    verdict = await recheck();
  } catch {
    verdict = 'unknown';
  }
  if (verdict === 'not_admin') {
    await safely(() => doSignOut({ scope: 'local' }));
    return { outcome: 'signed_out', message: ADMIN_ONLY_MESSAGE };
  }
  if (verdict === 'session_invalid') {
    await safely(() => doSignOut({ scope: 'local' }));
    return { outcome: 'session_invalid', message: SESSION_ENDED_MESSAGE };
  }
  return { outcome: 'kept', message: PERMISSION_MESSAGE };
}

/** Invalid session: local sign-out (best effort), then sign-in. */
export async function handleSessionInvalid({ signOut: doSignOut, redirectToSignIn }) {
  await safely(() => doSignOut({ scope: 'local' }));
  redirectToSignIn();
}

async function safely(fn) {
  try {
    await fn();
  } catch {
    // Best effort: the caller still proceeds to the signed-out state.
  }
}

/**
 * Idle timer with an injectable clock. Activity only records a timestamp
 * (cheap for mousemove bursts); the scheduled check re-arms for the remaining
 * time. `check()` lets focus/visibility handlers catch a throttled tab.
 */
export function createIdleTimer({
  timeoutMs = IDLE_TIMEOUT_MS,
  onIdle,
  now = Date.now,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
}) {
  let handle = null;
  let last = now();
  let running = false;
  let fired = false;

  function clear() {
    if (handle !== null) clearTimer(handle);
    handle = null;
  }

  function schedule(delay) {
    clear();
    handle = setTimer(check, Math.max(0, delay));
  }

  function check() {
    if (!running || fired) return;
    const elapsed = now() - last;
    if (elapsed >= timeoutMs) {
      fired = true;
      running = false;
      clear();
      onIdle();
      return;
    }
    schedule(timeoutMs - elapsed);
  }

  return {
    start() {
      running = true;
      fired = false;
      last = now();
      schedule(timeoutMs);
    },
    activity() {
      if (!running || fired) return;
      last = now();
    },
    check,
    stop() {
      running = false;
      clear();
    },
    lastActivity: () => last,
  };
}

/** Only same-app paths survive as a post-sign-in destination. */
export function safeRedirectPath(value) {
  if (typeof value !== 'string') return '/';
  if (!value.startsWith('/') || value.startsWith('//') || value.startsWith('/\\')) return '/';
  if (value === '/sign-in' || value.startsWith('/sign-in?')) return '/';
  return value;
}
