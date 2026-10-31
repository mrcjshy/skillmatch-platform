import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

import { checkPublicConfig } from './src/config.js';

const root = fileURLToPath(new URL('.', import.meta.url));

/** The exact headers Vercel serves (vercel.json), reused by `vite preview`. */
function vercelHeaders() {
  const config = JSON.parse(readFileSync(new URL('./vercel.json', import.meta.url), 'utf8'));
  const all = config.headers.find((entry) => entry.source === '/(.*)');
  return Object.fromEntries(all.headers.map(({ key, value }) => [key, value]));
}

/**
 * Build-only guard and CSP pin.
 *
 * vercel.json is static and cannot read build env, so its header CSP allows
 * `https://*.supabase.co`. At build time this plugin (1) refuses to build
 * without a valid URL + publishable key, and refuses a secret key, and (2)
 * injects a <meta> CSP naming the EXACT project origin. Browsers enforce both
 * policies, so the effective connect-src/img-src is the one project origin.
 * (frame-ancestors is header-only, so it stays in vercel.json.)
 */
function adminBuildGuard(env) {
  return {
    name: 'skillmatch-admin-build-guard',
    apply: 'build',
    configResolved() {
      const result = checkPublicConfig(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY);
      if (!result.ok) throw new Error(`[admin-web] ${result.error} See admin-web/README.md.`);
    },
    transformIndexHtml() {
      const { origin } = checkPublicConfig(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY);
      const csp = [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self'",
        `img-src 'self' data: blob: ${origin}`,
        `connect-src 'self' ${origin}`,
        "font-src 'self'",
        "object-src 'none'",
        "frame-src 'none'",
        "base-uri 'none'",
        "form-action 'self'",
      ].join('; ');
      return [{ tag: 'meta', attrs: { 'http-equiv': 'Content-Security-Policy', content: csp }, injectTo: 'head-prepend' }];
    },
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, root, 'VITE_');
  return {
    root,
    envPrefix: 'VITE_',
    plugins: [react(), adminBuildGuard(env)],
    build: { outDir: 'dist', emptyOutDir: true, sourcemap: false },
    server: { port: 5174, strictPort: true },
    preview: { port: 4174, strictPort: true, headers: vercelHeaders() },
  };
});
