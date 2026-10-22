import { useInfiniteQuery } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Feed } from '@/components/feed';
import { TuneSheet } from '@/components/tune-sheet';
import { api, unwrap } from '@/lib/api';
import { useForYouFeed } from '@/lib/feed-session';
import type { ForYouItem } from '@/lib/for-you-state';
import { colors, radius, space } from '@/theme';

type FeedKind = 'for-you' | 'following' | 'latest';

const LABELS: Record<FeedKind, string> = { 'for-you': 'For You', following: 'Following', latest: 'Latest' };

/**
 * For You is ranked by the explainable ranker: every item has a "Why?", and
 * Tune changes the ranking live (the feed re-ranks after the item you're
 * on). Following and Latest are plain reverse-chronological feeds.
 */
export default function FeedScreen() {
  const [kind, setKind] = useState<FeedKind>('for-you');
  const [tuning, setTuning] = useState(false);
  const [focus, setFocus] = useState<string[]>([]);
  const params = useLocalSearchParams<{ tune?: string }>();

  const forYou = useForYouFeed(kind === 'for-you');

  // "Adjust" from a Why sheet lands here with ?tune=<topic slug> (or an
  // empty value for the source controls). Handle each arrival once, during
  // render, then clear it from the URL.
  const [handledTune, setHandledTune] = useState<string | undefined>();
  if (params.tune !== handledTune) {
    setHandledTune(params.tune);
    if (params.tune !== undefined) {
      setKind('for-you');
      setFocus(params.tune ? [params.tune] : []);
      setTuning(true);
    }
  }
  useEffect(() => {
    if (params.tune !== undefined) router.setParams({ tune: undefined });
  }, [params.tune]);

  const chrono = useInfiniteQuery({
    queryKey: ['feed', kind],
    enabled: kind !== 'for-you',
    initialPageParam: null as string | null,
    queryFn: ({ pageParam }) => {
      const query = { cursor: pageParam ?? undefined, limit: 10 };
      return unwrap(
        kind === 'following'
          ? api.GET('/api/feed/following', { params: { query } })
          : api.GET('/api/feed/latest', { params: { query } }),
      );
    },
    getNextPageParam: (last) => last.next_cursor,
  });

  const { at } = forYou;
  const onActive = useCallback(
    (item: ForYouItem) => {
      at(item);
      // The Tune sheet leads with the topics of whatever is on screen.
      setFocus(item.topics.map((t) => t.slug));
    },
    [at],
  );

  const onWhy = useCallback((item: ForYouItem) => router.push(`/why/${item.impression_id}`), []);

  return (
    <View style={styles.container}>
      {kind === 'for-you' ? (
        <Feed
          key={forYou.sessionId ?? 'for-you'}
          items={forYou.items}
          onActive={onActive}
          onWhy={onWhy}
          onEndReached={forYou.loadMore}
          loadingMore={forYou.loading}
          onRefresh={forYou.refresh}
          refreshing={forYou.refreshing}
          empty={
            <Text style={styles.emptyText}>
              {forYou.error ?? (forYou.refreshing ? 'Loading…' : 'Nothing to show yet. Check back soon!')}
            </Text>
          }
        />
      ) : (
        <Feed
          key={kind}
          items={chrono.data?.pages.flatMap((p) => p.items) ?? []}
          onEndReached={() => chrono.hasNextPage && !chrono.isFetchingNextPage && chrono.fetchNextPage()}
          loadingMore={chrono.isFetchingNextPage}
          onRefresh={() => chrono.refetch()}
          refreshing={chrono.isRefetching && !chrono.isFetchingNextPage}
          empty={
            <Text style={styles.emptyText}>
              {chrono.isLoading
                ? 'Loading…'
                : kind === 'following'
                  ? 'Nothing here yet. Follow some creators, or check Latest.'
                  : 'No posts yet. Be the first!'}
            </Text>
          }
        />
      )}

      <SafeAreaView edges={['top']} style={styles.header} pointerEvents="box-none">
        <View style={styles.headerRow} pointerEvents="box-none">
          <View style={styles.toggle}>
            {(Object.keys(LABELS) as FeedKind[]).map((k) => (
              <Pressable
                key={k}
                testID={`feed-tab-${k}`}
                accessibilityRole="tab"
                accessibilityState={{ selected: k === kind }}
                onPress={() => {
                  setKind(k);
                  if (k !== 'for-you') setTuning(false);
                }}
                style={[styles.toggleItem, k === kind && styles.toggleItemOn]}>
                <Text style={[styles.toggleText, k === kind && styles.toggleTextOn]}>{LABELS[k]}</Text>
              </Pressable>
            ))}
          </View>
          {kind === 'for-you' && (
            <Pressable
              onPress={() => setTuning((t) => !t)}
              style={[styles.tune, tuning && styles.toggleItemOn]}
              accessibilityRole="button"
              accessibilityLabel="Tune your feed"
              testID="tune-button">
              <Text style={styles.tuneText}>Tune</Text>
            </Pressable>
          )}
        </View>
      </SafeAreaView>

      {tuning && kind === 'for-you' && (
        <TuneSheet focus={focus} send={forYou.updateSettings} onClose={() => setTuning(false)} />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  header: { position: 'absolute', top: 0, left: 0, right: 0 },
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.sm,
    marginTop: space.sm,
  },
  toggle: {
    flexDirection: 'row',
    backgroundColor: 'rgba(0,0,0,0.45)',
    borderRadius: radius.pill,
    padding: 3,
  },
  toggleItem: { paddingHorizontal: space.md, paddingVertical: space.xs + 2, borderRadius: radius.pill },
  toggleItemOn: { backgroundColor: 'rgba(255,255,255,0.18)' },
  toggleText: { color: colors.textMuted, fontWeight: '600' },
  toggleTextOn: { color: colors.text },
  tune: {
    paddingHorizontal: space.md,
    paddingVertical: space.xs + 5,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(0,0,0,0.45)',
  },
  tuneText: { color: colors.text, fontWeight: '700' },
  emptyText: { color: colors.textMuted, textAlign: 'center', fontSize: 15 },
});
