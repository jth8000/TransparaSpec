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
