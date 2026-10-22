import { useQuery } from '@tanstack/react-query';

import { api, unwrap, type Schemas } from './api';

export type Topic = Schemas['Topic'];

export type TopicTree = { parent: Topic; children: Topic[] }[];

/** The taxonomy is static reference data: fetch once per app session. */
export function useTopics() {
  return useQuery({
    queryKey: ['topics'],
    queryFn: () => unwrap(api.GET('/api/topics')),
    staleTime: Infinity,
    gcTime: Infinity,
  });
}

/** Tier-1 topics with their tier-2 children, in API order (by name). */
export function topicTree(topics: Topic[]): TopicTree {
  const children = new Map<string, Topic[]>();
  for (const t of topics) {
    if (t.parent) children.set(t.parent, [...(children.get(t.parent) ?? []), t]);
  }
  return topics
    .filter((t) => t.tier === 1)
    .map((parent) => ({ parent, children: children.get(parent.slug) ?? [] }));
}

/**
 * Topics whose name matches `query` (case-insensitive substring). A matching
 * child keeps its parent visible; a matching parent shows all its children.
 */
export function filterTree(tree: TopicTree, query: string): TopicTree {
  const q = query.trim().toLowerCase();
  if (!q) return tree;
  const hit = (t: Topic) => t.name.toLowerCase().includes(q);
  return tree.flatMap(({ parent, children }) => {
    if (hit(parent)) return [{ parent, children }];
    const matching = children.filter(hit);
    return matching.length ? [{ parent, children: matching }] : [];
  });
}

/** Adds or removes `slug`; adding beyond `max` is a no-op. */
export function toggleTopic(selected: string[], slug: string, max: number): string[] {
  if (selected.includes(slug)) return selected.filter((s) => s !== slug);
  return selected.length >= max ? selected : [...selected, slug];
}
