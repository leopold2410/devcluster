import { defineConfig, devices } from '@playwright/test';

// Browser smoke tests for the Keycloak logins (update-setup-03).
// Run them with tests/run.sh, which resolves the host names into the container and
// checks the certificates with the real CA before the browser starts.
export default defineConfig({
  testDir: './specs',
  timeout: 90_000,
  expect: { timeout: 20_000 },
  reporter: [['list']],
  // One worker: both tests drive the same Keycloak and the same Harbor account.
  workers: 1,
  use: {
    // The certificates come from the local CA, which this throwaway browser profile does
    // not trust. run.sh verifies them with curl and the real root CA beforehand, so this
    // switch only spares us installing the CA into the container's NSS database.
    ignoreHTTPSErrors: true,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    actionTimeout: 20_000,
  },
  projects: [
    {
      // A real browser: the Chromium build that ships with the Playwright image, driven
      // with Chrome's device profile. Set PLAYWRIGHT_CHANNEL=chrome in run.sh to use
      // branded Google Chrome instead - the image can fetch it with
      // "npx playwright install chrome".
      name: 'chrome',
      use: {
        ...devices['Desktop Chrome'],
        channel: process.env.PLAYWRIGHT_CHANNEL || undefined,
      },
    },
  ],
});
