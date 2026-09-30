import { test, expect } from '@playwright/test';
import { AUTH_URL, GROUP, USER, requirePassword, submitKeycloakForm } from './support';

// The RustFS console login through Keycloak (update-setup-09). RustFS exchanges the login for
// temporary S3 credentials and takes the user's policies from the token claim "policy", which
// Keycloak fills from the client roles of "rustfs". Members of platform-admins get the policy
// of that name, which makes them administrators.
// Skipped when the object store is not set up - run.sh sets RUSTFS_URL only then.

const RUSTFS = process.env.RUSTFS_URL ?? '';

test.skip(!RUSTFS, 'RustFS is not set up (no objectstore/out)');
test.beforeAll(requirePassword);

test('logs in through Keycloak and is an administrator via platform-admins', async ({ page }) => {
  await page.goto(`${RUSTFS}/rustfs/console/`);
  await page.getByRole('button', { name: /login with keycloak/i }).click();

  await page.waitForURL(AUTH_URL);
  await submitKeycloakForm(page);

  // RustFS answers a failed policy mapping with an XML error instead of the console.
  await page.waitForURL(/\/rustfs\/console\/browser/);

  // The console keeps the temporary credentials in the browser; the session token is a JWT
  // whose claims say who RustFS thinks this is.
  const claims = await page.evaluate(() => {
    const credentials = JSON.parse(localStorage.getItem('auth.credentials') ?? '{}');
    const payload = (credentials.SessionToken ?? '..').split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return payload ? JSON.parse(atob(payload)) : {};
  });
  expect(claims.preferred_username, 'user name from preferred_username').toBe(USER);
  expect(claims.groups ?? [], 'groups claim reaches RustFS').toContain(GROUP);
  expect(claims.policy, `${USER} should get the policy named after ${GROUP}`).toContain(GROUP);

  expect(await page.evaluate(() => localStorage.getItem('auth.isAdmin')), 'administrator').toBe('true');
});
