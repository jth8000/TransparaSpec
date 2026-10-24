import type { Schemas } from './api';

export type ForYouItem = Schemas['ForYouItem'];

/** A live re-rank pushed by the server (ADR 0011). */
export type Rerank = {
  session_id: string;
  rev: number;
  /** Keep everything up to and including this item; null = replace all. */
  after_impression_id: string | null;
  items: ForYouItem[];
};

export type ForYouState = { sessionId: string | null; rev: number; items: ForYouItem[] };

export const initialForYou: ForYouState = { sessionId: null, rev: 0, items: [] };

/** Adds a fetched page. A different session id means a fresh feed. */
export function appendPage(state: ForYouState, page: Schemas['ForYouPage']): ForYouState {
  if (state.sessionId !== page.session_id) {
    return { sessionId: page.session_id, rev: page.rev, items: page.items };
  }
  // Skip anything already in the list, by impression or by content: the
  // client can keep an item the server re-ranked away (the one on screen),
  // and must not show that video twice.
  const impressions = new Set(state.items.map((i) => i.impression_id));
  const content = new Set(state.items.map((i) => i.id));
  return {
    ...state,
    rev: Math.max(state.rev, page.rev),
    items: [
      ...state.items,
      ...page.items.filter((i) => !impressions.has(i.impression_id) && !content.has(i.id)),
    ],
  };
}

/**
 * Applies a pushed re-rank: keeps the list up to and including the item the
 * server re-ranked after, and replaces the rest. The item on screen is never
 * taken away: if the server hasn't heard yet that the client moved further
 * (a push from a refill or another device can cross an `at` message in
 * flight), everything through `currentImpressionId` is kept too, and pushed
 * items already kept are dropped. Pushes for another session, or no newer
 * than the revision already held, are stale and ignored.
 */
export function applyRerank(
  state: ForYouState,
  push: Rerank,
  currentImpressionId?: string | null,
): ForYouState {
  if (push.session_id !== state.sessionId || push.rev <= state.rev) return state;

  const anchor =
    push.after_impression_id === null
      ? -1
      : state.items.findIndex((i) => i.impression_id === push.after_impression_id);
  if (push.after_impression_id !== null && anchor < 0) return state;

  const current = currentImpressionId
    ? state.items.findIndex((i) => i.impression_id === currentImpressionId)
    : -1;
  const kept = state.items.slice(0, Math.max(anchor, current) + 1);
  const keptContent = new Set(kept.map((i) => i.id));

  return { ...state, rev: push.rev, items: [...kept, ...push.items.filter((i) => !keptContent.has(i.id))] };
}
