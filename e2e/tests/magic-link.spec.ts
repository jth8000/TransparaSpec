import { expect, test } from '@playwright/test';

import { api, latestLink, unique } from './helpers';

/**
 * Opening the emailed link must not sign in by itself: mail scanners open
 * links too, and a link someone else sent shouldn't sign you into their
 * account. It shows the address and waits for a tap.
 */
test('the magic link shows who it signs in as and waits for a tap', async ({ page }) => {
  const email = `link_${unique()}@example.com`;
  await api(null, 'POST', '/api/auth/request', { email });
  const link = await latestLink(email);
  expect(link.searchParams.get('email')).toBe(email);

  const verifies: string[] = [];
  page.on('request', (req) => {
    if (req.url().endsWith('/api/auth/verify')) verifies.push(req.url());
  });

  await page.goto(link.pathname + link.search);
  const confirm = page.getByTestId('confirm-link');
  await expect(confirm).toHaveText(`Continue as ${email}`);
  await page.waitForLoadState('networkidle');
  expect(verifies).toHaveLength(0);

  await confirm.click();
  // A new account goes on to onboarding.
  await expect(page.getByTestId('handle-input')).toBeVisible();
  expect(verifies).toHaveLength(1);
});
