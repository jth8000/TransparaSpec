# ADR 0001: Expo (React Native) universal client

- **Status:** Accepted
- **Date:** 2026-10-20

## Context
The team is two developers (the user and Claude). T-Spec needs iOS, Android and web clients, and the core experience is a vertical-swipe short-video feed. Two things drive the choice:
- **Native-quality playback** with preloading.
- **A real web presence**, since links to posts and profiles get shared and should load fast.

## Decision
Use **Expo (React Native + react-native-web) with TypeScript and Expo Router**: one codebase for all three platforms.
- Playback: `expo-video` (HLS).
- Data fetching: TanStack Query.
- API: a typed client generated from the server's OpenAPI spec.

## Consequences
- One codebase, one language for client logic, and file-based routes shared across platforms.
- Native video and gestures on mobile; HLS playback on web.
- Some web-specific polish may need `.web.tsx` platform files.
- If SEO or server rendering ever becomes critical, we can add a Next.js web app to the monorepo that reuses the generated API client and shared logic.

## Alternatives considered
- **Flutter.** Its canvas-rendered web output is weak for shareable, fast-loading social pages.
- **Kotlin/Compose Multiplatform.** Web support is less mature, and it's a smaller ecosystem for this kind of app.
- **Capacitor or Tauri wrapping a web app.** WebView video feeds are more sensitive to performance problems, and the native feel is worse.
- **Separate native apps.** Too much surface for two people.
