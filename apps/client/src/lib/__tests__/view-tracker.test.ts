import { ViewTracker } from '../view-tracker';

jest.mock('expo-crypto', () => ({ randomUUID: () => 'default-id' }));

const setup = (isVideo = true) => {
  const track = jest.fn();
  let n = 0;
  const tracker = new ViewTracker('item-1', isVideo, track, () => `view-${++n}`);
  return { track, tracker };
};

describe('ViewTracker', () => {
  it('starts a view with a fresh id that every event carries', () => {
    const { track, tracker } = setup();
    expect(tracker.viewId).toBe('view-1');
    expect(track).toHaveBeenCalledWith('item-1', 'view_start', { viewId: 'view-1' });

    tracker.time(5.2);
    expect(track).toHaveBeenLastCalledWith('item-1', 'watch_progress', { value: 5.2, viewId: 'view-1' });
  });

  it('reports seconds cumulatively across loops', () => {
    const { track, tracker } = setup();
    tracker.time(3);
    tracker.ended(4);
    expect(track).toHaveBeenLastCalledWith('item-1', 'complete', { value: 4, viewId: 'view-1' });

    tracker.time(1.5);
    expect(tracker.played).toBe(5.5);
    expect(track).toHaveBeenLastCalledWith('item-1', 'watch_progress', { value: 5.5, viewId: 'view-1' });

    tracker.ended(4);
    expect(track).toHaveBeenLastCalledWith('item-1', 'complete', { value: 8, viewId: 'view-1' });
  });

  it('sends watch_progress once per 5 seconds played', () => {
    const { track, tracker } = setup();
    [1, 2, 4.9, 5, 6, 9.9, 10.1].forEach((t) => tracker.time(t));
    const progress = track.mock.calls.filter(([, type]) => type === 'watch_progress');
    expect(progress.map(([, , o]) => o.value)).toEqual([5, 10.1]);
  });

  it('skips only an unfinished video', () => {
    const unfinished = setup();
    unfinished.tracker.time(1.2);
    unfinished.tracker.end();
    expect(unfinished.track).toHaveBeenLastCalledWith('item-1', 'skip', { value: 1.2, viewId: 'view-1' });

    const finished = setup();
    finished.tracker.ended(3);
    finished.tracker.end();
    expect(finished.track).not.toHaveBeenCalledWith('item-1', 'skip', expect.anything());

    const text = setup(false);
    text.tracker.end();
    expect(text.track).toHaveBeenCalledTimes(1);
  });

  it('falls back to the furthest position when the player reports no duration', () => {
    const { track, tracker } = setup();
    tracker.time(2.5);
    tracker.ended(NaN);
    expect(track).toHaveBeenLastCalledWith('item-1', 'complete', { value: 2.5, viewId: 'view-1' });
  });
});
