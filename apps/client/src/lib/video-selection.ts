/** What the Create screen shows about a picked video before it's posted. */
export type PickedVideo = {
  fileName?: string | null;
  /** Milliseconds, when the picker knows it. */
  duration?: number | null;
  width?: number;
  height?: number;
};

const clock = (ms: number) => {
  const total = Math.round(ms / 1000);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
};

/**
 * The picked video's length in milliseconds. expo-image-picker documents
 * `duration` in milliseconds, but its web build reports the <video>
 * element's `duration`, which is in seconds.
 */
export function durationMs(duration: number | null | undefined, platform: string): number | null {
  if (!duration) return null;
  return platform === 'web' ? duration * 1000 : duration;
}

/** "clip.mp4 · 0:12 · 1080×1920", leaving out whatever the picker didn't report. */
export function describeVideo(video: PickedVideo): string {
  return [
    video.fileName || 'Video',
    video.duration ? clock(video.duration) : null,
    video.width && video.height ? `${video.width}×${video.height}` : null,
  ]
    .filter(Boolean)
    .join(' · ');
}
