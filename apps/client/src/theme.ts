/** Minimal design tokens. The feed is always dark (video-first); forms follow the system scheme. */
export const colors = {
  bg: '#0B0B0F',
  surface: '#17171D',
  surfaceRaised: '#22222A',
  border: '#2E2E38',
  text: '#F4F4F6',
  textMuted: '#A1A1AD',
  accent: '#7C5CFF',
  accentText: '#FFFFFF',
  danger: '#FF5C7A',
  success: '#3DDC97',
} as const;

export const space = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 } as const;

export const radius = { sm: 8, md: 12, lg: 20, pill: 999 } as const;
