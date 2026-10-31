import { createClient } from '@supabase/supabase-js';

import { checkPublicConfig } from './config.js';

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
const check = checkPublicConfig(url, key);

/** Non-null when the build was not given a valid URL + publishable key. */
export const configError = check.ok ? null : check.error;

/**
 * Publishable key only. The session lives in sessionStorage: it is scoped to
 * this tab and is gone when the tab closes. No URL session detection, because
 * this console has no magic-link, OAuth or password-reset flow.
 */
export const supabase = check.ok
  ? createClient(url.trim(), key.trim(), {
      auth: {
        storage: window.sessionStorage,
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: false,
      },
    })
  : null;

/** Fallback when a local sign-out cannot reach the server: drop this tab's stored session. */
export function clearLocalSession() {
  try {
    for (const storageKey of Object.keys(window.sessionStorage)) {
      if (storageKey.startsWith('sb-')) window.sessionStorage.removeItem(storageKey);
    }
  } catch {
    // Storage unavailable: nothing persisted to clear.
  }
}
