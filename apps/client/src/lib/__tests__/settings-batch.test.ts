import { mergeChanges, SettingsBatcher, subtractChange } from '../settings-batch';

describe('mergeChanges', () => {
  it('merges per topic field and per source; later wins', () => {
    expect(
      mergeChanges(
        { topics: { cooking: { multiplier: 1.5 } }, sources: { fresh: 2 } },
        {
          topics: { cooking: { hard_off: true }, travel: { multiplier: 0 } },
          sources: { fresh: 1, trending: 0 },
        },
      ),
    ).toEqual({
      topics: { cooking: { multiplier: 1.5, hard_off: true }, travel: { multiplier: 0 } },
      sources: { fresh: 1, trending: 0 },
    });
  });

  it('keeps non_personalized from whichever set has it', () => {
    expect(mergeChanges({ non_personalized: true }, {})).toEqual({ non_personalized: true });
    expect(mergeChanges({ non_personalized: true }, { non_personalized: false })).toEqual({
      non_personalized: false,
    });
  });
});

describe('SettingsBatcher', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  it('sends one merged change after 150 ms of quiet', () => {
    const send = jest.fn();
    const b = new SettingsBatcher(send);
    for (const m of [1.1, 1.3, 1.6, 2]) {
      b.push({ topics: { cooking: { multiplier: m } } });
      jest.advanceTimersByTime(100);
    }
    expect(send).not.toHaveBeenCalled();

    jest.advanceTimersByTime(50);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send).toHaveBeenCalledWith({ topics: { cooking: { multiplier: 2 } } });
  });

  it('flush sends immediately; cancel drops pending changes', () => {
    const send = jest.fn();
    const b = new SettingsBatcher(send);
    b.push({ sources: { fresh: 0 } });
    b.flush();
    expect(send).toHaveBeenCalledTimes(1);

    b.push({ sources: { fresh: 2 } });
    b.cancel();
    jest.advanceTimersByTime(1000);
    expect(send).toHaveBeenCalledTimes(1);
  });

  it('serializes writes: a later edit waits for the one in flight and lands last', async () => {
    const sent: unknown[] = [];
    let release!: () => void;
    const send = jest.fn((change) => {
      sent.push(change);
      // The first request is slow; later ones answer at once.
      return sent.length === 1 ? new Promise<void>((r) => (release = r)) : Promise.resolve();
    });
    const b = new SettingsBatcher(send);

    b.push({ topics: { cooking: { multiplier: 1.5 } } });
    jest.advanceTimersByTime(150); // A goes out and hangs
    await Promise.resolve();
    b.push({ topics: { cooking: { multiplier: 0.5 } } });
    jest.advanceTimersByTime(150); // B's quiet period ends while A is in flight
    await Promise.resolve();
    expect(send).toHaveBeenCalledTimes(1);

    release();
    for (let i = 0; i < 5; i++) await Promise.resolve();
    expect(sent).toEqual([
      { topics: { cooking: { multiplier: 1.5 } } },
      { topics: { cooking: { multiplier: 0.5 } } },
    ]);
  });
});

describe('SettingsBatcher barriers (reset)', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  const deferred = () => {
    let resolve!: () => void;
    const promise = new Promise<void>((r) => (resolve = r));
    return { promise, resolve };
  };
  const ticks = async (n = 6) => {
    for (let i = 0; i < n; i++) await Promise.resolve();
  };

  it('a reset drops an edit still in its quiet period', async () => {
    const log: string[] = [];
    const b = new SettingsBatcher((c) => {
      log.push(`save ${JSON.stringify(c)}`);
    });

    b.push({ topics: { cooking: { multiplier: 2 } } });
    await b.supersede(async () => {
      log.push('reset');
    });
    jest.advanceTimersByTime(1000);
    await ticks();

    expect(log).toEqual(['reset']);
  });

  it('a reset waits for a save in flight, so the save can never land after it', async () => {
    const log: string[] = [];
    const slow = deferred();
    const b = new SettingsBatcher(() => {
      log.push('save sent');
      return slow.promise.then(() => void log.push('save done'));
    });

    b.push({ topics: { cooking: { multiplier: 2 } } });
    jest.advanceTimersByTime(150);
    const reset = b.supersede(async () => {
      log.push('reset');
    });
    await ticks();
    expect(log).toEqual(['save sent']);

    slow.resolve();
    await reset;
    expect(log).toEqual(['save sent', 'save done', 'reset']);
  });

  it('edits made during the reset go out after it', async () => {
    const log: string[] = [];
    const resetDone = deferred();
    const b = new SettingsBatcher((c) => {
      log.push(`save ${JSON.stringify(c)}`);
    });

    const reset = b.supersede(() => {
      log.push('reset sent');
      return resetDone.promise.then(() => void log.push('reset done'));
    });
    await ticks();
    b.push({ sources: { fresh: 0 } });
    jest.advanceTimersByTime(150);
    await ticks();
    expect(log).toEqual(['reset sent']);

    resetDone.resolve();
    await reset;
    await ticks();
    expect(log).toEqual(['reset sent', 'reset done', 'save {"sources":{"fresh":0}}']);
  });

  it('drain waits for follow-up writes, not just the one in flight', async () => {
    const first = deferred();
    const sent: unknown[] = [];
    const b = new SettingsBatcher((c) => {
      sent.push(c);
      return sent.length === 1 ? first.promise : Promise.resolve();
    });

    b.push({ sources: { fresh: 0 } });
    jest.advanceTimersByTime(150);
    b.push({ sources: { trending: 2 } });

    let drained = false;
    const done = b.drain().then(() => (drained = true));
    await ticks();
    expect(drained).toBe(false);

    first.resolve();
    await done;
    expect(sent).toEqual([{ sources: { fresh: 0 } }, { sources: { trending: 2 } }]);
  });
});

describe('subtractChange', () => {
  it('settles only what an acknowledged write carried', () => {
    const pending = {
      topics: { cooking: { multiplier: 0.5, hard_off: true }, travel: { multiplier: 2 } },
      sources: { fresh: 0, trending: 1.5 },
      non_personalized: true,
    };
    // The write that just landed carried cooking at 1.5 (since edited to
    // 0.5), cooking off, travel 2 and fresh 0.
    const sent = {
      topics: { cooking: { multiplier: 1.5, hard_off: true }, travel: { multiplier: 2 } },
      sources: { fresh: 0 },
    };
    expect(subtractChange(pending, sent)).toEqual({
      topics: { cooking: { multiplier: 0.5 } },
      sources: { trending: 1.5 },
      non_personalized: true,
    });
  });

  it('returns nothing pending once everything is acknowledged', () => {
    const c = { topics: { cooking: { hard_off: true } }, non_personalized: false };
    expect(subtractChange(c, c)).toEqual({});
  });
});
