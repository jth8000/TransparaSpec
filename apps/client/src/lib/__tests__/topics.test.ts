import { filterTree, toggleTopic, topicTree, type Topic } from '../topics';

const t = (slug: string, name: string, parent: string | null = null): Topic => ({
  slug,
  name,
  tier: parent ? 2 : 1,
  parent,
});

const topics = [
  t('food-and-drink', 'Food & Drink'),
  t('healthy-living', 'Healthy Living'),
  t('cooking', 'Cooking', 'food-and-drink'),
  t('fitness-and-exercise', 'Fitness and Exercise', 'healthy-living'),
  t('nutrition', 'Nutrition', 'healthy-living'),
];

describe('topicTree', () => {
  it('groups tier-2 topics under their tier-1 parent', () => {
    expect(
      topicTree(topics).map(({ parent, children }) => [parent.slug, children.map((c) => c.slug)]),
    ).toEqual([
      ['food-and-drink', ['cooking']],
      ['healthy-living', ['fitness-and-exercise', 'nutrition']],
    ]);
  });
});

describe('filterTree', () => {
  const tree = topicTree(topics);

  it('keeps a matching child with its parent, and only that child', () => {
    const result = filterTree(tree, 'fit');
    expect(result).toHaveLength(1);
    expect(result[0].parent.slug).toBe('healthy-living');
    expect(result[0].children.map((c) => c.slug)).toEqual(['fitness-and-exercise']);
  });

  it('shows all children of a matching parent', () => {
    expect(filterTree(tree, 'HEALTHY')[0].children).toHaveLength(2);
  });

  it('returns everything for a blank query', () => {
    expect(filterTree(tree, '  ')).toBe(tree);
  });
});

describe('toggleTopic', () => {
  it('adds and removes', () => {
    expect(toggleTopic([], 'cooking', 3)).toEqual(['cooking']);
    expect(toggleTopic(['cooking', 'travel'], 'cooking', 3)).toEqual(['travel']);
  });

  it('does not add past the maximum, but still removes', () => {
    const full = ['a', 'b', 'c'];
    expect(toggleTopic(full, 'd', 3)).toBe(full);
    expect(toggleTopic(full, 'b', 3)).toEqual(['a', 'c']);
  });
});
