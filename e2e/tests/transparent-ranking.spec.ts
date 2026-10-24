import { expect, test, type Page } from '@playwright/test';

import { api, apiSignUp, apiVideo, apiWatch, unique, type ApiUser } from './helpers';

type Contribution = { feature: string; topic?: string | null; contribution: number };
type Explanation = {
  final_score: number;
  contributions: Contribution[];
  settings_version: number;
  settings: { topics: { slug: string; multiplier: number; hard_off: boolean }[] };
};
type Item = { id: string; impression_id: string; topics: { slug: string }[] };
type Rerank = { session_id: string; rev: number; after_impression_id: string | null; items: Item[] };

const FITNESS = 'fitness-and-exercise';
const TOKEN_KEY = 'tspec.session.token';

/** Opens the app signed in as `user`, recording feed_reranked pushes as they arrive. */
async function openFeed(browser: import('@playwright/test').Browser, user: ApiUser) {
  const context = await browser.newContext();
  await context.addInitScript(([key, token]) => window.localStorage.setItem(key, token), [TOKEN_KEY, user.token]);
  const page = await context.newPage();
  const pushes: { at: number; push: Rerank }[] = [];

  page.on('websocket', (ws) =>
    ws.on('framereceived', ({ payload }) => {
      // Phoenix v2 frames: [join_ref, ref, topic, event, payload]
      const frame = JSON.parse(String(payload));
      if (frame[3] === 'feed_reranked') pushes.push({ at: Date.now(), push: frame[4] });
    }),
  );

  await page.goto('/feed');
  await expect(page.getByTestId('why-button').first()).toBeVisible({ timeout: 30_000 });
  return { page, pushes };
}

const sum = (cs: Contribution[]) => cs.reduce((total, c) => total + c.contribution, 0);
const labeled = (item: Item, slug: string) => item.topics.some((t) => t.slug === slug);

async function whyImpressionId(page: Page) {
  await page.getByTestId('why-button').first().click();
  await expect(page.getByTestId('why-total')).toBeVisible();
  return page.url().split('/why/')[1];
}

/**
 * Phase 1a "done when" (ADR 0011/0012): turning off "fitness" visibly re-ranks
 * the feed within a second, and every item's explanation matches its stored
 * trace — including after the settings change again.
 */
test('turning off fitness re-ranks For You live, and explanations match their stored traces', async ({
  browser,
}) => {
  test.setTimeout(180_000);
  const id = unique();

  // --- Content: creators post fitness, cooking and travel.
  const creators = await Promise.all([1, 2, 3].map((n) => apiSignUp(`tr_${id}_c${n}`)));
  for (let i = 0; i < 12; i++) {
    const topic = [FITNESS, 'cooking', 'travel'][i % 3];
    await api(creators[i % 3].token, 'POST', '/api/posts', { body: `${topic} #${i} ${id}`, topics: [topic] });
  }
  const watched = [
    await apiVideo(creators[0], `leg day ${id}`, [FITNESS]),
    await apiVideo(creators[1], `core ${id}`, [FITNESS]),
  ];

  // --- The viewer watches fitness to the end, and the model learns it.
  const viewer = await apiSignUp(`tr_${id}_v`);
  for (const contentId of watched) await apiWatch(viewer, contentId);
  await expect
    .poll(
      async () =>
        (await api<{ topics: { slug: string; score: number }[] }>(viewer.token, 'GET', '/api/me/interests')).topics.find(
          (t) => t.slug === FITNESS,
        )?.score ?? 0,
      { timeout: 30_000 },
    )
    .toBeGreaterThan(1.5);

  // --- Two devices: each its own feed session (ADR 0011).
  const phone = await openFeed(browser, viewer);
  const laptop = await openFeed(browser, viewer);

  // Fitness ranks first, and the trace says it's learned interest.
  await expect(phone.page.getByText('#Fitness and Exercise').first()).toBeVisible();
  const firstImpression = await whyImpressionId(phone.page);
  const first = await api<Explanation>(viewer.token, 'GET', `/api/impressions/${firstImpression}`);
  expect(first.contributions.some((c) => c.feature === 'topic_affinity' && c.topic === FITNESS)).toBe(true);

  // The sheet shows exactly the stored trace: every row, and the stored total.
  expect(sum(first.contributions)).toBe(first.final_score);
  await expect(phone.page.getByTestId('why-row')).toHaveCount(first.contributions.length);
  await expect(phone.page.getByTestId('why-total')).toHaveText(first.final_score.toFixed(3));
  const shown = await phone.page.getByTestId('why-row-contribution').allTextContents();
  const stored = [...first.contributions]
    .sort((a, b) => Math.abs(b.contribution) - Math.abs(a.contribution))
    .map((c) => `${c.contribution >= 0 ? '+' : '−'}${Math.abs(c.contribution).toFixed(2)}`);
  expect(shown).toEqual(stored);
  await phone.page.goBack();
  await expect(phone.page.getByTestId('tune-button')).toBeVisible();

  // --- Turn fitness off in Tune, with no reload.
  let navigations = 0;
  phone.page.on('framenavigated', (f) => f === phone.page.mainFrame() && navigations++);
  await phone.page.getByTestId('tune-button').click();
  const before = phone.pushes.length;
  const clicked = Date.now();
  await phone.page.getByTestId(`tune-topic-${FITNESS}-switch`).click();

  await expect.poll(() => phone.pushes.length, { timeout: 5_000 }).toBeGreaterThan(before);
  const { at, push } = phone.pushes[before];
  console.log(`  live re-rank: ${at - clicked} ms from tap to pushed feed (incl. 150 ms debounce)`);
  expect(at - clicked).toBeLessThan(1_000);
  expect(navigations).toBe(0);

  // The item being watched stays; nothing after it is labeled fitness.
  expect(push.after_impression_id).not.toBeNull();
  expect(push.items.length).toBeGreaterThan(0);
  for (const item of push.items) expect(labeled(item, FITNESS)).toBe(false);
  await expect(phone.page.getByTestId(`feed-item-${push.items[0].id}`)).toBeAttached();

  // Every newly served item's explanation is its stored trace, under the new settings.
  for (const item of push.items) {
    const e = await api<Explanation>(viewer.token, 'GET', `/api/impressions/${item.impression_id}`);
    expect(sum(e.contributions)).toBe(e.final_score);
    expect(e.settings_version).toBe(1);
    expect(e.contributions.some((c) => c.topic === FITNESS)).toBe(false);
  }

  // The other device re-ranked its own feed, from its own position.
  await expect.poll(() => laptop.pushes.length, { timeout: 5_000 }).toBeGreaterThan(0);
  const other = laptop.pushes[0].push;
  expect(other.session_id).not.toBe(push.session_id);
  for (const item of other.items) expect(labeled(item, FITNESS)).toBe(false);

  // --- Settings change again (version 2). An item served under version 1
  // still explains itself with version 1's settings.
  const servedUnderV1 = push.items[0];
  await api(viewer.token, 'PUT', '/api/algorithm/settings', { topics: { cooking: { multiplier: 1.5 } } });

  const later = await api<Explanation>(viewer.token, 'GET', `/api/impressions/${servedUnderV1.impression_id}`);
  expect(later.settings_version).toBe(1);
  expect(later.settings.topics).toEqual([{ slug: FITNESS, multiplier: 1, hard_off: true }]);

  await phone.page.goto(`/why/${servedUnderV1.impression_id}`);
  await expect(phone.page.getByTestId('why-total')).toHaveText(later.final_score.toFixed(3));
  await expect(phone.page.getByText(/version 1\)/)).toBeVisible();
});
