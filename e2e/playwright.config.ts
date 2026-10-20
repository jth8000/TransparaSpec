import { defineConfig, devices } from '@playwright/test';

/**
 * E2E against the Expo web build and the Phoenix dev server (LocalProvider
 * video, dev mailbox). Reuses servers that are already running.
 */
export default defineConfig({
  testDir: './tests',
  timeout: 120_000,
  expect: { timeout: 30_000 },
  fullyParallel: false,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: 'http://localhost:8081',
    trace: 'retain-on-failure',
    video: 'retain-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 420, height: 860 } } }],
  webServer: [
    {
      command: 'cd ../apps/server && mix phx.server',
      url: 'http://localhost:4000/api/health',
      reuseExistingServer: true,
      timeout: 120_000,
    },
    {
      command: 'npm run web -w apps/client -- --port 8081',
      cwd: '..',
      url: 'http://localhost:8081',
      reuseExistingServer: true,
      timeout: 180_000,
      env: { CI: '1' },
    },
  ],
});
