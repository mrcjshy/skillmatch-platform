import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { fetchOwnRoleRow, getUserId } from './api.js';
import { AuthContext } from './auth-context.js';
import {
  ADMIN_ONLY_MESSAGE,
  IDLE_MESSAGE,
  IDLE_TIMEOUT_MS,
  PERMISSION_MESSAGE,
  SESSION_ENDED_MESSAGE,
  afterDenied,
  classifyError,
  createIdleTimer,
  handleSessionInvalid,
  recheckRole,
  signOut as signOutWithScope,
} from './session.js';
import { clearLocalSession, configError, supabase } from './supabase.js';

/**
 * status:
 *  'config_error' build has no valid URL/publishable key
 *  'loading'      reading the stored session
 *  'checking'     signed in; role check in flight (console not shown yet)
 *  'admin'        active administrator confirmed
 *  'unverified'   signed in, but the role check could not complete (network)
 *  'signed_out'
 */

const LAST_ACTIVITY_KEY = 'skillmatch-admin:last-activity';
const ACTIVITY_EVENTS = ['pointerdown', 'keydown', 'wheel', 'touchstart', 'mousemove'];

function readLastActivity() {
  try {
    const value = Number(window.sessionStorage.getItem(LAST_ACTIVITY_KEY));
    return Number.isFinite(value) && value > 0 ? value : null;
  } catch {
    return null;
  }
}

function writeLastActivity(value) {
  try {
    if (value === null) window.sessionStorage.removeItem(LAST_ACTIVITY_KEY);
    else window.sessionStorage.setItem(LAST_ACTIVITY_KEY, String(value));
  } catch {
    // Storage unavailable: idle detection still runs in memory.
  }
}

const recheck = () => recheckRole({ getUserId, fetchOwnRow: fetchOwnRoleRow });

/** The contract's signOut({ scope }) bound to this client; 'global' only when asked for explicitly. */
const scopedSignOut = (options) =>
  signOutWithScope(supabase.auth, { allDevices: options?.scope === 'global', clearLocalSession });

