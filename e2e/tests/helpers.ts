import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
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
async function latestCode(email: string): Promise<string> {
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
