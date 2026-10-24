import { render, screen } from '@testing-library/react-native';

import type { Schemas } from '@/lib/api';

import { FeedItem, fitFor } from '../feed-item';

const mockTrack = jest.fn();

jest.mock('@/lib/events', () => ({ useTrack: () => mockTrack }));

let mockViewIds = 0;
jest.mock('expo-crypto', () => ({ randomUUID: () => `view-${++mockViewIds}` }));

jest.mock('expo-router', () => {
  const { Text: MockText } = jest.requireActual('react-native');
  return { Link: ({ children }: { children: React.ReactNode }) => <MockText>{children}</MockText> };
});

jest.mock('../video-player', () => ({
  VideoPlayer: ({ uri }: { uri: string | null }) => {
    const { Text: MockText } = jest.requireActual('react-native');
    return <MockText testID="video-player">{uri ?? 'not loaded'}</MockText>;
  },
}));

const base: Schemas['ContentItem'] = {
  id: '0190f3a8-0000-7000-8000-000000000001',
  kind: 'text_post',
  status: 'ready',
  caption: null,
  published_at: '2026-10-20T12:00:00Z',
  created_at: '2026-10-20T12:00:00Z',
  author: { id: 'a', handle: 'alice', display_name: null, avatar_url: null },
  topics: [],
  video: null,
  text: { body: 'Hello T-Spec' },
};

const video: Schemas['ContentItem'] = {
  ...base,
  kind: 'short_video',
  text: null,
  caption: 'my clip',
  video: {
    playback_url: 'http://localhost:4000/dev_media/x/index.m3u8',
    thumbnail_url: null,
    duration_ms: 2000,
    width: 360,
    height: 640,
    failure_reason: null,
  },
};

describe('fitFor', () => {
  it('fills the screen with vertical video and letterboxes landscape', () => {
    expect(fitFor({ width: 1080, height: 1920 })).toBe('cover');
    expect(fitFor({ width: 1920, height: 1080 })).toBe('contain');
    expect(fitFor({ width: 1080, height: 1080 })).toBe('cover');
    expect(fitFor({ width: null, height: null })).toBe('cover');
  });
});

describe('FeedItem', () => {
  beforeEach(() => mockTrack.mockClear());

  it('renders a text post with its author', async () => {
    await render(<FeedItem item={base} height={800} active={false} preload={false} muted />);

    expect(screen.getByText('Hello T-Spec')).toBeOnTheScreen();
    expect(screen.getByText('@alice')).toBeOnTheScreen();
  });

  it('records view_start when it becomes active', async () => {
    const { rerender } = await render(
      <FeedItem item={base} height={800} active={false} preload={false} muted />,
    );
    expect(mockTrack).not.toHaveBeenCalled();

    await rerender(<FeedItem item={base} height={800} active preload={false} muted />);
    expect(mockTrack).toHaveBeenCalledWith(base.id, 'view_start', {
      viewId: expect.stringMatching(/^view-/),
    });
  });

  it('records a skip when an unfinished video is swiped away', async () => {
    const { rerender } = await render(<FeedItem item={video} height={800} active preload={false} muted />);
    await rerender(<FeedItem item={video} height={800} active={false} preload={false} muted />);

    const [[, , start]] = mockTrack.mock.calls;
    expect(mockTrack).toHaveBeenCalledWith(video.id, 'view_start', { viewId: start.viewId });
    expect(mockTrack).toHaveBeenCalledWith(video.id, 'skip', { value: 0, viewId: start.viewId });
  });

  it('starts a new view, with a new id, each time the item becomes active again', async () => {
    const { rerender } = await render(<FeedItem item={video} height={800} active preload={false} muted />);
    await rerender(<FeedItem item={video} height={800} active={false} preload={false} muted />);
    await rerender(<FeedItem item={video} height={800} active preload={false} muted />);

    const starts = mockTrack.mock.calls
      .filter(([, type]) => type === 'view_start')
      .map(([, , o]) => o.viewId);
    expect(starts).toHaveLength(2);
    expect(starts[0]).not.toEqual(starts[1]);
  });

  it('only loads video when active or adjacent', async () => {
    const { rerender } = await render(
      <FeedItem item={video} height={800} active={false} preload={false} muted />,
    );
    expect(screen.getByTestId('video-player')).toHaveTextContent('not loaded');

    await rerender(<FeedItem item={video} height={800} active={false} preload muted />);
    expect(screen.getByTestId('video-player')).toHaveTextContent(video.video!.playback_url!);
  });
});
