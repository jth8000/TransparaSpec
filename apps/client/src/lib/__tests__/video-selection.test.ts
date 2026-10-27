import { describeVideo, durationMs } from '../video-selection';

describe('describeVideo', () => {
  it('shows name, length and size', () => {
    expect(describeVideo({ fileName: 'clip.mp4', duration: 12_400, width: 1080, height: 1920 })).toBe(
      'clip.mp4 · 0:12 · 1080×1920',
    );
    expect(describeVideo({ fileName: 'long.mov', duration: 125_000 })).toBe('long.mov · 2:05');
  });

  it('leaves out what the picker did not report', () => {
    expect(describeVideo({ fileName: null, duration: null })).toBe('Video');
  });
});

describe('durationMs', () => {
  it("converts the web picker's seconds; native already reports milliseconds", () => {
    expect(durationMs(3.04, 'web')).toBeCloseTo(3040);
    expect(durationMs(3040, 'android')).toBe(3040);
    expect(durationMs(null, 'web')).toBeNull();
  });
});
