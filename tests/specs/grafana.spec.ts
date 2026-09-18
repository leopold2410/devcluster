import { test, expect } from '@playwright/test';
import { AUTH_URL, GROUP, USER, requirePassword, submitKeycloakForm } from './support';

// Grafana's OIDC login end to end (update-setup-05), plus the check that turns "Grafana is up"
// into "the stack is wired": all three data sources pass Grafana's own health check.
// Skipped when monitoring is not deployed - run.sh sets GRAFANA_URL only if the Ingress exists.

const GRAFANA = process.env.GRAFANA_URL ?? '';

test.skip(!GRAFANA, 'monitoring is not deployed (no grafana Ingress)');
test.beforeAll(requirePassword);

test('logs in through Keycloak as server admin, and every data source is healthy', async ({ page }) => {
  await page.goto(`${GRAFANA}/login`);

  // Grafana renders "Sign in with <name>" from auth.generic_oauth.name.
  await page.getByText(/sign in with keycloak/i).click();

  await page.waitForURL(AUTH_URL);
  await submitKeycloakForm(page);

  // Back in Grafana, past the login pages.
  await page.waitForURL((url) => url.origin === new URL(GRAFANA).origin && !url.pathname.startsWith('/login'));

  const user = await (await page.request.get(`${GRAFANA}/api/user`)).json();
  expect(user.login, 'Grafana takes the login from preferred_username').toBe(USER);
  // platform-admins maps to 'GrafanaAdmin': server admin, and Admin of the organisation.
  expect(user.isGrafanaAdmin, `${USER} should be Grafana server admin via ${GROUP}`).toBe(true);

  const orgs = await (await page.request.get(`${GRAFANA}/api/user/orgs`)).json();
  expect(orgs[0]?.role, 'organisation role').toBe('Admin');

  // In the logged-in session: Grafana's own check that it can reach each backend.
  for (const uid of ['prometheus', 'loki', 'tempo']) {
    const health = await page.request.get(`${GRAFANA}/api/datasources/uid/${uid}/health`);
    expect(health.ok(), `${uid} health request`).toBeTruthy();
    expect((await health.json()).status, `${uid} data source`).toBe('OK');
  }
});
