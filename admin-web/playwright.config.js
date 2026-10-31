import { defineConfig, devices } from '@playwright/test';

/**
 * MOCKED-BACKEND UI evidence only (see e2e/admin.spec.js). The app is built
 * into .e2e-dist with a fake project URL and served by `vite preview`, which
 * applies the same response headers as vercel.json. Every Supabase request is
 * intercepted in the browser; nothing reaches a real project.
 */
export const E2E_SUPABASE_URL = 'https://admin-e2e.supabase.co';
const PORT = 4175;

// Default: the installed Google Chrome (no browser download). Set
// PLAYWRIGHT_CHANNEL=chromium to use Playwright's bundled build instead
// (after `npx playwright install chromium`).
const channel = process.env.PLAYWRIGHT_CHANNEL ?? 'chrome';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: true,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: `http://localhost:${PORT}`,
    trace: 'retain-on-failure',
  },
  projects: [{
    name: 'chromium',
    use: { ...devices['Desktop Chrome'], ...(channel === 'chromium' ? {} : { channel }) },
  }],
  webServer: {
    command: `npx vite build --outDir .e2e-dist && npx vite preview --outDir .e2e-dist --port ${PORT} --strictPort`,
    url: `http://localhost:${PORT}/sign-in`,
    reuseExistingServer: false,
    timeout: 120_000,
    env: {
      VITE_SUPABASE_URL: E2E_SUPABASE_URL,
      VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_e2e_mock_not_a_real_key',
    },
  },
});
