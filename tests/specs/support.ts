import { Page, expect } from '@playwright/test';

// Shared bits for the login suites. Values come from tests/run.sh, which reads the
// generated password from identity/out/ - nothing is hardcoded.

export const ARGOCD = process.env.ARGOCD_URL ?? 'https://argocd.kind.local';
export const HARBOR = process.env.HARBOR_URL ?? 'https://harbor.kind.local:3443';
export const REALM = process.env.KEYCLOAK_REALM ?? 'localdev';
export const USER = process.env.OIDC_USER ?? 'dev';
export const PASSWORD = process.env.OIDC_PASSWORD ?? '';
export const USER_EMAIL = process.env.OIDC_USER_EMAIL ?? `${USER}@kind.local`;
export const GROUP = process.env.OIDC_ADMIN_GROUP ?? 'platform-admins';

export const AUTH_URL = new RegExp(`/realms/${REALM}/protocol/openid-connect/auth`);

export function requirePassword() {
  if (!PASSWORD) {
    throw new Error('OIDC_PASSWORD is empty - run.sh reads it from identity/out/dev-password');
  }
}

/**
 * Fill in Keycloak's login form. Skipped when Keycloak already has an SSO session for
 * this browser context, in which case it redirects straight back to the client.
 */
export async function submitKeycloakForm(page: Page) {
  const username = page.locator('#username');
  if (await username.isVisible({ timeout: 15_000 }).catch(() => false)) {
    await username.fill(USER);
    await page.locator('#password').fill(PASSWORD);
    await page.locator('#kc-login').click();
  }
}

/**
 * Fail with the server's own message instead of a timeout when a client turns the OIDC
 * callback into an error page. That is how the missing offline_access scope showed up:
 * {"errors":[{"code":"BAD_REQUEST","message":"OIDC callback returned error: invalid_scope ..."}]}
 */
export async function failOnCallbackError(page: Page) {
  const body = (await page.locator('body').textContent({ timeout: 5_000 }).catch(() => '')) ?? '';
  const match = body.match(/OIDC callback returned error:[^"}]+/);
  expect(match?.[0] ?? null, 'the OIDC callback should not return an error').toBeNull();
}
