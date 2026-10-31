/**
 * Validates the only two values this console is allowed to hold: the Supabase
 * project URL and its publishable key. Used at build time (vite.config.js, to
 * fail the build and to pin the CSP origin) and at runtime (src/supabase.js).
 *
 * A secret key (`sb_secret_…`) or any legacy JWT key whose role is not `anon`
 * is refused, so a privileged key can never be shipped by mistake.
 */

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

function decodeJwtRole(key) {
  const parts = key.split('.');
  if (parts.length !== 3) return undefined;
  try {
    const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
    const payload = JSON.parse(atob(padded));
    return payload && typeof payload === 'object' ? payload.role : null;
  } catch {
    return null;
  }
}

/**
 * @returns {{ ok: true, origin: string } | { ok: false, error: string }}
 */
export function checkPublicConfig(url, key) {
  if (typeof url !== 'string' || url.trim() === '') {
    return { ok: false, error: 'VITE_SUPABASE_URL is not set.' };
  }
  let parsed;
  try {
    parsed = new URL(url.trim());
  } catch {
    return { ok: false, error: 'VITE_SUPABASE_URL is not a valid URL.' };
  }
  const local = LOCAL_HOSTS.has(parsed.hostname);
  if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && local)) {
    return { ok: false, error: 'VITE_SUPABASE_URL must use https (http only for a local stack).' };
  }
  if (parsed.username || parsed.password || (parsed.pathname !== '/' && parsed.pathname !== '') ||
      parsed.search || parsed.hash) {
    return { ok: false, error: 'VITE_SUPABASE_URL must be the bare project URL.' };
  }

  if (typeof key !== 'string' || key.trim() === '') {
    return { ok: false, error: 'VITE_SUPABASE_PUBLISHABLE_KEY is not set.' };
  }
  const trimmed = key.trim();
  if (trimmed.startsWith('sb_secret_')) {
    return { ok: false, error: 'A secret key was supplied. Use the publishable key only.' };
  }
  const role = decodeJwtRole(trimmed);
  if (role !== undefined && role !== 'anon') {
    return { ok: false, error: 'Only the publishable (anon) key is allowed.' };
  }
  return { ok: true, origin: parsed.origin };
}
