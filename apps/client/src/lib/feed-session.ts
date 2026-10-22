import { Socket, type Channel } from 'phoenix';
import { useCallback, useEffect, useReducer, useRef, useState } from 'react';

import { api, unwrap, type Schemas } from './api';
import { SOCKET_URL } from './config';
import {
  appendPage,
  applyRerank,
  initialForYou,
  type ForYouItem,
  type ForYouState,
  type Rerank,
} from './for-you-state';
import { useSession } from './session';
import type { SettingsChange } from './settings-batch';

type Action =
  | { type: 'page'; page: Schemas['ForYouPage'] }
  | { type: 'reset'; page: Schemas['ForYouPage'] }
  | { type: 'rerank'; push: Rerank };

function reducer(state: ForYouState, action: Action): ForYouState {
  switch (action.type) {
    case 'page':
      return appendPage(state, action.page);
    case 'reset':
      return appendPage(initialForYou, action.page);
    case 'rerank':
      return applyRerank(state, action.push);
  }
}

const PAGE_SIZE = 10;

/**
 * The For You feed (ADR 0011): pages from `GET /api/feed/for-you`, plus the
 * feed session's channel for live control.
 *
 *   - `at(item)` tells the server which item is on screen, so a re-rank
 *     never replaces it or anything before it
 *   - `updateSettings(change)` sends a settings change over the channel; the
 *     server saves it and pushes the re-ranked tail (`feed_reranked`)
 *   - pushes older than the revision we hold are dropped (`applyRerank`)
 */
export function useForYouFeed(enabled: boolean) {
  const { token } = useSession();
  const [state, dispatch] = useReducer(reducer, initialForYou);
  const [loading, setLoading] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string>();

  // Read by callbacks that outlive a render.
  const stateRef = useRef(state);
  const loadingRef = useRef(false);
  const channelRef = useRef<Channel | null>(null);
  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  const load = useCallback(async (fresh: boolean) => {
    if (loadingRef.current) return;
    loadingRef.current = true;
    if (fresh) setRefreshing(true);
    else setLoading(true);
    try {
      const session = fresh ? undefined : (stateRef.current.sessionId ?? undefined);
      const page = await unwrap(
        api.GET('/api/feed/for-you', { params: { query: { session, limit: PAGE_SIZE } } }),
      );
      dispatch({ type: fresh ? 'reset' : 'page', page });
      setError(undefined);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load your feed');
    } finally {
      loadingRef.current = false;
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    if (enabled && !stateRef.current.sessionId) void load(true);
  }, [enabled, load]);

  const sessionId = state.sessionId;
  useEffect(() => {
    if (!enabled || !token || !sessionId) return;
    const socket = new Socket(SOCKET_URL, { params: { token } });
    socket.connect();
    const channel = socket.channel(`feed_session:${sessionId}`);
    channel.on('feed_reranked', (push: Rerank) => dispatch({ type: 'rerank', push }));
    channel.join();
    channelRef.current = channel;
    return () => {
      channelRef.current = null;
      channel.leave();
      socket.disconnect();
    };
  }, [enabled, token, sessionId]);

  const at = useCallback((item: ForYouItem) => {
    channelRef.current?.push('at', { impression_id: item.impression_id, rev: stateRef.current.rev });
  }, []);

  const updateSettings = useCallback(
    (change: SettingsChange) =>
      new Promise<{ settings_version: number }>((resolve, reject) => {
        const channel = channelRef.current;
        if (!channel) return reject(new Error('Not connected'));
        channel
          .push('update_settings', change)
          .receive('ok', resolve)
          .receive('error', (e: { message?: string }) => reject(new Error(e.message ?? 'Invalid settings')))
          .receive('timeout', () => reject(new Error('Timed out')));
      }),
    [],
  );

  return {
    items: state.items,
    sessionId,
    rev: state.rev,
    loading,
    refreshing,
    error,
    loadMore: useCallback(() => void load(false), [load]),
    refresh: useCallback(() => void load(true), [load]),
    at,
    updateSettings,
  };
}
