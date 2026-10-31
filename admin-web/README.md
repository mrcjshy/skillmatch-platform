# SkillMatch Administrator web console (`admin-web/`)

A separate browser console for **existing, active SkillMatch administrators**
(D-009 amendment RF-A). It does what the native Admin does (analytics, Worker
and Client directories, user details, ID reviews, reports, notifications) and
nothing more. It is its own package, build and origin. The public landing site
never imports it.

## Security boundary

- The console holds only the Supabase project URL and the **publishable** key.
  The build refuses to run without them, and refuses a secret (`sb_secret_…`)
  or any non-`anon` JWT key (`src/config.js`, `vite.config.js`).
- It acts only through the existing administrator-checked RPCs, the private
  `worker-identity` bucket (signed URLs), and the `report-outcome-email` Edge
  Function. Every rule is enforced by the backend. The UI gate is a second layer.
- No signup, no password reset and no role assignment. Sign-in is email and
  password for existing accounts only.
- The session is kept in `sessionStorage` (this tab only). The caller's own
  `users` row is re-read after sign-in, on boot and on window focus. Anything
  other than `role = 'administrator'` with `is_active = true` signs out locally.
- A denied action (42501 / 403) re-checks the role. The console signs out only
  if that re-check shows the account is no longer an active administrator.
- "Sign out" is this browser only (`scope: 'local'`). "Sign out on all devices"
  (`scope: 'global'`) is separate, needs confirmation, and also signs out the
  mobile app. After 15 minutes without activity the console signs out locally.
- ID images use 120-second signed URLs, created when the review opens and never
  stored. They limit link reuse. They do not stop an administrator from saving
  or capturing the image.
- No analytics, no third-party scripts, no external fonts.
  `vercel.json` sets a strict CSP and `noindex`, `no-store`, `DENY` framing.

## Environment

Copy `.env.example` to `.env.local` (git-ignored) and fill in both values:

```
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

**CSP and the project origin.** `vercel.json` is static and cannot read build
environment variables, so its header allows `https://*.supabase.co` for
`connect-src` and `img-src`. The build adds a `<meta>` CSP that names the exact
`VITE_SUPABASE_URL` origin. Browsers enforce both, so the effective policy is
that one project. `frame-ancestors` only works as a header, so it stays in
`vercel.json`. A local stack (`http://127.0.0.1:54321`) works with `npm run dev`.
`npm run preview` applies the `vercel.json` headers, which allow only
`*.supabase.co`.

The `report-outcome-email` function answers browser CORS only for origins in its
`ADMIN_WEB_ORIGINS` secret. Add the console's exact origin there.

## Local commands (run inside `admin-web/`)

| Command | What it does |
| --- | --- |
| `npm ci` | Install the exact versions in `package-lock.json` |
| `npm run dev` | Dev server on http://localhost:5174 |
| `npm run build` | Production build into `admin-web/dist` (needs both env values) |
| `npm run preview` | Serve `dist` on http://localhost:4174 with the `vercel.json` headers |
| `npm test` | Unit tests: `node --test "src/**/*.test.js"` |
| `npm run test:e2e` | Playwright **mocked-backend** UI tests (see below) |

The e2e suite intercepts every Supabase request in the browser and answers from
fixtures. It is UI evidence, not backend proof. It builds into `.e2e-dist` with a
fake project URL and uses the installed Google Chrome by default. To use the
bundled browser instead, run `npx playwright install chromium` and set
`PLAYWRIGHT_CHANNEL=chromium`.

## Vercel project settings

Use a separate Vercel project for the console, not the landing site's project.

| Setting | Value |
| --- | --- |
| Root Directory | `admin-web` (Project Settings; `vercel.json` cannot set this) |
| Framework preset | Vite (also declared in `vercel.json`) |
| Install Command | `npm ci` (from `vercel.json`) |
| Build Command | `npm run build` (from `vercel.json`) |
| Output Directory | `dist` (from `vercel.json`) |
| Environment variables | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` only |

`vercel.json` also rewrites every path to `/index.html`, because this is a
single-page app, and applies the security headers to all routes. Never add a
service-role key, secret key or provider secret to this project.
