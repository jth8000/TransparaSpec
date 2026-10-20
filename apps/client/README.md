# T-Spec client

Expo (React Native + web) app — one codebase for Android, iOS and web (ADR 0001).

```bash
make web       # Expo web on http://localhost:8081
make android   # Android emulator (adb reverse maps the emulator's localhost:4000 to the API)
npm test -w apps/client
npm run typecheck -w apps/client
npm run lint -w apps/client
```

The API base URL comes from `EXPO_PUBLIC_API_URL` (default `http://localhost:4000`).

- `src/app/` — routes (Expo Router). `_layout.tsx` guards three states: signed out → `(auth)`, signed in but not onboarded → `onboarding`, onboarded → `(tabs)` + `u/[handle]`.
- `src/lib/` — API client (generated from the server's OpenAPI spec via `@tspec/api-schema`), session, engagement event queue, real-time socket, uploads.
- `src/components/` — feed pager, feed items, platform video players (`expo-video` native, `<video>` + hls.js web).
