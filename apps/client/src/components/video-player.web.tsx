// hls.js's documented API is its default export (with static isSupported()).
// eslint-disable-next-line import/no-named-as-default
import Hls from 'hls.js';
import { useEffect, useRef } from 'react';

import type { VideoPlayerProps } from './video-player';

export type { VideoPlayerProps };

/**
 * Web player: a plain <video>. Browsers with native HLS (Safari) get the URL
 * directly; others go through hls.js (Media Source Extensions).
 */
export function VideoPlayer({ uri, active, muted, fit, onTime, onEnded }: VideoPlayerProps) {
  const ref = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const video = ref.current;
    if (!video || !uri) return;

    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = uri;
      return () => {
        video.removeAttribute('src');
        video.load();
      };
    }

    // eslint-disable-next-line import/no-named-as-default-member
    if (Hls.isSupported()) {
      const hls = new Hls();
      hls.loadSource(uri);
      hls.attachMedia(video);
      return () => hls.destroy();
    }
  }, [uri]);

  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    if (active) {
      // Autoplay can be refused until the user interacts; muted autoplay is allowed.
      void video.play().catch(() => undefined);
    } else {
      video.pause();
      video.currentTime = 0;
    }
  }, [active, uri]);

  return (
    <video
      ref={ref}
      data-testid="feed-video"
      playsInline
      muted={muted}
      preload={uri ? 'auto' : 'none'}
      onTimeUpdate={(e) => onTime?.(e.currentTarget.currentTime)}
      onEnded={(e) => {
        const video = e.currentTarget;
        onEnded?.(video.duration);
        if (active) {
          video.currentTime = 0;
          void video.play().catch(() => undefined);
        }
      }}
      style={{
        position: 'absolute',
        inset: 0,
        width: '100%',
        height: '100%',
        objectFit: fit,
        backgroundColor: '#000',
      }}
    />
  );
}
