import { expect, test, type Page } from '@playwright/test';

import { api, apiSignUp, apiVideo, apiWatch, unique } from './helpers';

const TOKEN_KEY = 'tspec.session.token';

/** Content ids of feed items whose top is near the top of the viewport. */
const onScreen = (page: Page) =>
  page.evaluate(() => {
    const h = window.innerHeight;
    return [...document.querySelectorAll('[data-testid^="feed-item-"]')]
      .filter((e) => {
        const r = e.getBoundingClientRect();
        return r.top > -h / 2 && r.top < h / 2;
      })
      .map((e) => e.getAttribute('data-testid')!.replace('feed-item-', ''));
  });

/**
 * On web, a covered screen is hidden and the browser resets the feed's
 * scroll. Coming back (from "Why?" or another tab) must return to the same
 * item without telling the feed session the user moved (which would make a
 * re-rank replace what they'd already passed).
 */
test('the feed keeps its place after "Why?" and after switching tabs', async ({ browser }) => {
  test.setTimeout(120_000);
  const id = unique();
  const creator = await apiSignUp(`pos_${id}_c`);
  for (let i = 0; i < 8; i++) {
    await api(creator.token, 'POST', '/api/posts', { body: `post ${i} ${id}`, topics: ['travel'] });
  }

  const viewer = await apiSignUp(`pos_${id}_v`);
  const context = await browser.newContext();
  await context.addInitScript(([key, token]) => window.localStorage.setItem(key, token), [TOKEN_KEY, viewer.token]);
  const page = await context.newPage();

  const positions: string[] = [];
  page.on('websocket', (ws) =>
    ws.on('framesent', ({ payload }) => {
      const frame = JSON.parse(String(payload));
      if (frame[3] === 'at') positions.push(frame[4].impression_id);
    }),
  );

  await page.goto('/feed');
  await expect(page.getByTestId('why-button').first()).toBeVisible({ timeout: 30_000 });
  for (let i = 0; i < 4; i++) {
    await page.mouse.wheel(0, 900);
    await page.waitForTimeout(700);
  }
  const here = await onScreen(page);
  expect(here).toHaveLength(1);

  // "Why?" and back.
  let reported = positions.length;
  await page.getByTestId('why-button').filter({ visible: true }).first().click();
  await expect(page.getByTestId('why-total')).toBeVisible();
  await page.goBack();
  await page.waitForTimeout(1_000);
  expect(await onScreen(page)).toEqual(here);
  expect(positions.slice(reported)).toEqual([]);

  // To the Algorithm tab and back. While away, the viewer watches a video
  // (on another device, say); the tab shows the new interest without reload.
  reported = positions.length;
  await page.getByRole('tab', { name: /algorithm/i }).click();
  await expect(page.getByText('What it has learned about you')).toBeVisible();
  await page.getByRole('tab', { name: /feed/i }).click();
  await page.waitForTimeout(500);

  const cooking = await apiVideo(creator, `pasta ${id}`, ['cooking']);
  await apiWatch(viewer, cooking);
  await expect
    .poll(async () => (await api<{ topics: { slug: string }[] }>(viewer.token, 'GET', '/api/me/interests')).topics.length, {
      timeout: 30_000,
    })
    .toBeGreaterThan(0);

  await page.getByRole('tab', { name: /algorithm/i }).click();
  await expect(page.getByTestId('interest-cooking')).toBeVisible({ timeout: 10_000 });
  await page.getByRole('tab', { name: /feed/i }).click();
  await page.waitForTimeout(1_000);
  expect(await onScreen(page)).toEqual(here);
  expect(positions.slice(reported)).toEqual([]);

  // And scrolling still reports positions (the wheel scrolls whatever is
  // under the mouse, which is still over the tab bar).
  await page.mouse.move(200, 300);
  await page.mouse.wheel(0, 900);
  await expect.poll(() => positions.length, { timeout: 5_000 }).toBeGreaterThan(reported);
  expect(await onScreen(page)).not.toEqual(here);
});
