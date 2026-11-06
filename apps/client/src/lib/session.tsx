import { useQueryClient } from '@tanstack/react-query';
import { createContext, use, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';

import { api, ApiError, setApiToken, unwrap, type Schemas } from './api';
import { loadToken, saveToken } from './token-storage';

type Session = {
  /** True until the stored token has been checked against the API. */
  isLoading: boolean;
  /**
   * The stored token couldn't be checked (offline, or a server error). It's
   * kept for `retryRestore`; only a 401 means it's no longer valid.
   */
  restoreFailed: boolean;
  retryRestore: () => Promise<void>;
  token: string | null;
  me: Schemas['Me'] | null;
  signIn: (session: Schemas['AuthSession']) => Promise<void>;
  /** Runs the `beforeSignOut` work, revokes the token, then forgets it. */
  signOut: () => Promise<void>;
  /**
   * Registers work that needs the current token and must finish before
   * sign-out revokes it (sending queued events). Returns an unregister function.
   */
  beforeSignOut: (fn: () => Promise<unknown>) => () => void;
  setMe: (me: Schemas['Me']) => void;
};

// The longest sign-out waits for `beforeSignOut` work (e.g. offline sends).
const BEFORE_SIGN_OUT_MS = 3_000;

const SessionContext = createContext<Session | null>(null);

export function useSession(): Session {
  const value = use(SessionContext);
  if (!value) throw new Error('useSession must be used inside <SessionProvider>');
  return value;
}

type Restored = { token: string; me: Schemas['Me'] } | 'none' | 'rejected' | 'unreachable';

/**
 * Checks the stored token against the API. Only a 401 means it's no longer
 * valid; offline or a server error is `unreachable`, and the token is kept
 * so a retry, or the next launch, can still use it.
 */
async function checkStoredToken(): Promise<Restored> {
  const stored = await loadToken();
  if (!stored) return 'none';
  setApiToken(stored);
  try {
    return { token: stored, me: await unwrap(api.GET('/api/me')) };
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) return 'rejected';
    setApiToken(null);
    return 'unreachable';
  }
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [isLoading, setLoading] = useState(true);
  const [restoreFailed, setRestoreFailed] = useState(false);
  const [token, setToken] = useState<string | null>(null);
  const [me, setMe] = useState<Schemas['Me'] | null>(null);
  const beforeSignOutWork = useRef(new Set<() => Promise<unknown>>());

  const apply = useCallback(async (nextToken: string | null, nextMe: Schemas['Me'] | null) => {
    setApiToken(nextToken);
    await saveToken(nextToken);
    setToken(nextToken);
    setMe(nextMe);
  }, []);

  const settle = useCallback(
    async (result: Restored) => {
      if (result === 'rejected') await apply(null, null);
      else if (typeof result === 'object') {
        setToken(result.token);
        setMe(result.me);
      }
      setRestoreFailed(result === 'unreachable');
      setLoading(false);
    },
    [apply],
  );

  useEffect(() => {
    (async () => settle(await checkStoredToken()))();
  }, [settle]);

  const retryRestore = useCallback(async () => {
    setLoading(true);
    await settle(await checkStoredToken());
  }, [settle]);

  const beforeSignOut = useCallback((fn: () => Promise<unknown>) => {
    beforeSignOutWork.current.add(fn);
    return () => void beforeSignOutWork.current.delete(fn);
  }, []);

  const value = useMemo<Session>(
    () => ({
      isLoading,
      restoreFailed,
      retryRestore,
      token,
      me,
      setMe,
      beforeSignOut,
      signIn: (session) => apply(session.token, session.user),
      signOut: async () => {
        // Work that needs this token first (queued events), but never let
        // it hold up signing out for long.
        const work = [...beforeSignOutWork.current].map((fn) => fn().catch(() => undefined));
        let timer: ReturnType<typeof setTimeout> | undefined;
        await Promise.race([
          Promise.all(work),
          new Promise((resolve) => {
            timer = setTimeout(resolve, BEFORE_SIGN_OUT_MS);
          }),
        ]);
        clearTimeout(timer);
        // Best effort: revoke server-side, then forget locally regardless.
        await api.DELETE('/api/auth/session').catch(() => undefined);
        queryClient.clear();
        await apply(null, null);
      },
    }),
    [isLoading, restoreFailed, retryRestore, token, me, apply, beforeSignOut, queryClient],
  );

  return <SessionContext value={value}>{children}</SessionContext>;
}
