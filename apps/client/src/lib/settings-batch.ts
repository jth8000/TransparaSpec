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
 * Removes from `pending` every field a sent change carried *with the same
 * value*: once that change is acknowledged it's no longer pending. A field
 * edited again since then (a different value) stays pending.
 */
export function subtractChange(pending: SettingsChange, sent: SettingsChange): SettingsChange {
  const topics: NonNullable<SettingsChange['topics']> = {};
  for (const [slug, change] of Object.entries(pending.topics ?? {})) {
    const acked = sent.topics?.[slug] ?? {};
    const rest = Object.fromEntries(
      Object.entries(change).filter(([k, v]) => acked[k as keyof typeof acked] !== v),
    ) as typeof change;
    if (Object.keys(rest).length) topics[slug] = rest;
  }

  const sources = Object.fromEntries(
    Object.entries(pending.sources ?? {}).filter(([k, v]) => sent.sources?.[k] !== v),
  );

  return {
    ...(Object.keys(topics).length ? { topics } : {}),
    ...(Object.keys(sources).length ? { sources } : {}),
    ...(pending.non_personalized !== undefined && pending.non_personalized !== sent.non_personalized
      ? { non_personalized: pending.non_personalized }
      : {}),
  };
}

/**
 * Batches settings changes and sends them once input has been quiet for
 * `delayMs` (150 ms: a slider drag becomes one or a few updates, each
 * re-ranking the feed live, rather than dozens).
 *
 * Writes are serialized: at most one is in flight, and later edits wait for
 * it, so the server applies them in the order they were made (an older
 * value can never land last).
 */
export class SettingsBatcher {
  private pending: SettingsChange | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private inFlight: Promise<void> | null = null;
  private flushWhenIdle = false;

  constructor(
    private send: (change: SettingsChange) => Promise<unknown> | void = () => {},
    private readonly delayMs = 150,
  ) {}

  /** Replaces where batches go (e.g. when a component's sender changes). */
  setSender(send: (change: SettingsChange) => Promise<unknown> | void) {
    this.send = send;
  }

  push(change: SettingsChange) {
    this.pending = this.pending ? mergeChanges(this.pending, change) : change;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.flush(), this.delayMs);
  }

  /** Sends anything pending — now, or as soon as the write in flight finishes. */
  flush(): Promise<void> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;

    if (this.inFlight) {
      this.flushWhenIdle = true;
      return this.inFlight;
    }

    const change = this.pending;
    this.pending = null;
    if (!change) return Promise.resolve();

    // Send now (synchronously); then wait for it before the next one.
    let result: Promise<unknown> | void;
    try {
      result = this.send(change);
    } catch {
      result = undefined;
    }

    this.inFlight = Promise.resolve(result)
      .then(
        () => undefined,
        () => undefined,
      )
      .finally(() => {
        this.inFlight = null;
        // Edits that came in meanwhile go next, unless their quiet period
        // is still running (its timer will flush them).
        if (this.pending && (this.flushWhenIdle || this.timer === null)) void this.flush();
        this.flushWhenIdle = false;
      });

    return this.inFlight;
  }

  cancel() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.pending = null;
  }
}