export function AuthProvider({ children }) {
  const [status, setStatus] = useState(configError ? 'config_error' : 'loading');
  const [email, setEmail] = useState(null);
  const [notice, setNotice] = useState(null);
  const statusRef = useRef(status);
  const verifying = useRef(null);

  const update = useCallback((next) => {
    statusRef.current = next;
    setStatus(next);
  }, []);

  /** The signed-out state, with the reason shown on the sign-in page. */
  const finishSignedOut = useCallback((message) => {
    setNotice(message ?? null);
    writeLastActivity(null);
    update('signed_out');
  }, [update]);

  /** Local sign-out (this browser), then the signed-out state with a reason. */
  const endSession = useCallback(async (message) => {
    await scopedSignOut({ scope: 'local' });
    finishSignedOut(message);
  }, [finishSignedOut]);

  /** Re-read the caller's own role. `reason` is 'boot' | 'sign_in' | 'focus' | 'retry'. */
  const verify = useCallback((reason) => {
    if (verifying.current) return verifying.current;
    const run = (async () => {
      if (reason !== 'focus') update('checking');
      const verdict = await recheck();
      if (verdict === 'admin') {
        update('admin');
      } else if (verdict === 'not_admin') {
        await endSession(ADMIN_ONLY_MESSAGE);
      } else if (verdict === 'session_invalid') {
        await endSession(SESSION_ENDED_MESSAGE);
      } else if (!(reason === 'focus' && statusRef.current === 'admin')) {
        // Could not decide (offline). Never sign out on that; never show the console either,
        // except that an already-confirmed session survives a failed focus re-check.
        update('unverified');
      }
    })().finally(() => {
      verifying.current = null;
    });
    verifying.current = run;
    return run;
  }, [endSession, update]);

  // Boot: stored session → idle staleness → role check.
  useEffect(() => {
    if (!supabase) return undefined;
    let cancelled = false;
    const { data: listener } = supabase.auth.onAuthStateChange((event, session) => {
      // State only; never call Supabase from inside this callback.
      setEmail(session?.user?.email ?? null);
      if (event === 'SIGNED_OUT') update('signed_out');
    });
    (async () => {
      const { data } = await supabase.auth.getSession();
      if (cancelled) return;
      if (!data.session) {
        update('signed_out');
        return;
      }
      setEmail(data.session.user?.email ?? null);
      const last = readLastActivity();
      if (last !== null && Date.now() - last >= IDLE_TIMEOUT_MS) {
        await endSession(IDLE_MESSAGE);
        return;
      }
      await verify('boot');
    })();
    return () => {
      cancelled = true;
      listener.subscription.unsubscribe();
    };
  }, [endSession, update, verify]);

  // Re-check on window focus / tab return while the console is open.
  useEffect(() => {
    if (status !== 'admin') return undefined;
    const onFocus = () => { void verify('focus'); };
    const onVisible = () => { if (document.visibilityState === 'visible') onFocus(); };
    window.addEventListener('focus', onFocus);
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      window.removeEventListener('focus', onFocus);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [status, verify]);

  // 15-minute idle sign-out (local scope).
  useEffect(() => {
    if (status !== 'admin') return undefined;
    const timer = createIdleTimer({ timeoutMs: IDLE_TIMEOUT_MS, onIdle: () => { void endSession(IDLE_MESSAGE); } });
    timer.start();
    writeLastActivity(timer.lastActivity());
    const onActivity = () => timer.activity();
    const persist = () => writeLastActivity(timer.lastActivity());
    const onVisibility = () => {
      if (document.visibilityState === 'visible') timer.check();
      else persist();
    };
    for (const name of ACTIVITY_EVENTS) window.addEventListener(name, onActivity, { passive: true });
    window.addEventListener('focus', timer.check);
    window.addEventListener('pagehide', persist);
    document.addEventListener('visibilitychange', onVisibility);
    const saver = window.setInterval(persist, 30_000);
    return () => {
      timer.stop();
      window.clearInterval(saver);
      for (const name of ACTIVITY_EVENTS) window.removeEventListener(name, onActivity);
      window.removeEventListener('focus', timer.check);
      window.removeEventListener('pagehide', persist);
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [status, endSession]);

  const signIn = useCallback(async (emailInput, password) => {
    setNotice(null);
    update('checking');
    const { error } = await supabase.auth.signInWithPassword({ email: emailInput, password });
    if (error) {
      update('signed_out');
      return error.code === 'invalid_credentials' || error.status === 400
        ? 'Email or password is incorrect.'
        : 'Sign-in failed. Please try again.';
    }
    writeLastActivity(Date.now());
    await verify('sign_in');
    return null;
  }, [update, verify]);

  /** "Sign out": this browser only. */
  const signOutHere = useCallback(() => endSession(null), [endSession]);

  /** "Sign out on all devices": global scope, explicit and confirmed by the caller. */
  const signOutEverywhere = useCallback(async () => {
    const { error } = await scopedSignOut({ scope: 'global' });
    if (error) return 'Could not sign out on all devices. Please try again.';
    finishSignedOut(null);
    return null;
  }, [finishSignedOut]);

  /**
   * Central failure handling for every page.
   * Returns { kind: 'denied', message } when the session was kept,
   * { kind: 'ended' } when it was ended, or { kind: 'other' } for the page to word.
   */
  const handleError = useCallback(async (error) => {
    const kind = classifyError(error);
    if (kind === 'session_invalid') {
      await handleSessionInvalid({
        signOut: scopedSignOut,
        redirectToSignIn: () => finishSignedOut(SESSION_ENDED_MESSAGE),
      });
      return { kind: 'ended' };
    }
    if (kind === 'denied') {
      // Re-check first; sign out only if the account is provably no longer an active admin.
      const result = await afterDenied({ recheckRole: recheck, signOut: scopedSignOut });
      if (result.outcome === 'kept') return { kind: 'denied', message: PERMISSION_MESSAGE };
      finishSignedOut(result.message);
      return { kind: 'ended' };
    }
    return { kind: 'other' };
  }, [finishSignedOut]);

  const value = useMemo(() => ({
    status, email, notice, signIn, signOutHere, signOutEverywhere, handleError, retryVerify: () => verify('retry'),
  }), [status, email, notice, signIn, signOutHere, signOutEverywhere, handleError, verify]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
