import { Link } from 'expo-router';
import { useEffect, useRef } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { Schemas } from '@/lib/api';
import { useTrack } from '@/lib/events';
import { ViewTracker } from '@/lib/view-tracker';
import { colors, radius, space } from '@/theme';

import { VideoPlayer } from './video-player';

type Props = {
  item: Schemas['ContentItem'];
  height: number;
  /** The visible item: plays and records engagement. */
  active: boolean;
  /** Near the visible item: preloads its video. */
  preload: boolean;
  muted: boolean;
  /** Shows a "Why?" button (For You items, which carry an impression). */
  onWhy?: () => void;
};

/**
 * Vertical (and square/unknown) videos fill the screen; landscape videos are
 * letterboxed so nothing is cropped off the sides — like TikTok/Reels.
 */
export function fitFor(video: { width: number | null; height: number | null }): 'cover' | 'contain' {
  return video.width && video.height && video.width > video.height ? 'contain' : 'cover';
}

/**
 * One full-screen feed entry. While it's the active item it records one
 * *view* (see `ViewTracker`): `view_start`, cumulative `watch_progress`,
 * `complete` on each loop, and `skip` if swiped away before finishing.
 */
export function FeedItem({ item, height, active, preload, muted, onWhy }: Props) {
  const track = useTrack();
  const view = useRef<ViewTracker | null>(null);
  const impressionId = 'impression_id' in item ? (item.impression_id as string) : undefined;

  useEffect(() => {
    if (!active) return;
    const tracker = new ViewTracker(item.id, item.kind === 'short_video', track, { impressionId });
    view.current = tracker;
    return () => {
      tracker.end();
      if (view.current === tracker) view.current = null;
    };
  }, [active, item.id, item.kind, impressionId, track]);

  const onTime = (seconds: number) => view.current?.time(seconds);
  const onEnded = (duration: number) => view.current?.ended(duration);

  return (
    <View style={[styles.container, { height }]} testID={`feed-item-${item.id}`}>
      {item.video ? (
        <VideoPlayer
          uri={preload || active ? item.video.playback_url : null}
          active={active}
          muted={muted}
          fit={fitFor(item.video)}
          onTime={onTime}
          onEnded={onEnded}
        />
      ) : (
        <View style={styles.textCard}>
          <Text style={styles.textBody}>{item.text?.body}</Text>
        </View>
      )}

      <View style={styles.overlay} pointerEvents="box-none">
        <Link href={`/u/${item.author.handle}`} style={styles.handle}>
          @{item.author.handle}
        </Link>
        {item.caption ? <Text style={styles.caption}>{item.caption}</Text> : null}
        {item.topics.length > 0 && (
          <Text style={styles.topics} numberOfLines={1}>
            {item.topics.map((t) => `#${t.name}`).join('  ')}
          </Text>
        )}
      </View>

      {onWhy && (
        <Pressable
          onPress={onWhy}
          style={styles.why}
          accessibilityRole="button"
          accessibilityLabel="Why am I seeing this?"
          testID="why-button">
          <Text style={styles.whyText}>Why?</Text>
        </Pressable>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { width: '100%', backgroundColor: '#000', overflow: 'hidden' },
  textCard: {
    flex: 1,
    justifyContent: 'center',
    padding: space.xxl,
    backgroundColor: colors.surface,
  },
  textBody: { color: colors.text, fontSize: 26, lineHeight: 34, fontWeight: '600' },
  overlay: {
    position: 'absolute',
    left: space.lg,
    right: space.lg,
    bottom: space.xl,
    gap: space.xs,
  },
  handle: {
    alignSelf: 'flex-start',
    color: colors.text,
    fontWeight: '700',
    fontSize: 16,
    paddingVertical: 2,
    paddingHorizontal: space.sm,
    borderRadius: radius.sm,
    backgroundColor: 'rgba(0,0,0,0.35)',
    overflow: 'hidden',
  },
  topics: { color: colors.textMuted, fontSize: 13 },
  why: {
    position: 'absolute',
    right: space.lg,
    bottom: space.xl,
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(0,0,0,0.55)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.25)',
  },
  whyText: { color: colors.text, fontWeight: '700', fontSize: 14 },
  caption: {
    color: colors.text,
    fontSize: 15,
    textShadowColor: 'rgba(0,0,0,0.6)',
    textShadowRadius: 4,
  },
});
