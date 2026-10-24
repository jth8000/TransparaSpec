import { appendPage, applyRerank, initialForYou, type ForYouItem } from '../for-you-state';

const item = (imp: string): ForYouItem =>
  ({ id: `c-${imp}`, impression_id: imp, candidate_source: 'fresh' }) as unknown as ForYouItem;

const page = (session_id: string, rev: number, imps: string[]) => ({
  session_id,
  rev,
  items: imps.map(item),
});
const ids = (s: { items: ForYouItem[] }) => s.items.map((i) => i.impression_id);

describe('appendPage', () => {
  it('starts a session, then appends without duplicates', () => {
    let s = appendPage(initialForYou, page('s1', 0, ['a', 'b']));
    s = appendPage(s, page('s1', 0, ['b', 'c']));
    expect(s.sessionId).toBe('s1');
    expect(ids(s)).toEqual(['a', 'b', 'c']);
  });

  it('skips a page item whose video the list already holds (kept through a re-rank)', () => {
    const s = appendPage(appendPage(initialForYou, page('s1', 0, ['a', 'b'])), {
      session_id: 's1',
      rev: 0,
      items: [{ ...item('z'), id: 'c-a' } as ForYouItem, item('c')],
    });
    expect(ids(s)).toEqual(['a', 'b', 'c']);
  });

  it('a new session id replaces the feed', () => {
    const s = appendPage(appendPage(initialForYou, page('s1', 3, ['a'])), page('s2', 0, ['x']));
    expect(s).toEqual({ sessionId: 's2', rev: 0, items: [item('x')] });
  });
});

describe('applyRerank', () => {
  const base = appendPage(initialForYou, page('s1', 0, ['a', 'b', 'c', 'd']));

  it('keeps everything through the current item and replaces the tail', () => {
    const s = applyRerank(base, {
      session_id: 's1',
      rev: 1,
      after_impression_id: 'b',
      items: [item('x'), item('y')],
    });
    expect(ids(s)).toEqual(['a', 'b', 'x', 'y']);
    expect(s.rev).toBe(1);
  });

  it('drops stale or foreign pushes', () => {
    const s1 = applyRerank(base, { session_id: 's1', rev: 2, after_impression_id: 'a', items: [item('x')] });
    // An older revision arriving late changes nothing.
    expect(
      applyRerank(s1, { session_id: 's1', rev: 1, after_impression_id: 'a', items: [item('old')] }),
    ).toBe(s1);
    // Same revision twice: already applied.
    expect(
      applyRerank(s1, { session_id: 's1', rev: 2, after_impression_id: 'a', items: [item('dup')] }),
    ).toBe(s1);
    // Another feed session's push.
    expect(applyRerank(s1, { session_id: 's9', rev: 5, after_impression_id: 'a', items: [] })).toBe(s1);
  });

  it('replaces everything when nothing had been served, and ignores an unknown anchor', () => {
    const empty = appendPage(initialForYou, page('s1', 0, []));
    expect(
      ids(applyRerank(empty, { session_id: 's1', rev: 1, after_impression_id: null, items: [item('x')] })),
    ).toEqual(['x']);
    expect(applyRerank(base, { session_id: 's1', rev: 1, after_impression_id: 'zzz', items: [] })).toBe(base);
  });

  it('never replaces the item on screen, even if the server anchored earlier', () => {
    // The client is on "c"; the server still thinks it's on "a".
    const push = { session_id: 's1', rev: 1, after_impression_id: 'a', items: [item('x'), item('c2')] };
    const s = applyRerank(base, push, 'c');
    expect(ids(s)).toEqual(['a', 'b', 'c', 'x', 'c2']);
  });

  it('drops pushed items that are already kept (same content)', () => {
    const dup = { ...item('x'), id: 'c-b' } as ForYouItem;
    const s = applyRerank(
      base,
      { session_id: 's1', rev: 1, after_impression_id: 'a', items: [dup, item('y')] },
      'b',
    );
    expect(ids(s)).toEqual(['a', 'b', 'y']);
  });

  it('uses the server anchor when it is further than the current item', () => {
    const s = applyRerank(
      base,
      { session_id: 's1', rev: 1, after_impression_id: 'c', items: [item('x')] },
      'a',
    );
    expect(ids(s)).toEqual(['a', 'b', 'c', 'x']);
  });
});
