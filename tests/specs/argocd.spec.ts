import { test, expect } from '@playwright/test';
import { ARGOCD, AUTH_URL, GROUP, USER, USER_EMAIL, requirePassword, submitKeycloakForm } from './support';

// The browser half of Argo CD's OIDC login, which curl cannot reach: the button, the
// Keycloak form, the callback and the session that comes back. Three real failures
// during update-setup-03 lived exactly here - the wrong origin, a rejected return_url,
// and a Secure state cookie that a plain-http page never stores.

test.beforeAll(requirePassword);

test('logs in through Keycloak and lands with admin rights', async ({ page }) => {
  await page.goto(`${ARGOCD}/`);

  // Argo CD renders this button from oidc.config; its label is the "name:" field there.
  await page.getByRole('button', { name: /log in via keycloak/i }).click();

  await page.waitForURL(AUTH_URL);
  await submitKeycloakForm(page);

  // Back on Argo CD, past /auth/*, with a session.
  await page.waitForURL((url) => url.origin === new URL(ARGOCD).origin && !url.pathname.startsWith('/auth/'));

  const info = await page.request.get(`${ARGOCD}/api/v1/session/userinfo`);
  expect(info.ok(), 'userinfo request should succeed').toBeTruthy();

  const session = await info.json();
  expect(session.loggedIn, 'session should be logged in').toBe(true);
  // Argo CD takes the identity from the email claim, not from preferred_username -
  // so this is dev@kind.local while Harbor onboards plain "dev".
  expect(session.username, 'Argo CD identifies the user by the email claim').toBe(USER_EMAIL);
  // The groups claim is what grants role:admin through argocd-rbac-cm.
  expect(session.groups ?? [], `${USER} should be in ${GROUP}`).toContain(GROUP);
});

test('rejects the login when it starts on the http origin', async ({ page }) => {
  // cloud-provider-kind serves the UI on http as well and does not redirect to https.
  // Argo CD validates the login request's return_url against url in argocd-cm, so the
  // http origin is refused - deliberately, because its Secure state cookie would never
  // be stored and the callback would fail later, after the password has been typed.
  const httpOrigin = ARGOCD.replace('https://', 'http://');
  const response = await page.request.get(
    `${httpOrigin}/auth/login?return_url=${encodeURIComponent(httpOrigin + '/')}`,
    { maxRedirects: 0 },
  );
  expect(response.status(), 'http origin should be refused up front').toBe(400);
  expect(await response.text()).toContain('Invalid redirect URL');
});
