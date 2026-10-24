import { EventQueue, type ClientEvent } from '../event-queue';

const event = (n: number): ClientEvent => ({
  content_id: `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`,
  type: 'view_start',
  occurred_at: new Date(0).toISOString(),
});

describe('EventQueue', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  it('flushes when flushAt events are waiting', async () => {
    const send = jest.fn().mockResolvedValue(undefined);
    const queue = new EventQueue(send, { flushAt: 3 });

    queue.push(event(1));
    queue.push(event(2));
    expect(send).not.toHaveBeenCalled();

    queue.push(event(3));
    await Promise.resolve();
    expect(send).toHaveBeenCalledWith([event(1), event(2), event(3)], {});
    expect(queue.size).toBe(0);
  });

  it('flushes on the timer once started', async () => {
    const send = jest.fn().mockResolvedValue(undefined);
    const queue = new EventQueue(send, { intervalMs: 1000 });
    queue.start();
    queue.push(event(1));

    jest.advanceTimersByTime(999);
    expect(send).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1);
    expect(send).toHaveBeenCalledTimes(1);
    queue.stop();
  });

  it('caps a batch at maxBatch and sends the rest next time', async () => {
    const send = jest.fn().mockResolvedValue(undefined);
    const queue = new EventQueue(send, { flushAt: 1000, maxBatch: 2 });
    [1, 2, 3].forEach((n) => queue.push(event(n)));

    await queue.flush();
    expect(send).toHaveBeenLastCalledWith([event(1), event(2)], {});
    await queue.flush();
    expect(send).toHaveBeenLastCalledWith([event(3)], {});
  });

  it('puts a failed batch back at the front, in order', async () => {
    const send = jest.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValue(undefined);
    const queue = new EventQueue(send, { flushAt: 1000 });
    queue.push(event(1));
    queue.push(event(2));

    await queue.flush();
    expect(queue.size).toBe(2);

    queue.push(event(3));
    await queue.flush();
    expect(send).toHaveBeenLastCalledWith([event(1), event(2), event(3)], {});
    expect(queue.size).toBe(0);
  });

  it('shares one request between concurrent flushes', async () => {
    let resolve!: () => void;
    const send = jest.fn(() => new Promise<void>((r) => (resolve = r)));
    const queue = new EventQueue(send, { flushAt: 1000 });
    queue.push(event(1));

    const a = queue.flush();
    const b = queue.flush();
    resolve();
    await Promise.all([a, b]);
    expect(send).toHaveBeenCalledTimes(1);
  });

  it('drops the oldest events past maxBuffered', async () => {
    const send = jest.fn().mockResolvedValue(undefined);
    const queue = new EventQueue(send, { flushAt: 1000, maxBuffered: 2 });
    [1, 2, 3].forEach((n) => queue.push(event(n)));

    await queue.flush();
    expect(send).toHaveBeenCalledWith([event(2), event(3)], {});
  });

  it('passes keepalive through for page-hide flushes', async () => {
    const send = jest.fn().mockResolvedValue(undefined);
    const queue = new EventQueue(send);
    queue.push(event(1));

    await queue.flush({ keepalive: true });
    expect(send).toHaveBeenCalledWith([event(1)], { keepalive: true });
  });

  it('flushAll drains every batch and reports success', async () => {
    const send = jest.fn().mockResolvedValue(undefined);
    const queue = new EventQueue(send, { flushAt: 1000, maxBatch: 2 });
    [1, 2, 3, 4, 5].forEach((n) => queue.push(event(n)));

    await expect(queue.flushAll()).resolves.toBe(true);
    expect(send).toHaveBeenCalledTimes(3);
    expect(queue.size).toBe(0);
  });

  it('flushAll reports failure and keeps the unsent batch', async () => {
    const send = jest.fn().mockResolvedValueOnce(undefined).mockRejectedValueOnce(new Error('offline'));
    const queue = new EventQueue(send, { flushAt: 1000, maxBatch: 2 });
    [1, 2, 3].forEach((n) => queue.push(event(n)));

    await expect(queue.flushAll()).resolves.toBe(false);
    expect(queue.size).toBe(1);
  });

  it('flushAll waits for a batch already in flight', async () => {
    let release!: () => void;
    const send = jest
      .fn()
      .mockImplementationOnce(() => new Promise<void>((resolve) => (release = resolve)))
      .mockResolvedValue(undefined);
    const queue = new EventQueue(send, { flushAt: 1000 });
    queue.push(event(1));
    void queue.flush();

    let done = false;
    const all = queue.flushAll().then((ok) => (done = ok));
    await Promise.resolve();
    expect(done).toBe(false);

    release();
    await all;
    expect(done).toBe(true);
  });
});
