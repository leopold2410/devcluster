import { test, expect } from '@playwright/test';
import { AUTH_URL, GROUP, USER, requirePassword, submitKeycloakForm } from './support';

// Vault's UI login through Keycloak (update-setup-06). Vault opens the provider in a popup
// window; after the callback the popup closes and the main window is logged in. The token the
// UI then holds must carry policy "admin", granted through the external group platform-admins.
// Skipped when Vault is not set up - run.sh sets VAULT_URL only then.

const VAULT = process.env.VAULT_URL ?? '';

test.skip(!VAULT, 'Vault is not set up (no vault/out/root-token)');
test.beforeAll(requirePassword);

test('logs in through Keycloak and gets policy admin from platform-admins', async ({ page }) => {
  await page.goto(`${VAULT}/ui/vault/auth?with=oidc`);

  const popupPromise = page.waitForEvent('popup');
  await page.getByRole('button', { name: /sign in with/i }).click();
  const popup = await popupPromise;

  await popup.waitForURL(AUTH_URL);
  await submitKeycloakForm(popup);

  // Logged in: the UI leaves the auth page.
  await page.waitForURL((url) => url.pathname.startsWith('/ui/vault/') && !url.pathname.startsWith('/ui/vault/auth'));

  // The UI keeps the token in the browser's storage; ask Vault what it carries.
  const token = await page.evaluate(() => {
    for (const store of [window.localStorage, window.sessionStorage]) {
      for (let i = 0; i < store.length; i++) {
        const raw = store.getItem(store.key(i) as string) ?? '';
        try {
          const value = JSON.parse(raw);
          if (value && typeof value.token === 'string') return value.token;
        } catch { /* not JSON */ }
      }
    }
    return null;
  });
  expect(token, 'the UI should hold a Vault token').toBeTruthy();

  const lookup = await page.request.get(`${VAULT}/v1/auth/token/lookup-self`, {
    headers: { 'X-Vault-Token': token as string },
  });
  expect(lookup.ok(), 'token lookup').toBeTruthy();
  const data = (await lookup.json()).data;

  expect(data.meta?.role, 'logged in with the OIDC role').toBe('default');
  expect(data.display_name, 'display name from preferred_username').toContain(USER);
  // The external group platform-admins, filled from the groups claim, grants "admin".
  expect(data.identity_policies ?? [], `${USER} should get admin via ${GROUP}`).toContain('admin');
});
