// Unit tests for the pure session/permission contract (D-009 amendment RF-A).
// Run with: npm test   (node --test src/)
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ADMIN_ONLY_MESSAGE,
  IDLE_TIMEOUT_MS,
  PERMISSION_MESSAGE,
  afterDenied,
  classifyError,
  createIdleTimer,
  handleSessionInvalid,
  isActiveAdministrator,
  recheckRole,
  signOut,
  safeRedirectPath,
} from './session.js';

/* ------------------------------------------------------------------ *
 * classifyError
 * ------------------------------------------------------------------ */

test('classifyError: PostgREST 42501 is denied', () => {
  assert.equal(classifyError({ code: '42501', status: 403, message: 'permission denied' }), 'denied');
  assert.equal(classifyError({ code: '42501' }), 'denied');
});

test('classifyError: HTTP 403 without a code is denied', () => {
  assert.equal(classifyError({ status: 403, message: 'Forbidden' }), 'denied');
});

test('classifyError: HTTP 401 is session_invalid', () => {
  assert.equal(classifyError({ status: 401, message: 'Unauthorized' }), 'session_invalid');
});

test('classifyError: expired or invalid JWT is session_invalid', () => {
  assert.equal(classifyError({ code: 'PGRST303', message: 'JWT expired' }), 'session_invalid');
  assert.equal(classifyError({ code: 'PGRST301', message: 'JWSError JWSInvalidSignature' }), 'session_invalid');
  assert.equal(classifyError({ message: 'JWT expired' }), 'session_invalid');
  assert.equal(classifyError({ message: 'invalid JWT: unable to parse or verify signature' }), 'session_invalid');
  // GoTrue answers a bad bearer with 403 + bad_jwt: still a session problem, not a role denial.
  assert.equal(classifyError({ name: 'AuthApiError', status: 403, code: 'bad_jwt' }), 'session_invalid');
  assert.equal(classifyError({ name: 'AuthApiError', status: 403, code: 'session_not_found' }), 'session_invalid');
});

test('classifyError: refresh failure is session_invalid', () => {
  assert.equal(classifyError({ name: 'AuthApiError', status: 400, code: 'refresh_token_not_found' }), 'session_invalid');
  assert.equal(classifyError({ name: 'AuthApiError', status: 400, code: 'refresh_token_already_used' }), 'session_invalid');
  assert.equal(classifyError({ name: 'AuthSessionMissingError', message: 'Auth session missing!' }), 'session_invalid');
});

test('classifyError: anything else is other', () => {
  assert.equal(classifyError({ code: '22023', status: 400, message: 'invalid input' }), 'other');
  assert.equal(classifyError({ code: 'SM409', status: 409 }), 'other');
  assert.equal(classifyError({ status: 500 }), 'other');
  assert.equal(classifyError(new TypeError('Failed to fetch')), 'other');
  assert.equal(classifyError(null), 'other');
  assert.equal(classifyError(undefined), 'other');
  assert.equal(classifyError('42501'), 'other');
});

/* ------------------------------------------------------------------ *
 * Role check
 * ------------------------------------------------------------------ */

test('isActiveAdministrator accepts only an active administrator row', () => {
  assert.equal(isActiveAdministrator({ role: 'administrator', is_active: true }), true);
  assert.equal(isActiveAdministrator({ role: 'worker', is_active: true }), false);
  assert.equal(isActiveAdministrator({ role: 'client', is_active: true }), false);
  assert.equal(isActiveAdministrator({ role: 'administrator', is_active: false }), false);
  assert.equal(isActiveAdministrator({ role: 'administrator', is_active: null }), false);
  assert.equal(isActiveAdministrator({ role: 'administrator', is_active: 'true' }), false);
  assert.equal(isActiveAdministrator({ role: 'Administrator', is_active: true }), false);
  assert.equal(isActiveAdministrator(null), false);
  assert.equal(isActiveAdministrator(undefined), false);
  assert.equal(isActiveAdministrator([]), false);
});

function roleDeps(row, { userId = 'u1', rowError = null, userError = null } = {}) {
  const calls = [];
  return {
    calls,
    getUserId: async () => {
      calls.push('getUserId');
      if (userError) throw userError;
      return userId;
    },
    fetchOwnRow: async (id) => {
      calls.push(`fetchOwnRow:${id}`);
      return { data: row, error: rowError };
    },
  };
}

test('recheckRole: active administrator passes', async () => {
  const deps = roleDeps({ role: 'administrator', is_active: true });
  assert.equal(await recheckRole(deps), 'admin');
  assert.deepEqual(deps.calls, ['getUserId', 'fetchOwnRow:u1']);
});

