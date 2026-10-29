import { createApiClient } from '@tspec/api-schema';
import { createContext, use, useEffect, useMemo, type ReactNode } from 'react';
import { AppState, Platform } from 'react-native';

import { API_URL } from './config';
import { EventQueue } from './event-queue';
import { useSession } from './session';
import type { Track } from './view-tracker';

type Events = { track: Track; flushAll: () => Promise<boolean> };

const EventsContext = createContext<Events>({ track: () => {}, flushAll: async () => true });

/** Returns `track(contentId, type, { value?, viewId?, impressionId? })` for recording engagement. */
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
  const { token, me, beforeSignOut } = useSession();
  const enabled = !!token && !!me?.onboarded;

  // One queue per signed-in token, sending with that token only. Events
  // queued by one account (say, while offline) can then never be sent under
  // the next account to sign in on this device; a token that's been revoked
  // gets a 4xx, and its leftovers are dropped.
  const queue = useMemo(() => {
    if (!token) return null;
    const client = createApiClient(API_URL, () => token);
    return new EventQueue(async (events, { keepalive }) => {
      const { response } = await client.POST('/api/events', { body: { events }, keepalive });
      if (!response.ok && response.status >= 500) throw new Error('retry later');
    });
  }, [token]);

  // Send what's queued before sign-out revokes the token.
  useEffect(() => {
    if (queue) return beforeSignOut(() => queue.flushAll());
  }, [queue, beforeSignOut]);

  useEffect(() => {
    if (!enabled || !queue) return;
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
        if (!enabled || !queue) return;
        queue.push({
          content_id: contentId,
          type,
          value: options.value ?? null,
          occurred_at: new Date().toISOString(),
          session_id: SESSION_ID,
          view_id: options.viewId ?? null,
          ...(options.impressionId ? { impression_id: options.impressionId } : {}),
        });
      },
      flushAll: async () => (queue ? queue.flushAll() : true),
    }),
    [enabled, queue],
  );

  return <EventsContext value={events}>{children}</EventsContext>;
}
