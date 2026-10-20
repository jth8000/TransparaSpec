// Web: localStorage for Phase 0. Whether web should move to an httpOnly
// cookie session is an open question (docs/open-questions.md).
const KEY = 'tspec.session.token';

export async function loadToken(): Promise<string | null> {
  try {
    return window.localStorage.getItem(KEY);
  } catch {
    return null;
  }
}

export async function saveToken(token: string | null): Promise<void> {
  try {
    if (token) window.localStorage.setItem(KEY, token);
    else window.localStorage.removeItem(KEY);
  } catch {
    // Storage unavailable (private mode): the session lasts for this page only.
  }
}
