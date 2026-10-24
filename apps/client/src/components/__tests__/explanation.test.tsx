import { fireEvent, render, screen } from '@testing-library/react-native';

import type { Explanation as ExplanationData } from '@/lib/explanation';

import { Explanation } from '../explanation';

const contributions = [
  {
    feature: 'topic_affinity',
    topic: 'cooking',
    label_sources: ['creator'],
    default_weight: 1,
    user_multiplier: 1,
    weight: 1,
    value: 0.62,
    contribution: 0.62,
  },
  {
    feature: 'source_prior',
    source: 'topic',
    default_weight: 0.2,
    user_multiplier: 1,
    weight: 0.2,
    value: 1,
    contribution: 0.2,
  },
  {
    feature: 'freshness',
    default_weight: 0.4,
    user_multiplier: 1,
    weight: 0.4,
    value: 0.9,
    contribution: 0.36000000000000004,
  },
  {
    feature: 'diversity',
    default_weight: 0.5,
    user_multiplier: 1,
    weight: 0.5,
    value: -0.5,
    contribution: -0.25,
  },
] as ExplanationData['contributions'];

const explanation: ExplanationData = {
  impression_id: 'i',
  content_id: 'c',
  served_at: '2026-10-21T12:00:00Z',
  ranker_version: 'v1',
  candidate_source: 'topic',
  sources: ['fresh', 'topic'],
  position: 0,
  final_score: contributions.reduce((s, c) => s + c.contribution, 0),
  contributions,
  settings_version: 4,
  settings: {
    version: 4,
    non_personalized: false,
    topics: [],
    sources: [],
    available_sources: [],
    hard_off_threshold: 0.5,
  },
  topic_names: { cooking: 'Cooking' },
};

describe('Explanation', () => {
  it('shows every stored contribution, largest first, and the stored total', async () => {
    await render(<Explanation explanation={explanation} />);

    const amounts = screen.getAllByTestId('why-row-contribution').map((n) => n.props.children);
    expect(amounts).toEqual(['+0.62', '+0.36', '−0.25', '+0.20']);
    expect(screen.getByTestId('why-total')).toHaveTextContent(explanation.final_score.toFixed(3));
    expect(screen.getByText('You watch a lot of Cooking')).toBeOnTheScreen();
    expect(screen.getByText(/version 4/)).toBeOnTheScreen();
    expect(screen.getByText(/label from: creator/)).toBeOnTheScreen();
  });

  it('offers Adjust for topic and source rows', async () => {
    const onAdjust = jest.fn();
    await render(<Explanation explanation={explanation} onAdjust={onAdjust} />);

    fireEvent.press(screen.getByTestId('why-adjust-cooking'));
    expect(onAdjust).toHaveBeenCalledWith('cooking');
    fireEvent.press(screen.getByTestId('why-adjust-sources'));
    expect(onAdjust).toHaveBeenLastCalledWith(undefined);
  });
});
