import { act, render } from '@testing-library/react-native';
import { useEffect } from 'react';

import { setApiToken } from '../api';
import { EventsProvider, useFlushEvents, useTrack } from '../events';
import type { Track } from '../view-tracker';

// Every batch the API "receives", with the token it was sent under.
const mockSent: { token: string | null; ids: string[] }[] = [];
let mockOnline = true;

jest.mock('@tspec/api-schema', () => ({
  createApiClient: (_url: string, getToken: () => string | null) => ({
    POST: async (_path: string, { body }: { body: { events: { content_id: string }[] } }) => {
      if (!mockOnline) throw new TypeError('Network request failed');
      mockSent.push({ token: getToken(), ids: body.events.map((e) => e.content_id) });
      return { response: { ok: true, status: 202 } };
    },
  }),
}));

const mockBeforeSignOut = new Set<() => Promise<unknown>>();
const registerBeforeSignOut = (fn: () => Promise<unknown>) => {
  mockBeforeSignOut.add(fn);
  return () => void mockBeforeSignOut.delete(fn);
};
const sessionFor = (token: string) => ({
  token,
  me: { id: token, onboarded: true },
  beforeSignOut: registerBeforeSignOut,
});
let mockSession = sessionFor('token-a');
jest.mock('../session', () => ({ useSession: () => mockSession }));

let track: Track;
let flushAll: () => Promise<boolean>;

function Harness() {
  const t = useTrack();
  const f = useFlushEvents();
  useEffect(() => {
    track = t;
    flushAll = f;
  });
  return null;
}

// Mirrors SessionProvider: the shared API client follows the signed-in token.
function signIn(token: string) {
  mockSession = sessionFor(token);
  setApiToken(token);
}

beforeEach(() => {
  mockSent.length = 0;
  mockOnline = true;
  mockBeforeSignOut.clear();
  signIn('token-a');
});

describe('EventsProvider', () => {
  it("never sends one account's events under another account's token", async () => {
    const view = await render(
      <EventsProvider>
        <Harness />
      </EventsProvider>,
    );

    // Account A watches something while offline: the batch stays queued.
    mockOnline = false;
    track('content-a', 'view_start');
    expect(await act(() => flushAll())).toBe(false);

    // A signs out, B signs in on the same device, and the network is back.
    signIn('token-b');
    await view.rerender(
      <EventsProvider>
        <Harness />
      </EventsProvider>,
    );
    mockOnline = true;
    track('content-b', 'view_start');
    expect(await act(() => flushAll())).toBe(true);

    const underB = mockSent.filter((s) => s.token === 'token-b').flatMap((s) => s.ids);
    expect(underB).toEqual(['content-b']);
  });

  it('sends unsent events under their own token before sign-out revokes it', async () => {
    await render(
      <EventsProvider>
        <Harness />
      </EventsProvider>,
    );
    mockOnline = false;
    track('content-a', 'view_start');
    await act(() => flushAll());
    mockOnline = true;

    // What SessionProvider.signOut runs before revoking the token.
    await act(() => Promise.all([...mockBeforeSignOut].map((fn) => fn())));

    expect(mockSent).toEqual([{ token: 'token-a', ids: ['content-a'] }]);
  });
});
