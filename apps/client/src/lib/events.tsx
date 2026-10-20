import { createContext, use, useEffect, useMemo, type ReactNode } from 'react';
import { AppState, Platform } from 'react-native';

import { api } from './api';
import { EventQueue, type EngagementType } from './event-queue';
import { useSession } from './session';

type Track = (contentId: string, type: EngagementType, value?: number) => void;

const EventsContext = createContext<Track>(() => {});

/** Returns `track(contentId, type, value?)` for recording engagement. */
export function useTrack(): Track {
  return use(EventsContext);
}

// One id per app launch, to group a viewing session's events.
const SESSION_ID = Math.random().toString(36).slice(2) + Date.now().toString(36);

export function EventsProvider({ children }: { children: ReactNode }) {
  const { token, me } = useSession();
  const enabled = !!token && !!me?.onboarded;

  const queue = useMemo(
    () =>
      new EventQueue(async (events, { keepalive }) => {
        const { response } = await api.POST('/api/events', { body: { events }, keepalive });
        if (!response.ok && response.status >= 500) throw new Error('retry later');
      }),
    [],
  );

  useEffect(() => {
    if (!enabled) return;
    queue.start();

    const appState = AppState.addEventListener('change', (state) => {
      if (state !== 'active') void queue.flush({ keepalive: true });
    });

    const onHide = () => {
      if (document.visibilityState === 'hidden') void queue.flush({ keepalive: true });
    };
    if (Platform.OS === 'web') document.addEventListener('visibilitychange', onHide);

    return () => {
      void queue.flush();
      queue.stop();
      appState.remove();
      if (Platform.OS === 'web') document.removeEventListener('visibilitychange', onHide);
    };
  }, [enabled, queue]);

  const track = useMemo<Track>(
    () => (contentId, type, value) => {
      if (!enabled) return;
      queue.push({
        content_id: contentId,
        type,
        value: value ?? null,
        occurred_at: new Date().toISOString(),
        session_id: SESSION_ID,
      });
    },
    [enabled, queue],
  );

  return <EventsContext value={track}>{children}</EventsContext>;
}
