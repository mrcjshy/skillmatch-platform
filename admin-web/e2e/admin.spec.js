/**
 * ============================================================================
 * MOCKED-BACKEND UI EVIDENCE — NOT BACKEND PROOF
 * ============================================================================
 * No local Supabase stack is available (Docker is not installed), so every
 * request to the fake project origin is intercepted with page.route and
 * answered from the fixtures below. These tests prove what the BROWSER APP
 * does: routing, the role gate, confirmation dialogs, which endpoint and
 * scope it calls, and how it reacts to a 42501. They prove NOTHING about RLS,
 * RPC authorization, Storage policy or Edge Function behaviour on a real
 * project. Requests to any other origin are aborted and fail the test.
 * ============================================================================
 */
import { expect, test } from '@playwright/test';

const SUPABASE = 'https://admin-e2e.supabase.co';
const ADMIN_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const WORKER_ACCOUNT_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const PENDING_WORKER_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const REPORT_ID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const PASSWORD = 'correct horse battery staple';

const ACCOUNTS = {
  'admin@e2e.test': { id: ADMIN_ID, role: 'administrator', is_active: true },
  'worker@e2e.test': { id: WORKER_ACCOUNT_ID, role: 'worker', is_active: true },
};

// 1x1 transparent PNG.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  'base64'
);

const b64url = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
const tokenFor = (id) =>
  `${b64url({ alg: 'HS256', typ: 'JWT' })}.${b64url({ sub: id, role: 'authenticated', aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 })}.mock-signature`;
const idFromToken = (header) => {
  const token = (header ?? '').replace(/^Bearer /, '');
  try {
    return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).sub;
  } catch {
    return null;
  }
};
const userJson = (email) => ({
  id: ACCOUNTS[email].id, aud: 'authenticated', role: 'authenticated', email,
  app_metadata: { provider: 'email' }, user_metadata: {}, created_at: '2026-01-01T00:00:00Z',
});

const bucket = (keys, n = 1) => Object.fromEntries(keys.map((k) => [k, n]));
const PAY = bucket(['pending', 'paid', 'refunded', 'unset']);
const ANALYTICS = [{
  as_of: '2026-10-14T02:00:00Z',
  total_workers: 12, verified_workers: 9, pending_worker_verifications: 1, total_clients: 7,
  jobs_by_status: bucket(['open', 'matched', 'completed', 'cancelled', 'unset']),
  bookings_by_status: bucket(['pending', 'confirmed', 'completed', 'cancelled', 'no_show']),
  completed_bookings: 1,
  payments_by_method_status: { gcash: PAY, maya: PAY, qrph: PAY, cod: PAY, unset: PAY },
  reports_by_status: bucket(['submitted', 'under_review', 'resolved', 'dismissed']),
  reports_needing_attention: 2,
}];
const PENDING = {
  user_id: PENDING_WORKER_ID, document_id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', full_name: 'Maria Santos',
  phone: '+639171234567', barangay: 'Sto. Rosario', city: 'Santa Ana', id_type: 'passport',
  submitted_at: '2026-10-13T08:00:00Z',
};
const STORAGE_PATH = '11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.jpg';

function reportRow(status) {
  return {
    report_id: REPORT_ID, reporter_id: ADMIN_ID, reporter_full_name: 'Carlo Reyes',
    reported_user_id: PENDING_WORKER_ID, reported_full_name: 'Maria Santos', booking_id: null,
    job_title: null, category: 'other', description: 'The app froze on checkout.', status,
    admin_response: status === 'submitted' ? null : 'Thanks, fixed.', reviewed_at: null,
    created_at: '2026-10-12T05:00:00Z',
  };
}

/**
 * Installs the fake backend on a page. Returns the mutable fixture state and
 * every request seen, so tests can assert exactly what the app sent.
 */