test('recheckRole rejects worker, client, inactive admin and a missing row', async () => {
  assert.equal(await recheckRole(roleDeps({ role: 'worker', is_active: true })), 'not_admin');
  assert.equal(await recheckRole(roleDeps({ role: 'client', is_active: true })), 'not_admin');
  assert.equal(await recheckRole(roleDeps({ role: 'administrator', is_active: false })), 'not_admin');
  assert.equal(await recheckRole(roleDeps(null)), 'not_admin');
});

test('recheckRole: no user or an invalid session is session_invalid', async () => {
  assert.equal(await recheckRole(roleDeps(null, { userId: null })), 'session_invalid');
  assert.equal(
    await recheckRole(roleDeps(null, { userError: { name: 'AuthApiError', status: 403, code: 'bad_jwt' } })),
    'session_invalid'
  );
  assert.equal(
    await recheckRole(roleDeps(null, { rowError: { code: 'PGRST303', status: 401, message: 'JWT expired' } })),
    'session_invalid'
  );
});

test('recheckRole: a transient failure is unknown, never a verdict', async () => {
  assert.equal(await recheckRole(roleDeps(null, { rowError: { status: 500, message: 'boom' } })), 'unknown');
  assert.equal(await recheckRole(roleDeps(null, { userError: new TypeError('Failed to fetch') })), 'unknown');
});

/* ------------------------------------------------------------------ *
 * signOut scope
 * ------------------------------------------------------------------ */

function fakeAuth(result = { error: null }) {
  const calls = [];
  return {
    calls,
    signOut: async (options) => {
      calls.push(options);
      return result;
    },
  };
}

test('signOut defaults to scope local', async () => {
  const auth = fakeAuth();
  await signOut(auth);
  await signOut(auth, {});
  await signOut(auth, { allDevices: 'yes' });
  assert.deepEqual(auth.calls, [{ scope: 'local' }, { scope: 'local' }, { scope: 'local' }]);
});

test('signOut uses scope global only for the explicit all-devices action', async () => {
  const auth = fakeAuth();
  await signOut(auth, { allDevices: true });
  assert.deepEqual(auth.calls, [{ scope: 'global' }]);
});

test('signOut local clears the stored session if the server call fails', async () => {
  const auth = fakeAuth({ error: { message: 'network' } });
  let cleared = 0;
  const result = await signOut(auth, { clearLocalSession: () => { cleared += 1; } });
  assert.equal(cleared, 1);
  assert.equal(result.error, null);
});

test('signOut global reports a failure instead of pretending', async () => {
  const auth = fakeAuth({ error: { message: 'network' } });
  let cleared = 0;
  const result = await signOut(auth, { allDevices: true, clearLocalSession: () => { cleared += 1; } });
  assert.equal(cleared, 0);
  assert.deepEqual(result.error, { message: 'network' });
});

/* ------------------------------------------------------------------ *
 * afterDenied / session_invalid
 * ------------------------------------------------------------------ */

function signOutSpy() {
  const calls = [];
  const fn = async (options) => {
    calls.push(options);
    return { error: null };
  };
  fn.calls = calls;
  return fn;
}

test('afterDenied keeps an active administrator signed in', async () => {
  const doSignOut = signOutSpy();
  let rechecks = 0;
  const result = await afterDenied({
    recheckRole: async () => { rechecks += 1; return 'admin'; },
    signOut: doSignOut,
  });
  assert.equal(rechecks, 1);
  assert.deepEqual(doSignOut.calls, []);
  assert.deepEqual(result, { outcome: 'kept', message: PERMISSION_MESSAGE });
});

test('afterDenied keeps the session when the re-check cannot decide', async () => {
  const doSignOut = signOutSpy();
  const unknown = await afterDenied({ recheckRole: async () => 'unknown', signOut: doSignOut });
  const thrown = await afterDenied({ recheckRole: async () => { throw new Error('x'); }, signOut: doSignOut });
  assert.deepEqual(doSignOut.calls, []);
  assert.equal(unknown.outcome, 'kept');
  assert.equal(thrown.outcome, 'kept');
  assert.equal(thrown.message, PERMISSION_MESSAGE);
});

test('afterDenied signs out locally when the re-check shows a lost role or inactive account', async () => {
  for (const row of [
    { role: 'worker', is_active: true },
    { role: 'client', is_active: true },
    { role: 'administrator', is_active: false },
    null,
  ]) {
    const doSignOut = signOutSpy();
    const result = await afterDenied({
      recheckRole: () => recheckRole(roleDeps(row)),
      signOut: doSignOut,
    });
    assert.deepEqual(doSignOut.calls, [{ scope: 'local' }], JSON.stringify(row));
    assert.deepEqual(result, { outcome: 'signed_out', message: ADMIN_ONLY_MESSAGE });
  }
});

