import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useCallback, useEffect, useState } from 'react';

import { api, unwrap, type Schemas } from './api';
import { mergeChanges, SettingsBatcher, subtractChange, type SettingsChange } from './settings-batch';

export type AlgorithmSettings = Schemas['AlgorithmSettings'];
export type TopicControl = { multiplier: number; hard_off: boolean };

export const SETTINGS_KEY = ['algorithm-settings'] as const;

export function useAlgorithmSettings() {
  return useQuery({
    queryKey: SETTINGS_KEY,
    queryFn: () => unwrap(api.GET('/api/algorithm/settings')),
  });
}

/**
 * A topic's effective control, mirroring the server: its own entry, else its
 * tier-1 parent's multiplier, else the default (1×, on). Hard-off on a
 * parent covers the child.
 */
export function topicControl(
  settings: AlgorithmSettings | undefined,
  pending: SettingsChange,
  slug: string,
  parent?: string | null,
): TopicControl & { inherited: boolean } {
  const own = (s: string) => {
    const saved = settings?.topics.find((t) => t.slug === s);
    const p = pending.topics?.[s];
    if (!saved && !p) return undefined;
    return {
      multiplier: p?.multiplier ?? saved?.multiplier ?? 1,
      hard_off: p?.hard_off ?? saved?.hard_off ?? false,
    };
  };
  const mine = own(slug);
  const parents = parent ? own(parent) : undefined;
  return {
    multiplier: mine?.multiplier ?? parents?.multiplier ?? 1,
    hard_off: (mine?.hard_off ?? false) || (parents?.hard_off ?? false),
    inherited: !mine && !!parents,
  };
}

export function sourceMultiplier(
  settings: AlgorithmSettings | undefined,
  pending: SettingsChange,
  source: string,
) {
  return pending.sources?.[source] ?? settings?.sources.find((s) => s.source === source)?.multiplier ?? 1;
}

/**
 * Optimistic, batched settings edits. `change()` updates the UI at once and
 * sends merged changes after 150 ms of quiet via `send` (the feed channel on
 * the feed, REST elsewhere); then the saved settings are re-read.
 */
export function useSettingsEditor(send: (change: SettingsChange) => Promise<unknown>) {
  const queryClient = useQueryClient();
  const [pending, setPending] = useState<SettingsChange>({});
  const [error, setError] = useState<string>();
  const [batcher] = useState(() => new SettingsBatcher());

  useEffect(() => {
    // The batcher waits for this promise before sending the next change.
    batcher.setSender((change) =>
      send(change)
        .then(() => setError(undefined))
        .catch((e: unknown) => setError(e instanceof Error ? e.message : 'Could not save'))
        .finally(async () => {
          await queryClient.invalidateQueries({ queryKey: SETTINGS_KEY });
          // Only what this write carried is settled; newer edits stay shown.
          setPending((p) => subtractChange(p, change));
        }),
    );
  }, [batcher, send, queryClient]);

  // Send anything still pending when the editor goes away.
  useEffect(() => () => void batcher.flush(), [batcher]);

  const change = useCallback(
    (c: SettingsChange) => {
      setPending((p) => mergeChanges(p, c));
      batcher.push(c);
    },
    [batcher],
  );

  return { pending, change, error, flush: useCallback(() => batcher.flush(), [batcher]) };
}

/** REST sender for screens without a feed channel. */
export const saveSettings = (change: SettingsChange) =>
  unwrap(api.PUT('/api/algorithm/settings', { body: change }));
