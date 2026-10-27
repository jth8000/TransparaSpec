import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ActivityIndicator, FlatList, Platform, Pressable, StyleSheet, Text, View } from 'react-native';

import type { Schemas } from '@/lib/api';
import { colors, space } from '@/theme';

import { FeedItem } from './feed-item';

type Viewable = { index?: number | null; isViewable: boolean };

// How long a scroll position must hold before it counts as where the list rests.
const SETTLE_MS = 150;
// After a restore, the offset must hold this many frames in a row (about
// 0.2 s) before tracking resumes; give up after MAX_RESTORE_FRAMES.
const HOLD_FRAMES = 12;
const MAX_RESTORE_FRAMES = 90;

type Props<T extends Schemas['ContentItem']> = {
  items: T[];
  /** The item that became the visible, playing one. */
  onActive?: (item: T, index: number) => void;
  /** Shows a "Why?" button on each item. */
  onWhy?: (item: T) => void;
  /**
   * False while the screen is covered (a modal, another tab). The list keeps
   * its place and doesn't report position changes until it's visible again.
   */
  visible?: boolean;
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
  visible = true,
  onEndReached,
  loadingMore,
  onRefresh,
  refreshing,
  empty,
}: Props<T>) {
  const [height, setHeight] = useState(0);
  const [activeIndex, setActiveIndex] = useState(0);
  const [muted, setMuted] = useState(Platform.OS === 'web');

  const listRef = useRef<FlatList<T>>(null);
  // When the screen is covered (a modal, another tab), web hides it with
  // display:none and the browser resets the list's scroll to 0. That reset
  // must not move the active item (it would report a wrong position to the
  // feed session and replay an old video), so while hidden, tracking is
  // frozen, and when shown again the list scrolls back to where it was.
  const frozen = useRef(false);
  // Where the list rests, saved only once a scroll has settled for
  // SETTLE_MS. The browser's reset to 0 arrives as an ordinary-looking scroll
  // event just *before* the screen is hidden; the hide follows within
  // milliseconds and cancels it, so the reset never becomes the saved place.
  // (Not activeIndex: visibility is reported late and can lag the scroll.)
  const offsetRef = useRef(0);
  const pending = useRef<ReturnType<typeof setTimeout> | null>(null);

  const freeze = () => {
    frozen.current = true;
    if (pending.current) clearTimeout(pending.current);
    pending.current = null;
  };

  // Detecting "hidden" from the DOM is reliable whatever order the
  // navigator's re-render and the scroll events happen in.
  const isHidden = () => {
    if (Platform.OS !== 'web') return false;
    const node = listRef.current?.getScrollableNode() as HTMLElement | undefined;
    return !!node && node.offsetParent === null;
  };

  // While scrolled to 0 the list only rendered its first items, so at first
  // the page may be too short to reach the old offset (the browser clamps
  // it), and CSS scroll-snap can only snap to cells that are rendered (it
  // snaps the restored offset back to the nearest one). So hold the offset
  // for a short while, re-applying it each frame, until the list has
  // rendered cells around it; then resume tracking.
  const restore = () => {
    if (!frozen.current || isHidden()) return;
    const target = offsetRef.current;
    let frames = 0;
    let steady = 0;
    const hold = () =>
      requestAnimationFrame(() => {
        const node = listRef.current?.getScrollableNode() as HTMLElement | undefined;
        if (!node || Math.abs(node.scrollTop - target) >= 2) {
          listRef.current?.scrollToOffset({ offset: target, animated: false });
          steady = 0;
        } else {
          steady += 1;
        }
        frames += 1;
        if (steady >= HOLD_FRAMES || frames >= MAX_RESTORE_FRAMES) frozen.current = false;
        else hold();
      });
    hold();
  };

  useLayoutEffect(() => {
    if (!visible) freeze();
    else requestAnimationFrame(restore);
    // restore reads refs only; re-run on visibility changes alone.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visible]);

  // Must stay the same function for the list's lifetime (FlatList requirement).
  const onViewableItemsChanged = useCallback(({ viewableItems }: { viewableItems: Viewable[] }) => {
    if (frozen.current) return;
    const first = viewableItems.find((v) => v.isViewable);
    if (first?.index != null) setActiveIndex(first.index);
  }, []);

  const onScroll = (y: number) => {
    if (isHidden()) return freeze();
    if (frozen.current) return;
    if (pending.current) clearTimeout(pending.current);
    pending.current = setTimeout(() => {
      pending.current = null;
      if (!frozen.current) offsetRef.current = y;
    }, SETTLE_MS);
  };

  // A hidden screen measures 0 tall: keep the last real height so the list
  // stays mounted rather than remounting at the top.
  const onLayout = (h: number) => {
    if (h === 0) return freeze();
    setHeight(h);
    restore();
  };

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
    <View
      style={styles.container}
      // A covered screen (e.g. under the Why modal on web) measures 0 tall.
      onLayout={(e) => onLayout(e.nativeEvent.layout.height)}>
      {height > 0 && (
        <FlatList
          ref={listRef}
          testID="feed"
          onScroll={(e) => onScroll(e.nativeEvent.contentOffset.y)}
          scrollEventThrottle={16}
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