test('afterDenied treats an invalid session as session_invalid', async () => {
  const doSignOut = signOutSpy();
  const result = await afterDenied({ recheckRole: async () => 'session_invalid', signOut: doSignOut });
  assert.deepEqual(doSignOut.calls, [{ scope: 'local' }]);
  assert.equal(result.outcome, 'session_invalid');
});

test('session_invalid signs out locally, then redirects to sign-in', async () => {
  const order = [];
  await handleSessionInvalid({
    signOut: async (options) => { order.push(['signOut', options]); return { error: null }; },
    redirectToSignIn: () => order.push(['redirect']),
  });
  assert.deepEqual(order, [['signOut', { scope: 'local' }], ['redirect']]);
});

test('session_invalid still redirects when sign-out throws', async () => {
  const order = [];
  await handleSessionInvalid({
    signOut: async () => { throw new Error('offline'); },
    redirectToSignIn: () => order.push('redirect'),
  });
  assert.deepEqual(order, ['redirect']);
});

/* ------------------------------------------------------------------ *
 * Idle timer
 * ------------------------------------------------------------------ */

function fakeClock() {
  let time = 0;
  let nextId = 1;
  const timers = new Map();
  return {
    now: () => time,
    setTimer: (fn, delay) => {
      const id = nextId++;
      timers.set(id, { fn, at: time + delay });
      return id;
    },
    clearTimer: (id) => { timers.delete(id); },
    advance(ms) {
      const end = time + ms;
      for (;;) {
        let due = null;
        for (const [id, t] of timers) if (t.at <= end && (due === null || t.at < due[1].at)) due = [id, t];
        if (due === null) break;
        timers.delete(due[0]);
        time = due[1].at;
        due[1].fn();
      }
      time = end;
    },
    pending: () => timers.size,
  };
}

test('idle timeout is 15 minutes', () => {
  assert.equal(IDLE_TIMEOUT_MS, 15 * 60 * 1000);
});

test('idle timer fires once after the timeout', () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = createIdleTimer({ timeoutMs: IDLE_TIMEOUT_MS, onIdle: () => { fired += 1; }, ...clock });
  timer.start();
  clock.advance(IDLE_TIMEOUT_MS - 1);
  assert.equal(fired, 0);
  clock.advance(1);
  assert.equal(fired, 1);
  clock.advance(IDLE_TIMEOUT_MS * 3);
  timer.check();
  timer.activity();
  clock.advance(IDLE_TIMEOUT_MS * 3);
  assert.equal(fired, 1);
  assert.equal(clock.pending(), 0);
});

test('idle timer resets on activity', () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = createIdleTimer({ timeoutMs: IDLE_TIMEOUT_MS, onIdle: () => { fired += 1; }, ...clock });
  timer.start();
  clock.advance(10 * 60 * 1000);
  timer.activity();
  clock.advance(10 * 60 * 1000); // 20 min since start, 10 since activity
  assert.equal(fired, 0);
  clock.advance(5 * 60 * 1000 - 1);
  assert.equal(fired, 0);
  clock.advance(1);
  assert.equal(fired, 1);
});

test('idle timer check() fires immediately when a throttled background tab returns late', () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = createIdleTimer({ timeoutMs: 1000, onIdle: () => { fired += 1; }, ...clock });
  timer.start();
  // Simulate a throttled tab: time passes but the scheduled callback has not run.
  clock.clearTimer(1);
  clock.advance(5000);
  assert.equal(fired, 0);
  timer.check();
  assert.equal(fired, 1);
});

test('idle timer stop() prevents firing', () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = createIdleTimer({ timeoutMs: 1000, onIdle: () => { fired += 1; }, ...clock });
  timer.start();
  timer.stop();
  clock.advance(10_000);
  timer.check();
  assert.equal(fired, 0);
  assert.equal(clock.pending(), 0);
});

/* ------------------------------------------------------------------ *
 * Post-sign-in redirect target
 * ------------------------------------------------------------------ */

test('safeRedirectPath keeps only in-app paths', () => {
  assert.equal(safeRedirectPath('/reports'), '/reports');
  assert.equal(safeRedirectPath('/reports/abc?x=1'), '/reports/abc?x=1');
  assert.equal(safeRedirectPath('//evil.example'), '/');
  assert.equal(safeRedirectPath('/\\evil.example'), '/');
  assert.equal(safeRedirectPath('https://evil.example'), '/');
  assert.equal(safeRedirectPath('/sign-in'), '/');
  assert.equal(safeRedirectPath(undefined), '/');
  assert.equal(safeRedirectPath(42), '/');
});
