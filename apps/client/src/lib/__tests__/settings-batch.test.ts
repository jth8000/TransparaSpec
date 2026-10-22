import { mergeChanges, SettingsBatcher } from '../settings-batch';

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
});