async function mockBackend(page, overrides = {}) {
  const state = {
    roles: Object.fromEntries(Object.values(ACCOUNTS).map((a) => [a.id, { role: a.role, is_active: a.is_active }])),
    approve: { status: 200, body: [{ user_id: PENDING_WORKER_ID, document_id: PENDING.document_id, is_verified: true, verified_by: ADMIN_ID }] },
    reportStatus: 'submitted',
    // MOD-01: the moderated Worker (PENDING_WORKER_ID) starts active with two strikes.
    moderation: { is_active: true, strike_count: 2, last_action: null, last_reason: null, last_action_at: null },
    // Settings: the next PUT /auth/v1/user answers with this Auth error code (null = success).
    passwordError: null,
    // NTF-01: the Admin's unread count and notification rows.
    unread: 0,
    notifications: [],
    ...overrides,
  };
  const seen = { requests: [], unexpected: [], foreign: [], cspViolations: [], sockets: [] };

  // NTF-01: the live channel. No server is attached, so nothing leaves the test; the URL is recorded.
  await page.routeWebSocket(/\/realtime\/v1\/websocket/, (ws) => { seen.sockets.push(ws.url()); });

  page.on('console', (message) => {
    if (/Content Security Policy|Refused to/i.test(message.text())) seen.cspViolations.push(message.text());
  });

  // Anything that is neither the app nor the fake project is a third-party call: block and record it.
  await page.route('**/*', (route) => {
    const url = route.request().url();
    if (url.startsWith('http://localhost:4175/')) return route.continue();
    seen.foreign.push(url);
    return route.abort();
  });

  await page.route(`${SUPABASE}/**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const method = request.method();
    const cors = {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': (await request.headerValue('access-control-request-headers')) ?? '*',
      'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      'access-control-expose-headers': '*',
    };
    if (method === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });

    let body = null;
    try { body = request.postDataJSON(); } catch { body = request.postData(); }
    const entry = { method, path: url.pathname, search: url.search, body };
    seen.requests.push(entry);
    const json = (status, payload) =>
      route.fulfill({ status, headers: { ...cors, 'content-type': 'application/json' }, body: JSON.stringify(payload) });
    const caller = idFromToken(await request.headerValue('authorization'));

    // ---- Auth ----
    if (url.pathname === '/auth/v1/token' && url.searchParams.get('grant_type') === 'password') {
      const account = ACCOUNTS[body?.email];
      if (!account || body?.password !== PASSWORD) {
        return json(400, { code: 'invalid_credentials', error_code: 'invalid_credentials', msg: 'Invalid login credentials' });
      }
      return json(200, {
        access_token: tokenFor(account.id), token_type: 'bearer', expires_in: 3600,
        expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: `refresh-${account.id}`,
        user: userJson(body.email),
      });
    }
    if (url.pathname === '/auth/v1/user' && method === 'GET') {
      const email = Object.keys(ACCOUNTS).find((e) => ACCOUNTS[e].id === caller);
      return email ? json(200, userJson(email)) : json(403, { code: 'bad_jwt', msg: 'invalid JWT' });
    }
    if (url.pathname === '/auth/v1/logout') return route.fulfill({ status: 204, headers: cors });
    if (url.pathname === '/auth/v1/user' && method === 'PUT') {
      const email = Object.keys(ACCOUNTS).find((e) => ACCOUNTS[e].id === caller);
      if (!email) return json(403, { code: 'bad_jwt', msg: 'invalid JWT' });
      if (state.passwordError) {
        const code = state.passwordError;
        state.passwordError = null;
        return json(422, { code, error_code: code, msg: 'raw backend text that must not be shown' });
      }
      return json(200, userJson(email));
    }

    // ---- NTF-01 notifications: unread count (HEAD) and the list ----
    if (url.pathname === '/rest/v1/notifications' && method === 'HEAD') {
      return route.fulfill({ status: 200, headers: { ...cors, 'content-range': `*/${state.unread}` } });
    }
    if (url.pathname === '/rest/v1/notifications' && method === 'GET') return json(200, state.notifications);

    // ---- Own role row ----
    if (url.pathname === '/rest/v1/users' && method === 'GET') {
      const id = (url.searchParams.get('id') ?? '').replace(/^eq\./, '');
      const row = id === caller ? state.roles[id] : undefined;
      return json(200, row ? [row] : []);
    }

    // ---- RPCs ----
    const rpc = url.pathname.startsWith('/rest/v1/rpc/') ? url.pathname.slice('/rest/v1/rpc/'.length) : null;
    if (rpc === 'get_admin_analytics_summary') return json(200, ANALYTICS);
    if (rpc === 'get_admin_worker_directory_v2') {
      // ADM-01: two Workers, one active with 1 strike and one suspended with 3; filtered by p_status.
      const workers = [
        { user_id: WORKER_ACCOUNT_ID, full_name: 'Ana Active', is_active: true, created_at: null, has_profile: true, is_verified: true, availability_status: 'available', strike_count: 1 },
        { user_id: PENDING_WORKER_ID, full_name: 'Sol Suspended', is_active: false, created_at: null, has_profile: true, is_verified: true, availability_status: 'busy', strike_count: 3 },
      ].filter((w) => body.p_status === 'all' || (body.p_status === 'active') === w.is_active);
      return json(200, [{ total_count: workers.length, page: body.p_page, page_size: body.p_page_size, items: workers }]);
    }
    if (rpc === 'list_workers_pending_id_review') return json(200, [{ ...PENDING, skills: ['Plumbing', 'Carpentry'] }]);
    if (rpc === 'get_worker_identity_for_review') return json(200, [state.identities?.[body.p_worker_user_id] ?? { ...PENDING, storage_path: STORAGE_PATH }]);
    if (rpc === 'approve_worker_identity') return json(state.approve.status, state.approve.body);
    if (rpc === 'list_reports') return json(200, [reportRow(state.reportStatus)]);
    if (rpc === 'get_report') return json(200, [state.reports?.[body.p_report_id] ?? reportRow(state.reportStatus)]);
    if (rpc === 'get_report_discipline_state') return json(200, [{ eligible: false, current_strike_count: null, would_suspend: false }]);
    if (rpc === 'get_admin_user_detail') {
      return json(200, {
        user_id: body.p_user_id, full_name: 'Maria Santos', is_active: state.moderation.is_active,
        created_at: '2026-09-01T00:00:00Z', has_profile: true, is_verified: true,
        availability_status: 'available', completed_bookings_count: 4,
      });
    }
    if (rpc === 'get_admin_account_moderation') return json(200, [state.moderation]);
    if (rpc === 'get_admin_account_profile') {
      return json(200, {
        user_id: body.p_user_id, role: 'worker', full_name: 'Maria Santos', first_name: 'Maria', middle_name: null,
        last_name: 'Santos', name_suffix: null, email: 'maria@e2e.test', phone: '+639171234567',
        address_street: '12 M. Almeda St.', address_barangay: 'San Roque', address_city: 'Pateros', address_province: 'Metro Manila',
        client_account_type: null, business_name: null, profile_completed_at: '2026-11-03T00:00:00Z',
        birth_date: '1990-05-21', education_level: 'vocational', school_name: 'TESDA Pateros', resume_completed_at: '2026-11-03T00:00:00Z',
        work_history: [{ employer: 'ABC Builders', role: 'Carpenter', start_year: 2018, end_year: null }],
        skills: [{ name: 'Plumbing', proficiency: 'expert', years: 6 }],
      });
    }
    if (rpc === 'admin_set_account_banned') {
      const banned = body.p_banned === true;
      const changed = state.moderation.is_active === banned;
      if (changed) {
        state.moderation = {
          is_active: !banned,
          strike_count: banned ? state.moderation.strike_count : 0,
          last_action: banned ? 'ban' : 'reinstate', last_reason: body.p_reason, last_action_at: '2026-11-03T12:00:00Z',
        };
      }
      return json(200, [{ user_id: body.p_user_id, is_active: state.moderation.is_active, strike_count: state.moderation.strike_count, changed }]);
    }
    if (rpc === 'review_report') {
      state.reportStatus = body.p_status;
      return json(200, [{ report_id: REPORT_ID, status: body.p_status }]);
    }

    // ---- Storage: signed URL, then the image bytes ----
    if (url.pathname === `/storage/v1/object/sign/worker-identity/${STORAGE_PATH}` && method === 'POST') {
      return json(200, { signedURL: `/object/sign/worker-identity/${STORAGE_PATH}?token=mock-signed-token` });
    }
    if (url.pathname === `/storage/v1/object/sign/worker-identity/${STORAGE_PATH}` && method === 'GET') {
      return route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'image/png' }, body: PNG });
    }

    // ---- Edge Function ----
    if (url.pathname === '/functions/v1/report-outcome-email' && method === 'POST') return json(200, { delivered: true });

    seen.unexpected.push(`${method} ${url.pathname}${url.search}`);
    return json(404, { code: 'MOCK404', message: 'No fixture for this request' });
  });

  return { state, seen };
}

const rpcCalls = (seen, name) => seen.requests.filter((r) => r.path === `/rest/v1/rpc/${name}`);
const logouts = (seen) => seen.requests.filter((r) => r.path === '/auth/v1/logout');

async function signIn(page, email) {
  await page.goto('/sign-in');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

async function signInAsAdmin(page) {
  await signIn(page, 'admin@e2e.test');
  await expect(page.getByRole('heading', { level: 1, name: 'Dashboard' })).toBeVisible();
}

async function storedSessionKeys(page) {
  return page.evaluate(() => Object.keys(window.sessionStorage).filter((k) => k.startsWith('sb-')));
}

let backend;

test.beforeEach(async ({ page }) => {
  backend = await mockBackend(page);
});

test.afterEach(async () => {
  expect(backend.seen.unexpected, 'requests without a fixture').toEqual([]);
  expect(backend.seen.foreign, 'third-party requests').toEqual([]);
  expect(backend.seen.cspViolations, 'CSP violations').toEqual([]);
  expect(rpcCalls(backend.seen, 'verify_worker'), 'verify_worker must never be called').toEqual([]);
});

test('unauthenticated direct navigation to /reports redirects to /sign-in', async ({ page }) => {
  await page.goto('/reports');
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  expect(rpcCalls(backend.seen, 'list_reports')).toEqual([]);
});

test('a worker credential is signed out after the role check with the admin-only message', async ({ page }) => {
  await signIn(page, 'worker@e2e.test');
  await expect(page.getByText('This console is for SkillMatch administrators only.')).toBeVisible();
  await expect(page).toHaveURL(/\/sign-in$/);
  const roleReads = backend.seen.requests.filter((r) => r.path === '/rest/v1/users');
  expect(roleReads.length).toBeGreaterThan(0);
  expect(roleReads[0].search).toContain('select=role%2Cis_active');
  expect(roleReads[0].search).toContain(`id=eq.${WORKER_ACCOUNT_ID}`);
  expect(logouts(backend.seen).map((r) => r.search)).toEqual(['?scope=local']);
  expect(await storedSessionKeys(page)).toEqual([]);
  expect(rpcCalls(backend.seen, 'get_admin_analytics_summary')).toEqual([]);
});

test('an admin sees the dashboard', async ({ page }) => {
  await signInAsAdmin(page);
  await expect(page.getByRole('heading', { name: 'Platform summary' })).toBeVisible();
  await expect(page.getByText('1 Worker waiting for review')).toBeVisible();
  await expect(page.getByText('2 reports need attention')).toBeVisible();
  expect(rpcCalls(backend.seen, 'get_admin_analytics_summary').length).toBeGreaterThan(0);
  // Session is tab-scoped: sessionStorage, not localStorage.
  expect((await storedSessionKeys(page)).length).toBe(1);
  expect(await page.evaluate(() => Object.keys(window.localStorage).length)).toBe(0);
});

test('the approve confirmation dialog must be accepted before the RPC is sent', async ({ page }) => {
  await signInAsAdmin(page);
  await page.getByRole('link', { name: 'ID reviews', exact: true }).first().click();
  await page.getByRole('link', { name: 'Review identity for Maria Santos' }).click();
  await expect(page.getByRole('img', { name: 'Maria Santos identity document' })).toBeVisible();

  // Signed URL requested once, for 120 seconds, only now that the detail view is open.
  const signs = backend.seen.requests.filter((r) => r.path.startsWith('/storage/v1/object/sign/') && r.method === 'POST');
  expect(signs.map((r) => r.body)).toEqual([{ expiresIn: 120 }]);

  await page.getByRole('button', { name: 'Approve ID' }).click();
  const dialog = page.getByRole('dialog', { name: 'Approve this ID?' });
  await expect(dialog).toBeVisible();
  expect(rpcCalls(backend.seen, 'approve_worker_identity')).toEqual([]);

  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await expect(dialog).toBeHidden();
  expect(rpcCalls(backend.seen, 'approve_worker_identity')).toEqual([]);

  await page.getByRole('button', { name: 'Approve ID' }).click();
  await dialog.getByRole('button', { name: 'Approve ID' }).click();
  await expect(page.getByText('Identity approved. The Worker is now verified.')).toBeVisible();
  const approvals = rpcCalls(backend.seen, 'approve_worker_identity');
  expect(approvals.map((r) => r.body)).toEqual([{ p_worker_user_id: PENDING_WORKER_ID }]);
});

async function navigateWithinApp(page, pathname) {
  await page.evaluate((next) => {
    window.history.pushState(null, '', next);
    window.dispatchEvent(new PopStateEvent('popstate'));
  }, pathname);
}

test('an ID confirmation and rejection draft cannot carry over to a different Worker', async ({ page }) => {
  const nextWorkerId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  backend.state.identities = {
    [nextWorkerId]: { ...PENDING, user_id: nextWorkerId, full_name: 'Second Fixture Worker', storage_path: STORAGE_PATH },
  };
  await signInAsAdmin(page);
  await page.goto(`/id-reviews/${PENDING_WORKER_ID}`);
  await expect(page.getByRole('heading', { name: 'Maria Santos' })).toBeVisible();
  await page.getByLabel('Rejection reason').fill('Reason for the first Worker only');
  await page.getByRole('button', { name: 'Approve ID', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Approve this ID?' })).toBeVisible();

  await navigateWithinApp(page, `/id-reviews/${nextWorkerId}`);
  await expect(page.getByRole('heading', { name: 'Second Fixture Worker' })).toBeVisible();
  await expect(page.getByRole('dialog', { name: 'Approve this ID?' })).toBeHidden();
  await expect(page.getByLabel('Rejection reason')).toHaveValue('');
  expect(rpcCalls(backend.seen, 'approve_worker_identity')).toEqual([]);
});

test('a report confirmation and response draft cannot carry over to a different report', async ({ page }) => {
  const nextReportId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  backend.state.reports = {
    [nextReportId]: { ...reportRow('submitted'), report_id: nextReportId, description: 'Second fixture report' },
  };
  await signInAsAdmin(page);
  await page.goto(`/reports/${REPORT_ID}`);
  await page.getByLabel('Admin response').fill('Response for the first report only');
  await page.getByRole('button', { name: 'Resolve', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Resolve this report?' })).toBeVisible();

  await navigateWithinApp(page, `/reports/${nextReportId}`);
  await expect(page.getByText('Second fixture report', { exact: true })).toBeVisible();
  await expect(page.getByRole('dialog', { name: 'Resolve this report?' })).toBeHidden();
  await expect(page.getByLabel('Admin response')).toHaveValue('');
  expect(rpcCalls(backend.seen, 'review_report')).toEqual([]);
});

test('a late signed-image response cannot reopen an ID image after approval', async ({ page }) => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  let signerStarted;
  const started = new Promise((resolve) => { signerStarted = resolve; });
  await page.route(`${SUPABASE}/storage/v1/object/sign/worker-identity/${STORAGE_PATH}`, async (route) => {
    if (route.request().method() !== 'POST') return route.fallback();
    signerStarted();
    await pending;
    await route.fallback();
  });
  await signInAsAdmin(page);
  await page.goto(`/id-reviews/${PENDING_WORKER_ID}`);
  await started;
  await page.getByRole('button', { name: 'Approve ID', exact: true }).click();
  await page.getByRole('dialog', { name: 'Approve this ID?' }).getByRole('button', { name: 'Approve ID' }).click();
  await expect(page.getByText('Identity approved. The Worker is now verified.')).toBeVisible();
  const signed = page.waitForResponse((response) => response.request().method() === 'POST' && response.url().includes('/storage/v1/object/sign/'));
  release();
  await (await signed).finished();
  await page.evaluate(async () => {
    await new Promise((resolve) => requestAnimationFrame(resolve));
    await new Promise((resolve) => requestAnimationFrame(resolve));
  });
  await expect(page.getByRole('img', { name: 'Maria Santos identity document' })).toBeHidden();
  expect(backend.seen.requests.filter((r) => r.path.startsWith('/storage/v1/object/sign/') && r.method === 'GET')).toEqual([]);
});

test('a denied (42501) approve keeps the admin signed in and shows the permission message', async ({ page }) => {
  backend.state.approve = { status: 403, body: { code: '42501', message: 'permission denied', details: null, hint: null } };
  await signInAsAdmin(page);
  await page.goto(`/id-reviews/${PENDING_WORKER_ID}`);
  await page.getByRole('button', { name: 'Approve ID' }).click();
  const before = backend.seen.requests.filter((r) => r.path === '/rest/v1/users').length;
  await page.getByRole('dialog', { name: 'Approve this ID?' }).getByRole('button', { name: 'Approve ID' }).click();

  await expect(page.getByText("You don't have permission for that action.")).toBeVisible();
  await expect(page).toHaveURL(new RegExp(`/id-reviews/${PENDING_WORKER_ID}$`));
  await expect(page.getByRole('button', { name: 'Sign out', exact: true })).toBeVisible();
  // The denial triggered a role re-check, and no sign-out.
  expect(backend.seen.requests.filter((r) => r.path === '/rest/v1/users').length).toBeGreaterThan(before);
  expect(logouts(backend.seen)).toEqual([]);
  expect((await storedSessionKeys(page)).length).toBe(1);
});

test('a denied action signs out only when the re-check shows the role is gone', async ({ page }) => {
  backend.state.approve = { status: 403, body: { code: '42501', message: 'permission denied', details: null, hint: null } };
  await signInAsAdmin(page);
  await page.goto(`/id-reviews/${PENDING_WORKER_ID}`);
  await page.getByRole('button', { name: 'Approve ID' }).click();
  backend.state.roles[ADMIN_ID] = { role: 'administrator', is_active: false }; // deactivated meanwhile
  await page.getByRole('dialog', { name: 'Approve this ID?' }).getByRole('button', { name: 'Approve ID' }).click();

  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByText('This console is for SkillMatch administrators only.')).toBeVisible();
  expect(logouts(backend.seen).map((r) => r.search)).toEqual(['?scope=local']);
});

test('"Sign out" calls the logout endpoint with scope=local', async ({ page }) => {
  await signInAsAdmin(page);
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page).toHaveURL(/\/sign-in$/);
  expect(logouts(backend.seen).map((r) => r.search)).toEqual(['?scope=local']);
  expect(await storedSessionKeys(page)).toEqual([]);
});

test('"Sign out on all devices" is separate, confirmed, and uses scope=global', async ({ page }) => {
  await signInAsAdmin(page);
  await page.getByRole('button', { name: 'Sign out on all devices' }).click();
  const dialog = page.getByRole('dialog', { name: 'Sign out on all devices?' });
  await expect(dialog).toContainText('SkillMatch mobile app');
  expect(logouts(backend.seen)).toEqual([]);
  await dialog.getByRole('button', { name: 'Sign out everywhere' }).click();
  await expect(page).toHaveURL(/\/sign-in$/);
  expect(logouts(backend.seen).map((r) => r.search)).toEqual(['?scope=global']);
});

test('there is no signup link or route', async ({ page }) => {
  await page.goto('/sign-in');
  await expect(page.getByRole('link')).toHaveCount(0);
  await expect(page.getByText(/sign ?up|register|create (an )?account|forgot|reset password/i)).toHaveCount(0);
  await expect(page.locator('form input')).toHaveCount(2);

  for (const path of ['/sign-up', '/signup', '/register', '/reset-password', '/forgot-password']) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/sign-in$/);
    await expect(page.locator('form input')).toHaveCount(2);
  }

  await signInAsAdmin(page);
  await page.goto('/sign-up');
  await expect(page.getByRole('heading', { level: 1, name: 'Dashboard' })).toBeVisible();
  expect(backend.seen.requests.filter((r) => /\/auth\/v1\/(signup|recover|otp)/.test(r.path))).toEqual([]);
});

test('a report review is confirmed, then saved, then the outcome email is requested', async ({ page }) => {
  await signInAsAdmin(page);
  await page.getByRole('link', { name: 'Reports', exact: true }).first().click();
  await page.getByRole('link', { name: 'Other, Submitted. View report details' }).click();
  await page.getByLabel('Admin response').fill('Thanks, fixed.');
  await page.getByRole('button', { name: 'Resolve', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Resolve this report?' });
  await expect(dialog).toBeVisible();
  expect(rpcCalls(backend.seen, 'review_report')).toEqual([]);
  await dialog.getByRole('button', { name: 'Resolve' }).click();

  await expect(page.getByText('Review saved.')).toBeVisible();
  expect(rpcCalls(backend.seen, 'review_report').map((r) => r.body)).toEqual([
    { p_report_id: REPORT_ID, p_status: 'resolved', p_admin_response: 'Thanks, fixed.' },
  ]);
  const emails = backend.seen.requests.filter((r) => r.path === '/functions/v1/report-outcome-email');
  expect(emails.map((r) => r.body)).toEqual([{ report_id: REPORT_ID }]);
});

test('marking a report under review also requests the reporter email (owner, 2026-11-05)', async ({ page }) => {
  await signInAsAdmin(page);
  await page.getByRole('link', { name: 'Reports', exact: true }).first().click();
  await page.getByRole('link', { name: 'Other, Submitted. View report details' }).click();
  await page.getByRole('button', { name: 'Mark under review' }).click();
  const dialog = page.getByRole('dialog');
  if (await dialog.isVisible()) await dialog.getByRole('button', { name: /under review/i }).click();

  await expect(page.getByText('Review saved.')).toBeVisible();
  expect(rpcCalls(backend.seen, 'review_report').map((r) => r.body.p_status)).toEqual(['under_review']);
  const emails = backend.seen.requests.filter((r) => r.path === '/functions/v1/report-outcome-email');
  expect(emails.map((r) => r.body)).toEqual([{ report_id: REPORT_ID }]);
});

test('responses carry the vercel.json security headers', async ({ page }) => {
  const response = await page.goto('/sign-in');
  const headers = response.headers();
  expect(headers['content-security-policy']).toContain("default-src 'self'");
  expect(headers['content-security-policy']).toContain("frame-ancestors 'none'");
  expect(headers['content-security-policy']).toContain("base-uri 'none'");
  expect(headers['content-security-policy']).toContain("form-action 'self'");
  expect(headers['content-security-policy']).toContain("connect-src 'self' https://*.supabase.co");
  expect(headers['x-frame-options']).toBe('DENY');
  expect(headers['x-content-type-options']).toBe('nosniff');
  expect(headers['referrer-policy']).toBe('no-referrer');
  expect(headers['x-robots-tag']).toBe('noindex, nofollow');
  expect(headers['cache-control']).toBe('no-store');
  // The build also pins the exact project origin in a meta CSP.
  await expect(page.locator('meta[http-equiv="Content-Security-Policy"]')).toHaveAttribute(
    'content', new RegExp(`connect-src 'self' ${SUPABASE.replace(/\./g, '\\.')}(;|$)`)
  );
});

test('MOD-01: a Worker ban needs a reason and confirmation; reinstating resets strikes to 0', async ({ page }) => {
  await signInAsAdmin(page);
  await navigateWithinApp(page, `/users/worker/${PENDING_WORKER_ID}`);
  await expect(page.getByRole('heading', { name: 'Moderation' })).toBeVisible();
  await expect(page.getByRole('img', { name: 'No-show strikes: 2 of 3' })).toBeVisible();

  await page.getByRole('button', { name: 'Ban account' }).click();
  const dialog = page.getByRole('dialog', { name: 'Ban this account?' });
  await expect(dialog).toBeVisible();
  await dialog.getByRole('button', { name: 'Ban account' }).click();
  await expect(dialog.getByText('Enter a reason of 1 to 500 characters.')).toBeVisible();
  expect(rpcCalls(backend.seen, 'admin_set_account_banned')).toEqual([]);

  await dialog.getByLabel('Reason').fill('  Fraudulent listing  ');
  await dialog.getByRole('button', { name: 'Ban account' }).click();
  await expect(page.getByText('Account banned. It stays suspended until an Administrator reinstates it.')).toBeVisible();
  await expect(page.getByText('Fraudulent listing', { exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Reinstate account' })).toBeVisible();

  await page.getByRole('button', { name: 'Reinstate account' }).click();
  const reinstate = page.getByRole('dialog', { name: 'Reinstate this account?' });
  await reinstate.getByLabel('Reason').fill('Appeal accepted');
  await reinstate.getByRole('button', { name: 'Reinstate account' }).click();
  await expect(page.getByText('Account reinstated. No-show strikes were reset to 0.')).toBeVisible();
  await expect(page.getByRole('img', { name: 'No-show strikes: 0 of 3' })).toBeVisible();

  expect(rpcCalls(backend.seen, 'admin_set_account_banned').map((r) => r.body)).toEqual([
    { p_user_id: PENDING_WORKER_ID, p_banned: true, p_reason: 'Fraudulent listing' },
    { p_user_id: PENDING_WORKER_ID, p_banned: false, p_reason: 'Appeal accepted' },
  ]);
});

test('REG-01: Admin sees the full Worker resume on Worker details and on ID review', async ({ page }) => {
  await signInAsAdmin(page);
  await navigateWithinApp(page, `/users/worker/${PENDING_WORKER_ID}`);
  const resume = page.locator('section', { has: page.getByRole('heading', { name: 'Resume' }) });
  await expect(resume.getByText('12 M. Almeda St., Brgy. San Roque, Pateros, Metro Manila')).toBeVisible();
  await expect(resume.getByText('maria@e2e.test')).toBeVisible();
  await expect(resume.getByText('Vocational / TESDA')).toBeVisible();
  // Skill names only: no years of experience (owner, 2026-11-06) and no skill level (2026-11-05).
  await expect(resume.getByRole('heading', { name: 'Skills', exact: true })).toBeVisible();
  await expect(resume.getByText('Plumbing', { exact: true })).toBeVisible();
  await expect(resume.getByText(/\d+ years?\b/)).toHaveCount(0);
  await expect(resume.getByText(/Beginner|Intermediate|Expert/)).toHaveCount(0);
  await expect(resume.getByText('Carpenter · ABC Builders')).toBeVisible();
  await expect(resume.getByText('2018 – Present')).toBeVisible();

  await navigateWithinApp(page, `/id-reviews/${PENDING_WORKER_ID}`);
  await expect(page.getByRole('heading', { name: 'Resume' })).toBeVisible();
  await expect(page.getByText('Carpenter · ABC Builders')).toBeVisible();
  expect(rpcCalls(backend.seen, 'get_admin_account_profile').map((r) => r.body)).toEqual([
    { p_user_id: PENDING_WORKER_ID }, { p_user_id: PENDING_WORKER_ID },
  ]);
});

test('Settings: an admin changes their own password in place, with no email or reset route (owner, 2026-11-06)', async ({ page }) => {
  await signInAsAdmin(page);
  await page.getByRole('link', { name: 'Settings' }).click();
  await expect(page.getByRole('heading', { level: 1, name: 'Settings' })).toBeVisible();
  await expect(page.getByText('Alerts on your phone come from the SkillMatch mobile app.')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Open Notifications' })).toHaveAttribute('href', '/notifications');
  await expect(page.getByText(/^Built$/)).toBeVisible();

  const passwordPuts = () => backend.seen.requests.filter((r) => r.path === '/auth/v1/user' && r.method === 'PUT');
  const submit = page.getByRole('button', { name: 'Change password' });

  // Local rules first: nothing is sent.
  await page.getByLabel('New password', { exact: true }).fill('12345');
  await page.getByLabel('Confirm new password').fill('12345');
  await submit.click();
  await expect(page.getByRole('alert')).toHaveText('Password must be at least 6 characters.');
  await page.getByLabel('New password', { exact: true }).fill('new-secret-1');
  await page.getByLabel('Confirm new password').fill('new-secret-2');
  await submit.click();
  await expect(page.getByRole('alert')).toHaveText('The two passwords do not match.');
  expect(passwordPuts()).toEqual([]);

  // An Auth refusal gets plain wording, never the raw backend text.
  backend.state.passwordError = 'same_password';
  await page.getByLabel('Confirm new password').fill('new-secret-1');
  await submit.click();
  await expect(page.getByText('Choose a password different from your current one.')).toBeVisible();
  await expect(page.getByText('raw backend text that must not be shown')).toHaveCount(0);

  // Success: one PUT with only the password, then the fields clear.
  await submit.click();
  await expect(page.getByText('Your password was changed.')).toBeVisible();
  await expect(page.getByLabel('New password', { exact: true })).toHaveValue('');
  expect(passwordPuts().map((r) => r.body.password)).toEqual(['new-secret-1', 'new-secret-1']);
  expect(passwordPuts().every((r) => !('email' in r.body) && !('data' in r.body))).toBe(true);
  expect(backend.seen.requests.filter((r) => /\/auth\/v1\/(signup|recover|otp)/.test(r.path))).toEqual([]);
});

test('ADM-01: the Worker directory filters by account status and shows strikes', async ({ page }) => {
  await signInAsAdmin(page);
  await page.getByRole('link', { name: 'Workers' }).click();
  await expect(page.getByRole('heading', { level: 1, name: 'Workers' })).toBeVisible();
  const table = page.getByRole('table', { name: 'Workers' });
  await expect(table.getByRole('columnheader', { name: 'Strikes' })).toBeVisible();
  await expect(table.getByRole('row', { name: /Ana Active/ })).toContainText('1 of 3');
  await expect(table.getByRole('row', { name: /Sol Suspended/ })).toContainText('3 of 3');

  const filter = page.getByRole('group', { name: 'Account status' });
  await expect(filter.getByRole('radio', { name: 'All' })).toBeChecked();
  await filter.getByRole('radio', { name: 'Inactive' }).check();
  await expect(page).toHaveURL(/\/workers\?status=inactive$/);
  await expect(table.getByRole('row', { name: /Sol Suspended/ })).toBeVisible();
  await expect(table.getByRole('row', { name: /Ana Active/ })).toHaveCount(0);

  await filter.getByRole('radio', { name: 'Active', exact: true }).check();
  await expect(table.getByRole('row', { name: /Ana Active/ })).toBeVisible();
  await expect(table.getByRole('row', { name: /Sol Suspended/ })).toHaveCount(0);

  // The page may re-read once while the session settles; the order of statuses requested is what matters.
  const statuses = rpcCalls(backend.seen, 'get_admin_worker_directory_v2').map((r) => r.body.p_status);
  expect(statuses.filter((s, i) => s !== statuses[i - 1])).toEqual(['all', 'inactive', 'active']);
  expect(rpcCalls(backend.seen, 'get_admin_worker_directory')).toEqual([]);
});

test('NTF-01: the sidebar shows the unread count and a new ID alert opens ID reviews', async ({ page }) => {
  backend.state.unread = 3;
  backend.state.notifications = [
    { id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', type: 'identity_submitted', message: 'A Worker submitted an ID for review.', is_read: true, created_at: '2026-11-06T02:00:00Z' },
    { id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', type: 'worker_registered', message: 'A new Worker account was created.', is_read: true, created_at: '2026-11-06T01:00:00Z' },
  ];
  await signInAsAdmin(page);
  const link = page.getByRole('link', { name: 'Notifications 3 unread' });
  await expect(link).toBeVisible();
  await link.click();
  await expect(page.getByText('ID submitted for review')).toBeVisible();
  await expect(page.getByText('New Worker registered')).toBeVisible();
  await expect(page.getByText('Open ID reviews')).toBeVisible();
  await expect(page.getByText('Open Workers')).toBeVisible();
  await page.getByRole('button', { name: /ID submitted for review/ }).click();
  await expect(page).toHaveURL(/\/id-reviews$/);
  // The live channel was opened against the project, not a third party.
  expect(backend.seen.sockets.length).toBeGreaterThan(0);
  expect(backend.seen.sockets.every((u) => u.startsWith('wss://admin-e2e.supabase.co/realtime/v1/websocket'))).toBe(true);
});
