import { Link } from 'expo-router';
import { useEffect, useRef } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import type { Schemas } from '@/lib/api';
import { useTrack } from '@/lib/events';
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
};

const PROGRESS_EVERY_SECONDS = 5;

/**
 * Vertical (and square/unknown) videos fill the screen; landscape videos are
 * letterboxed so nothing is cropped off the sides — like TikTok/Reels.
 */
export function fitFor(video: { width: number | null; height: number | null }): 'cover' | 'contain' {
  return video.width && video.height && video.width > video.height ? 'contain' : 'cover';
}

/**
 * One full-screen feed entry. Records engagement for the active item:
 * `view_start` when it becomes visible, `watch_progress` every few seconds,
 * `complete` on the first play-through, and `skip` (with seconds watched) if
 * the viewer swipes away before finishing.
 */
export function FeedItem({ item, height, active, preload, muted }: Props) {
  const track = useTrack();
  const watched = useRef({ seconds: 0, completed: false, lastProgressBucket: 0 });

  useEffect(() => {
    if (!active) return;
    watched.current = { seconds: 0, completed: false, lastProgressBucket: 0 };
    track(item.id, 'view_start');

    return () => {
      const w = watched.current;
      if (item.kind === 'short_video' && !w.completed) track(item.id, 'skip', w.seconds);
    };
  }, [active, item.id, item.kind, track]);

  const onTime = (seconds: number) => {
    const w = watched.current;
    w.seconds = Math.max(w.seconds, seconds);
    const bucket = Math.floor(seconds / PROGRESS_EVERY_SECONDS);
    if (bucket > w.lastProgressBucket) {
      w.lastProgressBucket = bucket;
      track(item.id, 'watch_progress', Math.round(seconds * 10) / 10);
    }
  };

  const onEnded = (duration: number) => {
    const w = watched.current;
    if (!w.completed) {
      w.completed = true;
      track(item.id, 'complete', Number.isFinite(duration) ? duration : w.seconds);
    }
  };

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
      </View>
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
  caption: {
    color: colors.text,
    fontSize: 15,
    textShadowColor: 'rgba(0,0,0,0.6)',
    textShadowRadius: 4,
  },
});
