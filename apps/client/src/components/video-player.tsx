import { useEventListener } from 'expo';
import { useVideoPlayer, VideoView } from 'expo-video';
import { useEffect, useRef } from 'react';
import { StyleSheet } from 'react-native';

export type VideoPlayerProps = {
  /** HLS URL, or null to not load anything yet. */
  uri: string | null;
  /** Only the active item plays; others are paused (and preloaded if they have a uri). */
  active: boolean;
  muted: boolean;
  onTime?: (seconds: number) => void;
  /** Fires each time playback reaches the end; the player then restarts from 0. */
  onEnded?: (durationSeconds: number) => void;
};

/**
 * Native player (expo-video). Loops manually so each completion is observable.
 *
 * expo-video's player is an imperative object controlled by assigning
 * properties (`player.muted = …`), which the React Compiler's immutability
 * rule forbids for hook results. This component opts out of the compiler
 * rather than hide those writes.
 */
/* eslint-disable react-hooks/immutability */
export function VideoPlayer({ uri, active, muted, onTime, onEnded }: VideoPlayerProps) {
  'use no memo';
  const player = useVideoPlayer(uri ? { uri, contentType: 'hls' } : null, (p) => {
    p.loop = false;
    p.timeUpdateEventInterval = 1;
  });

  useEffect(() => {
    player.muted = muted;
  }, [player, muted]);

  // Read inside native event callbacks, which may outlive a render.
  const activeRef = useRef(active);

  useEffect(() => {
    activeRef.current = active;
    if (active) {
      player.play();
    } else {
      player.pause();
      player.currentTime = 0;
    }
  }, [player, active]);

  useEventListener(player, 'timeUpdate', ({ currentTime }) => onTime?.(currentTime));

  useEventListener(player, 'playToEnd', () => {
    onEnded?.(player.duration);
    if (activeRef.current) {
      // Seeking to 0 + play() doesn't restart an ended player on Android;
      // replay() is expo-video's API for this.
      player.replay();
      player.play();
    }
  });

  return (
    <VideoView
      player={player}
      style={StyleSheet.absoluteFill}
      contentFit="cover"
      nativeControls={false}
    />
  );
}
/* eslint-enable react-hooks/immutability */
