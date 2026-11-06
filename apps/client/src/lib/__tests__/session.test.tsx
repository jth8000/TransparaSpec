import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, render, screen } from '@testing-library/react-native';
import { useEffect } from 'react';
import { Text } from 'react-native';

import { api } from '../api';
import { SessionProvider, useSession } from '../session';
import { saveToken } from '../token-storage';

jest.mock('../token-storage', () => ({
  loadToken: jest.fn(async () => 'stored-token'),
  saveToken: jest.fn(async () => undefined),
}));

jest.mock('../api', () => {
  const actual = jest.requireActual('../api');
  return { ...actual, setApiToken: jest.fn(), api: { GET: jest.fn(), DELETE: jest.fn() } };
});

const me = { id: 'u1', email: 'u1@example.com', handle: 'u1', onboarded: true };
const ok = (data: unknown) => ({ data, response: { ok: true, status: 200 } });
const status = (code: number) => ({ error: { error: 'x', message: 'x' }, response: { ok: false, status: code } });

let session: ReturnType<typeof useSession>;

function Probe() {
  const s = useSession();
  useEffect(() => {
    session = s;
  });
  const state = s.isLoading ? 'loading' : s.restoreFailed ? 'unreachable' : s.token ? 'signed-in' : 'signed-out';
  return <Text testID="state">{state}</Text>;
}

async function launch() {
  await render(
    <QueryClientProvider client={new QueryClient()}>
      <SessionProvider>
        <Probe />
      </SessionProvider>
    </QueryClientProvider>,
  );
}

const GET = api.GET as jest.Mock;
const DELETE = api.DELETE as jest.Mock;

beforeEach(() => jest.clearAllMocks());

describe('SessionProvider', () => {
  it("keeps the stored token when the server can't be reached at launch, and retries", async () => {
    GET.mockRejectedValueOnce(new TypeError('Network request failed'));
    await launch();

    expect(await screen.findByText('unreachable')).toBeTruthy();
    expect(saveToken).not.toHaveBeenCalledWith(null);

    GET.mockResolvedValueOnce(ok(me));
    await act(() => session.retryRestore());
    expect(await screen.findByText('signed-in')).toBeTruthy();
  });

  it('keeps the stored token through a server error at launch', async () => {
    GET.mockResolvedValueOnce(status(503));
    await launch();

    expect(await screen.findByText('unreachable')).toBeTruthy();
    expect(saveToken).not.toHaveBeenCalledWith(null);
  });

  it('drops a stored token the server rejects', async () => {
    GET.mockResolvedValueOnce(status(401));
    await launch();

    expect(await screen.findByText('signed-out')).toBeTruthy();
    expect(saveToken).toHaveBeenCalledWith(null);
  });

  it('runs before-sign-out work while the token is still valid, then revokes it', async () => {
    GET.mockResolvedValueOnce(ok(me));
    await launch();
    await screen.findByText('signed-in');

    const order: string[] = [];
    session.beforeSignOut(async () => void order.push('flush'));
    DELETE.mockImplementationOnce(async () => {
      order.push('revoke');
      return { response: { ok: true, status: 204 } };
    });

    await act(() => session.signOut());
    expect(order).toEqual(['flush', 'revoke']);
    expect(await screen.findByText('signed-out')).toBeTruthy();
  });
});
