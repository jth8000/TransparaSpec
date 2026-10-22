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
  const have = new Set(state.items.map((i) => i.impression_id));
  return {
    ...state,
    rev: Math.max(state.rev, page.rev),
    items: [...state.items, ...page.items.filter((i) => !have.has(i.impression_id))],
  };
}

/**
 * Applies a pushed re-rank: keeps the list up to and including the item the
 * server re-ranked after (the one being watched is never taken away) and
 * replaces the rest. Pushes for another session, or no newer than the
 * revision already held, are stale and ignored.
 */
export function applyRerank(state: ForYouState, push: Rerank): ForYouState {
  if (push.session_id !== state.sessionId || push.rev <= state.rev) return state;
  if (push.after_impression_id === null) return { ...state, rev: push.rev, items: push.items };

  const index = state.items.findIndex((i) => i.impression_id === push.after_impression_id);
  if (index < 0) return state;
  return { ...state, rev: push.rev, items: [...state.items.slice(0, index + 1), ...push.items] };
}
