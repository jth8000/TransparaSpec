import type { Schemas } from './api';

export type Explanation = Schemas['Explanation'];
export type Contribution = Schemas['Contribution'];

const SOURCE_LABELS: Record<string, string> = {
  following: 'accounts you follow',
  topic: 'topics you like',
  co_engagement: 'people who watch what you watch',
  trending: 'trending now',
  explore: 'something new to explore',
  fresh: 'new posts',
};

export const sourceLabel = (source: string) => SOURCE_LABELS[source] ?? source;

export type ExplanationRow = {
  key: string;
  label: string;
  detail: string;
  contribution: number;
  /** Topic slug, for rows a topic slider can adjust. */
  topic?: string;
  /** Candidate source, for rows a source slider can adjust. */
  source?: string;
};

const fmt = (n: number) => (Math.abs(n) >= 10 ? n.toFixed(1) : n.toFixed(2));
const times = (m: number) => `${Number(m.toFixed(2))}×`;

function label(c: Contribution, name: (slug: string) => string): string {
  const topic = c.topic ? name(c.topic) : '';
  switch (c.feature) {
    case 'topic_affinity':
      return c.value >= 0 ? `You watch a lot of ${topic}` : `You tend to skip ${topic}`;
    case 'topic_preference':
      return `You set ${topic} to ${times(c.user_multiplier)}`;
    case 'creator_affinity':
      return c.value >= 0 ? 'You often watch this creator' : 'You tend to skip this creator';
    case 'following':
      return 'You follow this creator';
    case 'source_prior':
      return `Found via ${sourceLabel(c.source ?? '')}`;
    case 'freshness':
      return 'How recently it was posted';
    case 'quality':
      return 'How often people finish it';
    case 'diversity':
      return 'Spacing out a creator or topic you just saw';
    default:
      return c.feature;
  }
}

/**
 * The explanation as display rows, largest effect first. Each row is one
 * stored contribution, so the rows always add up to the stored score.
 */
export function explanationRows(e: Explanation): ExplanationRow[] {
  const name = (slug: string) => e.topic_names[slug] ?? slug;

  return e.contributions
    .map((c, i) => ({
      key: `${c.feature}:${c.topic ?? c.source ?? ''}:${i}`,
      label: label(c, name),
      detail: `${fmt(c.weight)} weight × ${fmt(c.value)}${
        c.user_multiplier !== 1 && c.feature !== 'topic_preference'
          ? ` (your ${times(c.user_multiplier)})`
          : ''
      }`,
      contribution: c.contribution,
      topic: c.topic ?? undefined,
      source: c.feature === 'source_prior' ? (c.source ?? undefined) : undefined,
    }))
    .sort((a, b) => Math.abs(b.contribution) - Math.abs(a.contribution));
}

/** The stored total, which the rows sum to (in stored order). */
export const explanationTotal = (e: Explanation) => e.final_score;

/** Who labeled the item with each topic in the trace. */
export function labelSources(e: Explanation): { topic: string; sources: string[] }[] {
  const seen = new Map<string, string[]>();
  for (const c of e.contributions) {
    if (c.topic && c.label_sources && !seen.has(c.topic)) seen.set(c.topic, c.label_sources);
  }
  return [...seen].map(([topic, sources]) => ({ topic: e.topic_names[topic] ?? topic, sources }));
}
