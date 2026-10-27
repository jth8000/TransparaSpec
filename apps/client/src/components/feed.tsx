import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, FlatList, Platform, Pressable, StyleSheet, Text, View } from 'react-native';

import type { Schemas } from '@/lib/api';
import { colors, space } from '@/theme';

import { FeedItem } from './feed-item';

type Viewable = { index?: number | null; isViewable: boolean };

type Props<T extends Schemas['ContentItem']> = {
  items: T[];
  /** The item that became the visible, playing one. */
  onActive?: (item: T, index: number) => void;
  /** Shows a "Why?" button on each item. */
  onWhy?: (item: T) => void;
  onEndReached: () => void;
  loadingMore: boolean;
  onRefresh: () => void;
  refreshing: boolean;
  empty: React.ReactNode;
};

/**
 * Vertical, one-item-per-screen pager. Only the most-visible item plays;
 * its neighbours preload. Tap toggles sound (web starts muted because
 * browsers block unmuted autoplay).
 */
export function Feed<T extends Schemas['ContentItem']>({
  items,
  onActive,
  onWhy,
  onEndReached,
  loadingMore,
  onRefresh,
  refreshing,
  empty,
}: Props<T>) {
  const [height, setHeight] = useState(0);
  const [activeIndex, setActiveIndex] = useState(0);
  const [muted, setMuted] = useState(Platform.OS === 'web');

  // Must stay the same function for the list's lifetime (FlatList requirement).
  const onViewableItemsChanged = useCallback(({ viewableItems }: { viewableItems: Viewable[] }) => {
    const first = viewableItems.find((v) => v.isViewable);
    if (first?.index != null) setActiveIndex(first.index);
  }, []);

  // Report the visible item (also when a re-rank replaces what's after it).
  const active = items[activeIndex];
  useEffect(() => {
    if (active) onActive?.(active, activeIndex);
  }, [active, activeIndex, onActive]);

  const renderItem = useCallback(
    ({ item, index }: { item: T; index: number }) => (
      <Pressable onPress={() => setMuted((m) => !m)} accessibilityLabel="Toggle sound">
        <FeedItem
          item={item}
          height={height}
          active={index === activeIndex}
          preload={Math.abs(index - activeIndex) === 1}
          muted={muted}
          onWhy={onWhy && (() => onWhy(item))}
        />
      </Pressable>
    ),
    [height, activeIndex, muted, onWhy],
  );

  return (
    <View style={styles.container} onLayout={(e) => setHeight(e.nativeEvent.layout.height)}>
      {height > 0 && (
        <FlatList
          testID="feed"
          data={items}
          keyExtractor={(item) => item.id}
          renderItem={renderItem}
          pagingEnabled
          snapToInterval={height}
          decelerationRate="fast"
          showsVerticalScrollIndicator={false}
          getItemLayout={(_, index) => ({ length: height, offset: height * index, index })}
          windowSize={3}
          initialNumToRender={2}
          maxToRenderPerBatch={2}
          viewabilityConfig={{ itemVisiblePercentThreshold: 60 }}
          onViewableItemsChanged={onViewableItemsChanged}
          onEndReached={onEndReached}
          onEndReachedThreshold={2}
          refreshing={refreshing}
          onRefresh={onRefresh}
          ListEmptyComponent={<View style={[styles.empty, { height }]}>{empty}</View>}
          ListFooterComponent={
            loadingMore ? <ActivityIndicator style={styles.footer} color={colors.text} /> : undefined
          }
        />
      )}
      {muted && items.length > 0 && (
        <View style={styles.mutedBadge} pointerEvents="none">
          <Text style={styles.mutedText}>Tap for sound</Text>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  empty: { alignItems: 'center', justifyContent: 'center', padding: space.xl },
  footer: { padding: space.lg },
  mutedBadge: {
    position: 'absolute',
    // Below the feed header (tabs and Tune).
    top: 64,
    right: space.lg,
    backgroundColor: 'rgba(0,0,0,0.5)',
    paddingHorizontal: space.md,
    paddingVertical: space.xs,
    borderRadius: 999,
  },
  mutedText: { color: colors.text, fontSize: 12 },
});
