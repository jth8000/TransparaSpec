import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { expect, type Page } from '@playwright/test';

const API = 'http://localhost:4000';

export const unique = () => `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;

/** A 3-second vertical test clip made with ffmpeg (cached between runs). */
export function testClip(): string {
  const dir = path.join(__dirname, '..', '.fixtures');
  const file = path.join(dir, 'clip.mp4');
  if (!existsSync(file)) {
    mkdirSync(dir, { recursive: true });
    execFileSync('ffmpeg', [
      '-y', '-v', 'error',
      '-f', 'lavfi', '-i', 'testsrc=duration=3:size=360x640:rate=24',
      '-f', 'lavfi', '-i', 'sine=duration=3',
      '-shortest', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', file,
    ]);
  }
  return file;
}

/** Reads the newest sign-in code sent to `email` from the dev mailbox. */
export async function latestCode(email: string): Promise<string> {
  let code: string | undefined;
  await expect
    .poll(async () => {
      const res = await fetch(`${API}/dev/mailbox/json`);
      const { data } = (await res.json()) as { data: { to: string[][] | string[]; subject: string }[] };
      const mail = data.find((m) => JSON.stringify(m.to).includes(email));
      code = mail?.subject.match(/(\d{6})$/)?.[1];
      return code;
    })
    .toBeTruthy();
  return code!;
}

/** Reads the newest magic link sent to `email` from the dev mailbox. */
export async function latestLink(email: string): Promise<URL> {
  let link: string | undefined;
  await expect
    .poll(async () => {
      const res = await fetch(`${API}/dev/mailbox/json`);
      const { data } = (await res.json()) as { data: { to: string[][] | string[]; text_body: string }[] };
      const mail = data.find((m) => JSON.stringify(m.to).includes(email));
      link = mail?.text_body.match(/https?:\/\/\S+\/verify\?\S+/)?.[0];
      return link;
    })
    .toBeTruthy();
  return new URL(link!);
}

/** Signs up through the UI: email → code → onboarding. Ends on the feed. */
export async function signUp(page: Page, handle: string) {
  const email = `${handle}@example.com`;

  await page.goto('/');
  await page.getByTestId('email-input').fill(email);
  await page.getByTestId('request-code').click();

  await page.getByTestId('code-input').fill(await latestCode(email));
  await page.getByTestId('verify-code').click();

  await page.getByTestId('handle-input').fill(handle);
  await page.getByTestId('birthdate-input').fill('2000-01-15');
  await page.getByTestId('accept-terms').click();
  await page.getByTestId('finish-onboarding').click();

  await expect(page.getByTestId('feed-tab-following')).toBeVisible();
}

/** A signed-in, onboarded user created through the API (no browser). */
export type ApiUser = { handle: string; token: string };

export async function api<T = unknown>(token: string | null, method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${await res.text()}`);
  return (res.status === 204 ? undefined : await res.json()) as T;
}

export async function apiSignUp(handle: string): Promise<ApiUser> {
  const email = `${handle}@example.com`;
  await api(null, 'POST', '/api/auth/request', { email });
  const { token } = await api<{ token: string }>(null, 'POST', '/api/auth/verify', {
    email,
    code: await latestCode(email),
  });
  const { version } = await api<{ version: number }>(null, 'GET', '/api/consent/current');
  await api(token, 'POST', '/api/onboarding', { handle, birthdate: '2000-01-15', accept_consent_version: version });
  return { handle, token };
}

/** Uploads the test clip through the provider and waits until it's ready. */
export async function apiVideo(user: ApiUser, caption: string, topics: string[]): Promise<string> {
  const { content, upload } = await api<{ content: { id: string }; upload: { url: string; form_field: string } }>(
    user.token,
    'POST',
    '/api/videos',
    { caption, topics },
  );
  const form = new FormData();
  form.append(upload.form_field, new Blob([readFileSync(testClip())], { type: 'video/mp4' }), 'clip.mp4');
  const res = await fetch(upload.url, { method: 'POST', body: form });
  if (!res.ok) throw new Error(`upload -> ${res.status}`);

  await expect
    .poll(async () => (await api<{ status: string }>(user.token, 'GET', `/api/content/${content.id}`)).status, {
      timeout: 60_000,
    })
    .toBe('ready');
  return content.id;
}

/** Records one fully watched view of `contentId` (the client's event shape). */
export async function apiWatch(user: ApiUser, contentId: string, seconds = 3) {
  const view_id = crypto.randomUUID();
  const occurred_at = new Date().toISOString();
  await api(user.token, 'POST', '/api/events', {
    events: [
      { content_id: contentId, view_id, type: 'view_start', occurred_at },
      { content_id: contentId, view_id, type: 'complete', value: seconds, occurred_at },
    ],
  });
}
