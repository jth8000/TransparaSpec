import { createContext, use, useEffect, useMemo, type ReactNode } from 'react';
import { AppState, Platform } from 'react-native';

import { api } from './api';
import { EventQueue } from './event-queue';
import { useSession } from './session';
import type { Track } from './view-tracker';

type Events = { track: Track; flushAll: () => Promise<boolean> };

const EventsContext = createContext<Events>({ track: () => {}, flushAll: async () => true });

/** Returns `track(contentId, type, { value?, viewId? })` for recording engagement. */
export function useTrack(): Track {
  return use(EventsContext).track;
}

/**
 * Returns `flushAll()`: sends every queued event and resolves `true` once the
 * server has acknowledged them all. Call it before changing personalization
 * mode (ADR 0012).
 */
export function useFlushEvents(): () => Promise<boolean> {
  return use(EventsContext).flushAll;
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

  const events = useMemo<Events>(
    () => ({
      track: (contentId, type, options = {}) => {
        if (!enabled) return;
        queue.push({
          content_id: contentId,
          type,
          value: options.value ?? null,
          occurred_at: new Date().toISOString(),
          session_id: SESSION_ID,
          view_id: options.viewId ?? null,
        });
      },
      flushAll: () => queue.flushAll(),
    }),
    [enabled, queue],
  );

  return <EventsContext value={events}>{children}</EventsContext>;
}
