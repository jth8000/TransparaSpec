import { useInfiniteQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Feed } from '@/components/feed';
import { api, unwrap } from '@/lib/api';
import { colors, radius, space } from '@/theme';

type FeedKind = 'following' | 'latest';

const LABELS: Record<FeedKind, string> = { following: 'Following', latest: 'Latest' };

/**
 * Phase 0 feeds are non-personalized: Following (accounts you follow) and
 * Latest (everyone, newest first). The explainable "For You" ranker arrives
 * in Phase 1.
 */
export default function FeedScreen() {
  const [kind, setKind] = useState<FeedKind>('following');

  const query = useInfiniteQuery({
    queryKey: ['feed', kind],
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

  const items = query.data?.pages.flatMap((p) => p.items) ?? [];

  return (
    <View style={styles.container}>
      <Feed
        key={kind}
        items={items}
        onEndReached={() => query.hasNextPage && !query.isFetchingNextPage && query.fetchNextPage()}
        loadingMore={query.isFetchingNextPage}
        onRefresh={() => query.refetch()}
        refreshing={query.isRefetching && !query.isFetchingNextPage}
        empty={
          <Text style={styles.emptyText}>
            {query.isLoading
              ? 'Loading…'
              : kind === 'following'
                ? 'Nothing here yet. Follow some creators, or check Latest.'
                : 'No posts yet. Be the first!'}
          </Text>
        }
      />

      <SafeAreaView edges={['top']} style={styles.header} pointerEvents="box-none">
        <View style={styles.toggle}>
          {(Object.keys(LABELS) as FeedKind[]).map((k) => (
            <Pressable
              key={k}
              testID={`feed-tab-${k}`}
              accessibilityRole="tab"
              accessibilityState={{ selected: k === kind }}
              onPress={() => setKind(k)}
              style={[styles.toggleItem, k === kind && styles.toggleItemOn]}>
              <Text style={[styles.toggleText, k === kind && styles.toggleTextOn]}>{LABELS[k]}</Text>
            </Pressable>
          ))}
        </View>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  header: { position: 'absolute', top: 0, left: 0, right: 0, alignItems: 'center' },
  toggle: {
    flexDirection: 'row',
    marginTop: space.sm,
    backgroundColor: 'rgba(0,0,0,0.45)',
    borderRadius: radius.pill,
    padding: 3,
  },
  toggleItem: { paddingHorizontal: space.lg, paddingVertical: space.xs + 2, borderRadius: radius.pill },
  toggleItemOn: { backgroundColor: 'rgba(255,255,255,0.18)' },
  toggleText: { color: colors.textMuted, fontWeight: '600' },
  toggleTextOn: { color: colors.text },
  emptyText: { color: colors.textMuted, textAlign: 'center', fontSize: 15 },
});
