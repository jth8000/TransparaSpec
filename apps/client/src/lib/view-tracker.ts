import { randomUUID } from 'expo-crypto';

import type { EngagementType } from './event-queue';

export type TrackOptions = { value?: number; viewId?: string; impressionId?: string };
export type Track = (contentId: string, type: EngagementType, options?: TrackOptions) => void;

const PROGRESS_EVERY_SECONDS = 5;

/**
 * One *view*: a single playback episode of an item, from becoming the
 * active item until it's swiped away (ADR 0012). Every event it records
 * carries the same `view_id`; the server learns interests once per view.
 *
 * Seconds are reported **cumulatively across loops** ("played so far in
 * this view"), so the server can merge batches with a simple max and tell a
 * looped video from a single watch.
 *
 *   - `view_start` on creation
 *   - `watch_progress` every 5 s played
 *   - `complete` each time playback reaches the end
 *   - `skip` on `end()` if the video never finished
 */
export class ViewTracker {
  readonly viewId: string;
  private base = 0; // seconds played in finished loops
  private position = 0; // furthest point reached in the current loop
  private completed = false;
  private lastBucket = 0;

  /**
   * `impressionId` (For You items) marks the served impression as actually
   * shown — exposure (ADR 0011).
   */
  constructor(
    private readonly contentId: string,
    private readonly isVideo: boolean,
    private readonly track: Track,
    options: { impressionId?: string; newId?: () => string } = {},
  ) {
    this.viewId = (options.newId ?? randomUUID)();
    this.track(contentId, 'view_start', {
      viewId: this.viewId,
      ...(options.impressionId ? { impressionId: options.impressionId } : {}),
    });
  }

  /** Seconds played so far in this view, across loops. */
  get played() {
    return this.base + this.position;
  }

  /** Playback time update (position within the current loop). */
  time(seconds: number) {
    this.position = Math.max(this.position, seconds);
    const bucket = Math.floor(this.played / PROGRESS_EVERY_SECONDS);
    if (bucket > this.lastBucket) {
      this.lastBucket = bucket;
      this.emit('watch_progress');
    }
  }

  /** Playback reached the end; the player loops back to 0. */
  ended(durationSeconds: number) {
    this.base += Number.isFinite(durationSeconds) && durationSeconds > 0 ? durationSeconds : this.position;
    this.position = 0;
    this.completed = true;
    this.emit('complete');
  }

  /** The item stopped being the active item. */
  end() {
    if (this.isVideo && !this.completed) this.emit('skip');
  }

  private emit(type: EngagementType) {
    this.track(this.contentId, type, { value: Math.round(this.played * 10) / 10, viewId: this.viewId });
  }
}
