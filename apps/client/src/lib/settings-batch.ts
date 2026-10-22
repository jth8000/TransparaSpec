import type { Schemas } from './api';

export type SettingsChange = Schemas['SettingsChange'];

/** Combines two change sets; later values win, per topic field and source. */
export function mergeChanges(a: SettingsChange, b: SettingsChange): SettingsChange {
  const topics = { ...a.topics };
  for (const [slug, change] of Object.entries(b.topics ?? {})) topics[slug] = { ...topics[slug], ...change };

  return {
    ...(Object.keys(topics).length ? { topics } : {}),
    ...(a.sources || b.sources ? { sources: { ...a.sources, ...b.sources } } : {}),
    ...(b.non_personalized !== undefined
      ? { non_personalized: b.non_personalized }
      : a.non_personalized !== undefined
        ? { non_personalized: a.non_personalized }
        : {}),
  };
}

/**
 * Batches settings changes and sends them once input has been quiet for
 * `delayMs` (150 ms: a slider drag becomes one or a few updates, each
 * re-ranking the feed live, rather than dozens).
 */
export class SettingsBatcher {
  private pending: SettingsChange | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private send: (change: SettingsChange) => void = () => {},
    private readonly delayMs = 150,
  ) {}

  /** Replaces where batches go (e.g. when a component's sender changes). */
  setSender(send: (change: SettingsChange) => void) {
    this.send = send;
  }

  push(change: SettingsChange) {
    this.pending = this.pending ? mergeChanges(this.pending, change) : change;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), this.delayMs);
  }

  /** Sends anything pending now. */
  flush() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const change = this.pending;
    this.pending = null;
    if (change) this.send(change);
  }

  cancel() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.pending = null;
  }
}
