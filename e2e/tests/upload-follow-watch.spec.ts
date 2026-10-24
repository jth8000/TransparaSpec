import { expect, test } from '@playwright/test';

import { signUp, testClip, unique } from './helpers';

/**
 * The Phase 0 "done when" path on web: A uploads a video; B follows A and
 * watches it play in the Following feed.
 */
test('a followed creator’s upload plays in the Following feed', async ({ browser }) => {
  const id = unique();
  const creatorHandle = `creator_${id}`;
  const viewerHandle = `viewer_${id}`;

  // --- Creator signs up and uploads.
  const creator = await (await browser.newContext()).newPage();
  await signUp(creator, creatorHandle);

  await creator.getByRole('tab', { name: /create/i }).click();
  await creator.getByTestId('caption-input').fill(`hello from ${creatorHandle}`);

  const chooser = creator.waitForEvent('filechooser');
  await creator.getByTestId('pick-video').click();
  await (await chooser).setFiles(testClip());

  // Upload → ffmpeg transcode → webhook → pushed over the user channel.
  await expect(creator.getByTestId('upload-status')).toHaveText('Your video is live.', {
    timeout: 60_000,
  });

  // --- Viewer signs up, follows the creator, opens Following.
  const viewer = await (await browser.newContext()).newPage();
  await signUp(viewer, viewerHandle);

  await viewer.goto(`/u/${creatorHandle}`);
  await viewer.getByTestId('follow-button').click();
  await expect(viewer.getByTestId('follow-button')).toHaveText('Following');
  await expect(viewer.getByTestId('followers-count')).toContainText('1');

  await viewer.goto('/');
  await viewer.getByTestId('feed-tab-following').click();
  await expect(viewer.getByText(`@${creatorHandle}`)).toBeVisible();
  await expect(viewer.getByText(`hello from ${creatorHandle}`)).toBeVisible();

  // Engagement events are batched and flushed on a timer (≤10 s).
  const eventsPosted = viewer.waitForResponse(
    (r) => r.url().endsWith('/api/events') && r.request().method() === 'POST',
    { timeout: 20_000 },
  );

  // It really plays: the <video> advances past the start.
  const video = viewer.getByTestId('feed-video').first();
  await expect
    .poll(() => video.evaluate((v: HTMLVideoElement) => v.currentTime), { timeout: 20_000 })
    .toBeGreaterThan(0.5);

  const response = await eventsPosted;
  expect(response.status()).toBe(202);
  const sent = response.request().postDataJSON() as { events: { type: string; view_id?: string }[] };
  expect(sent.events.map((e) => e.type)).toContain('view_start');
  expect(sent.events.some((e) => 'consent_version' in e)).toBe(false);
  // Every playback event belongs to a view (ADR 0012): one UUID per episode.
  const start = sent.events.find((e) => e.type === 'view_start')!;
  expect(start.view_id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  expect(((await response.json()) as { accepted: number }).accepted).toBeGreaterThan(0);
});
