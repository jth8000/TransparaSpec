import { useQueryClient } from '@tanstack/react-query';
import { createContext, use, useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';

import { api, setApiToken, unwrap, type Schemas } from './api';
import { loadToken, saveToken } from './token-storage';

type Session = {
  /** True until the stored token has been checked against the API. */
  isLoading: boolean;
  token: string | null;
  me: Schemas['Me'] | null;
  signIn: (session: Schemas['AuthSession']) => Promise<void>;
  signOut: () => Promise<void>;
  setMe: (me: Schemas['Me']) => void;
};

const SessionContext = createContext<Session | null>(null);

export function useSession(): Session {
  const value = use(SessionContext);
  if (!value) throw new Error('useSession must be used inside <SessionProvider>');
  return value;
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [isLoading, setLoading] = useState(true);
  const [token, setToken] = useState<string | null>(null);
  const [me, setMe] = useState<Schemas['Me'] | null>(null);

  const apply = useCallback(async (nextToken: string | null, nextMe: Schemas['Me'] | null) => {
    setApiToken(nextToken);
    await saveToken(nextToken);
    setToken(nextToken);
    setMe(nextMe);
  }, []);

  // Restore a stored session, dropping it if the API no longer accepts it.
  useEffect(() => {
    (async () => {
      const stored = await loadToken();
      if (stored) {
        setApiToken(stored);
        try {
          const current = await unwrap(api.GET('/api/me'));
          setToken(stored);
          setMe(current);
        } catch {
          await apply(null, null);
        }
      }
      setLoading(false);
    })();
  }, [apply]);

  const value = useMemo<Session>(
    () => ({
      isLoading,
      token,
      me,
      setMe,
      signIn: (session) => apply(session.token, session.user),
      signOut: async () => {
        // Best effort: revoke server-side, then forget locally regardless.
        await api.DELETE('/api/auth/session').catch(() => undefined);
        queryClient.clear();
        await apply(null, null);
      },
    }),
    [isLoading, token, me, apply, queryClient],
  );

  return <SessionContext value={value}>{children}</SessionContext>;
}
