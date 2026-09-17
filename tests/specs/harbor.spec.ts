import { test, expect } from '@playwright/test';
import { AUTH_URL, GROUP, HARBOR, USER, failOnCallbackError, requirePassword, submitKeycloakForm } from './support';

// Harbor's OIDC login end to end. Unlike Argo CD, Harbor onboards the account on first
// login and decides administrator rights from the groups claim, so both are asserted.

test.beforeAll(requirePassword);

test('logs in through Keycloak and is onboarded as an administrator', async ({ page }) => {
  await page.goto(`${HARBOR}/`);

  // Harbor labels it "LOGIN WITH <oidc_name>": a button inside a link to /c/oidc/login.
  await page.getByRole('button', { name: /login with keycloak/i }).click();

  await page.waitForURL(AUTH_URL);
  await submitKeycloakForm(page);

  // Harbor can answer the callback with a JSON error page; say what it was.
  await failOnCallbackError(page);

  // First OIDC login may ask to confirm the account name; oidc_auto_onboard with
  // oidc_user_claim usually skips it, so only fill it in when it appears.
  const onboardField = page.locator('#username_for_oidc');
  if (await onboardField.isVisible({ timeout: 5_000 }).catch(() => false)) {
    await onboardField.fill(USER);
    await page.getByRole('button', { name: /save|submit|ok/i }).first().click();
  }

  await page.waitForURL(new RegExp('/harbor/'));

  const me = await page.request.get(`${HARBOR}/api/v2.0/users/current`);
  expect(me.ok(), 'users/current should succeed once logged in').toBeTruthy();

  const user = await me.json();
  expect(user.username, 'Harbor onboards the preferred_username claim').toBe(USER);
  // Admin rights come from the groups claim, per session. Harbor reports that as
  // admin_role_in_auth; sysadmin_flag stays false because that column is for locally
  // promoted admins, not for rights derived from oidc_admin_group.
  expect(user.admin_role_in_auth, `${USER} should be admin via ${GROUP}`).toBe(true);

  // And prove the rights are effective, not just reported: only a Harbor sysadmin may
  // read the configuration.
  const config = await page.request.get(`${HARBOR}/api/v2.0/configurations`);
  expect(config.status(), 'an admin session may read the configuration').toBe(200);
});
