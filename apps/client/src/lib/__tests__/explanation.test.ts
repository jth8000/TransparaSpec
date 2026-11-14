import {
  explanationRows,
  labelSources,
  placementNote,
  sourceControlLabel,
  sourceLabel,
  type Explanation,
} from '../explanation';

const c = (o: Partial<Explanation['contributions'][number]>) =>
  ({
    default_weight: 1,
    user_multiplier: 1,
    weight: 1,
    value: 1,
    contribution: 1,
    ...o,
  }) as Explanation['contributions'][number];

const explanation = (contributions: Explanation['contributions']): Explanation =>
  ({
    impression_id: 'i',
    content_id: 'c',
    served_at: '2026-10-21T00:00:00Z',
    ranker_version: 'v1',
    candidate_source: 'topic',
    sources: ['topic'],
    position: 0,
    final_score: contributions.reduce((sum, x) => sum + x.contribution, 0),
    contributions,
    settings_version: 3,
    settings: {
      version: 3,
      non_personalized: false,
      topics: [],
      sources: [],
      available_sources: [],
      hard_off_threshold: 0.5,
    },
    topic_names: { cooking: 'Cooking' },
  }) as Explanation;

describe('explanationRows', () => {
  const e = explanation([
    c({ feature: 'source_prior', source: 'trending', weight: 0.2, value: 1, contribution: 0.2 }),
    c({
      feature: 'topic_affinity',
      topic: 'cooking',
      label_sources: ['creator'],
      weight: 1.5,
      user_multiplier: 1.5,
      value: 0.4,
      contribution: 0.6000000000000001,
    }),
    c({
      feature: 'topic_preference',
      topic: 'cooking',
      weight: 0.75,
      user_multiplier: 1.5,
      value: 1,
      contribution: 0.75,
    }),
    c({ feature: 'diversity', weight: 0.5, value: -1, contribution: -0.5 }),
  ]);
  const rows = explanationRows(e);

  it('lists every stored contribution, largest effect first, summing to the stored score', () => {
    expect(rows.map((r) => r.contribution)).toEqual([0.75, 0.6000000000000001, -0.5, 0.2]);
    const sum = e.contributions.reduce((s, x) => s + x.contribution, 0);
    expect(sum).toBe(e.final_score);
    expect(rows).toHaveLength(e.contributions.length);
  });

  it('says why in plain words, distinguishing learned from chosen', () => {
    expect(rows.map((r) => r.label)).toEqual([
      'You set Cooking to 1.5×',
      'You watch a lot of Cooking',
      'Spacing out a creator or topic you just saw',
      'Found via trending now',
    ]);
    expect(rows[1].detail).toBe('1.50 weight × 0.40 (your 1.5×)');
    expect(rows[1].topic).toBe('cooking');
    expect(rows[3].source).toBe('trending');
  });

  it('says how much of the item a topic stands for when its labels share it', () => {
    const shared = explanationRows(
      explanation([
        c({
          feature: 'topic_affinity',
          topic: 'cooking',
          value: 0.2,
          contribution: 0.2,
          confidence: 1,
          label_share: 1 / 3,
        }),
        c({
          feature: 'topic_preference',
          topic: 'cooking',
          value: 1,
          contribution: 0.1,
          confidence: 1,
          label_share: 1,
        }),
      ]),
    );
    expect(shared.map((r) => r.detail)).toEqual([
      "1.00 weight × 0.20; 33% of this item's topics",
      '1.00 weight × 1.00',
    ]);
  });

  it('reports who labeled each topic', () => {
    expect(labelSources(e)).toEqual([{ topic: 'Cooking', sources: ['creator'] }]);
  });
});

describe('sourceControlLabel', () => {
  it('says the Explore slider sets how often, and leaves other sources as they are', () => {
    expect(sourceControlLabel('explore')).toMatch(/how often/);
    expect(sourceControlLabel('trending')).toBe(sourceLabel('trending'));
  });
});

describe('placementNote', () => {
  const placed = (contributions: Explanation['contributions']) => ({
    ...explanation(contributions),
    placement: 'explore' as const,
  });

  it('says why an explore slot placed the item, from the stored trace', () => {
    expect(placementNote(placed([]))).toBe(
      "Shown to broaden your feed: this spot is kept for a topic that's new to you. " +
        'Its score is unchanged.',
    );
    const boosted = placed([
      c({ feature: 'topic_preference', topic: 'cooking', weight: 0.375, user_multiplier: 1.25 }),
    ]);
    expect(placementNote(boosted)).toMatch(/a topic you boosted but haven't watched lately/);
  });

  it('says nothing for an ordinary placement', () => {
    expect(placementNote(explanation([]))).toBeNull();
  });
});
