export type EngagementType = 'view_start' | 'watch_progress' | 'complete' | 'skip';

export type ClientEvent = {
  content_id: string;
  type: EngagementType;
  value?: number | null;
  occurred_at: string;
  session_id?: string | null;
  /** The playback episode this event belongs to (ADR 0012). */
  view_id?: string | null;
  /** On view_start: the served For You impression now shown (ADR 0011). */
  impression_id?: string | null;
};

export type SendOptions = { keepalive?: boolean };

type Options = {
  /** Flush as soon as this many events are waiting. */
  flushAt?: number;
  /** Flush on a timer this often. */
  intervalMs?: number;
  /** Most events per request (the API accepts up to 100). */
  maxBatch?: number;
  /** Cap on events held while offline; the oldest are dropped first. */
  maxBuffered?: number;
};

/**
 * Batches engagement events and sends them to `POST /api/events`.
 *
 * Flushes on a timer, when `flushAt` events are waiting, and when the caller
 * asks (app backgrounded / tab hidden). Failed sends are put back at the front
 * and retried on the next flush. The consent version is never sent: the
 * server stamps it (ADR 0007).
 */
export class EventQueue {
  private buffer: ClientEvent[] = [];
  private inFlight: Promise<boolean> | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;
  private readonly flushAt: number;
  private readonly intervalMs: number;
  private readonly maxBatch: number;
  private readonly maxBuffered: number;

  constructor(
    private readonly send: (events: ClientEvent[], options: SendOptions) => Promise<void>,
    options: Options = {},
  ) {
    this.flushAt = options.flushAt ?? 50;
    this.intervalMs = options.intervalMs ?? 10_000;
    this.maxBatch = options.maxBatch ?? 100;
    this.maxBuffered = options.maxBuffered ?? 500;
  }

  get size() {
    return this.buffer.length;
  }

  push(event: ClientEvent) {
    this.buffer.push(event);
    if (this.buffer.length > this.maxBuffered) {
      this.buffer.splice(0, this.buffer.length - this.maxBuffered);
    }
    if (this.buffer.length >= this.flushAt) void this.flush();
  }

  start() {
    if (!this.timer) this.timer = setInterval(() => void this.flush(), this.intervalMs);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /**
   * Sends one batch. Concurrent calls share the in-flight request. Resolves
   * whether that batch was acknowledged (`true` when there was nothing to send).
   */
  flush(options: SendOptions = {}): Promise<boolean> {
    if (this.inFlight) return this.inFlight;
    if (this.buffer.length === 0) return Promise.resolve(true);

    const batch = this.buffer.splice(0, this.maxBatch);
    this.inFlight = this.send(batch, options)
      .then(() => true)
      .catch(() => {
        this.buffer.unshift(...batch);
        return false;
      })
      .finally(() => {
        this.inFlight = null;
      });

    return this.inFlight;
  }

  /**
   * Sends everything buffered, batch by batch, waiting for each to be
   * acknowledged. Resolves `true` once the buffer is empty, or `false` if a
   * send failed (the batch is kept for a later retry). Used before switching
   * personalization mode, so events reach the server under the mode they
   * were recorded in.
   */
  async flushAll(): Promise<boolean> {
    if (this.inFlight && !(await this.inFlight)) return false;
    while (this.buffer.length > 0) {
      if (!(await this.flush())) return false;
    }
    return true;
  }
}
