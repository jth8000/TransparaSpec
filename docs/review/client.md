# Client

The Expo app (`apps/client`): iOS, Android and web from one codebase, with Expo Router, TanStack Query and a generated API client. It has run on web (Playwright, in CI) and the Android emulator, but **never on iOS**. Native builds aren't part of CI.

The server treats the client as untrusted ([threat-model.md](threat-model.md)). This page covers what the client must still get right: holding credentials, its session lifecycle, rendering untrusted content, deep links and the web build.

## Credentials

| Platform | Where the bearer token lives | Code |
|---|---|---|
| iOS, Android | OS keychain / keystore (`expo-secure-store`) | [token-storage.ts](../../apps/client/src/lib/token-storage.ts) |
| Web | `localStorage`, readable by any script on the page | [token-storage.web.ts](../../apps/client/src/lib/token-storage.web.ts) |

- **The token is sent in two ways:** as an `Authorization: Bearer` header on API calls, and as a `?token=` query parameter on the WebSocket URL, which is how Phoenix's JS client passes connect params. The server filters `token` from its own logs.
- **One shared API client** ([api.ts](../../apps/client/src/lib/api.ts)) reads the current token at request time. The event queue is the exception: it has its own client per token (I24).

## Session lifecycle ([session.tsx](../../apps/client/src/lib/session.tsx))

1. **Launch.** If a token is stored, the client checks it with `GET /api/me`. Only a 401 drops it. Offline or a server error shows a "Can't reach T-Spec" screen with Try again, and the token is kept (I26).
2. **Signed in.** `Stack.Protected` guards in [`_layout.tsx`](../../apps/client/src/app/_layout.tsx) pick which routes exist: auth screens when signed out, onboarding when signed in but not onboarded, the app once onboarded.
3. **Sign-out:**
   - runs `beforeSignOut` work while the token is still valid, capped at 3 s (I27): the event queue sends what it holds (I25);
   - revokes the token (`DELETE /api/auth/session`), and the server closes that token's sockets (I4 in [concurrency.md](concurrency.md));
   - clears the query cache;
   - forgets the token.

## What the server takes from the client

Everything below is client input. The server validates each item and bounds the damage, and it never trusts the client for identity or consent.

| Input | Server-side checks | Remaining risk |
|---|---|---|
| Engagement events (`POST /api/events`) | Event type, a timestamp within 7 days, at most 100 per batch, content the caller can see, the caller's own impression ids (I14). Consent version stamped server-side (I17). | Values are self-reported; there's no view attestation ([open-questions](../open-questions.md), "Engagement abuse"). |
| `view_id` (client-minted UUID) | A view belongs to the user and content of its first event. A reused id from another user or for other content is ignored. | — |
| Feed `session` id (client-minted UUID) | Namespaced by user id in the `:global` name and the PubSub topic. Capped at 10 live per user (I6). | — |
| Feed position (`at`) and `rev` on the channel | Matched by impression id within the user's own session; it only changes what that session re-ranks. | — |
| Algorithm settings | Validated (slugs, sources, 0–2 multipliers), all or nothing. | — |
| Video upload | The client posts the file straight to the provider's one-time URL. The server only trusts the provider's signed webhook. | — |

Server tests: [interests_test](../../apps/server/test/tspec/feed/interests_test.exs): "a view_id reused for other content or by another user is ignored"; [events_test](../../apps/server/test/tspec/events_test.exs): "ignores content the caller can't see (someone else's unprocessed upload)".

## Rendering untrusted content

- **Text:** captions, bios, display names and handles are rendered with React Native `<Text>`, which never interprets HTML, on web too. There's no `dangerouslySetInnerHTML`, `WebView`, `eval` or `innerHTML`.
- **Links:** the only ones are internal routes (`/u/<handle>`). User text never becomes a link.
- **Remote media:** only `playback_url`, which the server builds from the video provider's config. Users can't set an avatar URL: `ProfileUpdate` accepts only `display_name` and `bio`. On web, HLS plays through `hls.js`.

## Deep links

The app registers the `tspec://` scheme, so a link from anywhere can open any route. That's harmless today:
- routes outside the current auth state don't exist (`Stack.Protected`);
- `/verify?email&token` shows "Continue as <email>" and waits for a tap, and the server checks the token belongs to that email (I3);
- `/why/<impression>` only returns the caller's own impressions (I19).

No universal or app links (`https://`) are configured. Magic links go to the web client; native users type the 6-digit code.

## Web build

`app.json` has `web.output: "single"`, a static single-page app. **Where it will be hosted, and with which headers, isn't decided.** So there's no Content-Security-Policy or other security header for the web client yet (U11 in [unsure.md](unsure.md)). The server's CORS allows only `CLIENT_URL`'s origin in production. The socket's origin check is U9.

## Invariants

Same format as [concurrency.md](concurrency.md). The mutations live in [`scripts/mutation_checks.py`](../../scripts/mutation_checks.py) and run with Jest.

| # | Invariant | Enforced by | Test | Mutation |
|---|---|---|---|---|
| I21 | A re-rank push no newer than the revision the client holds, or for another session, is dropped. | `applyRerank` in [for-you-state.ts](../../apps/client/src/lib/for-you-state.ts). | [for-you-state.test](../../apps/client/src/lib/__tests__/for-you-state.test.ts): "drops stale or foreign pushes" | M19 |
| I22 | A re-rank never replaces the item on screen, even if the push was anchored earlier. | `applyRerank` keeps everything through `max(anchor, current)`. | [for-you-state.test](../../apps/client/src/lib/__tests__/for-you-state.test.ts): "never replaces the item on screen, even if the server anchored earlier" | M20 |
| I23 | A page never adds a video the list already holds, including one kept on screen through a re-rank. | `appendPage` dedupes by impression and content. | [for-you-state.test](../../apps/client/src/lib/__tests__/for-you-state.test.ts): "skips a page item whose video the list already holds (kept through a re-rank)" | M21 |
| I24 | A failed event batch is put back, in order, not lost. | `EventQueue.flush`. | [event-queue.test](../../apps/client/src/lib/__tests__/event-queue.test.ts): "puts a failed batch back at the front, in order" | M22 |
| I25 | Events one account queued are never sent under another account's token, and are sent under their own token before sign-out revokes it. | One `EventQueue` and API client per signed-in token; flushed through `beforeSignOut`. | [events.test](../../apps/client/src/lib/__tests__/events.test.tsx): "never sends one account's events under another account's token"; [events.test](../../apps/client/src/lib/__tests__/events.test.tsx): "sends unsent events under their own token before sign-out revokes it" | M23, M24 |
| I26 | Only a 401 drops the stored session. Offline or a server error at launch keeps it. | `checkStoredToken` in [session.tsx](../../apps/client/src/lib/session.tsx). | [session.test](../../apps/client/src/lib/__tests__/session.test.tsx): "keeps the stored token when the server can't be reached at launch, and retries"; [session.test](../../apps/client/src/lib/__tests__/session.test.tsx): "drops a stored token the server rejects" | M25 |
| I27 | Before-sign-out work runs while the token is still valid, before it's revoked. | `signOut` awaits the `beforeSignOut` work (capped at 3 s) before `DELETE /api/auth/session`. | [session.test](../../apps/client/src/lib/__tests__/session.test.tsx): "runs before-sign-out work while the token is still valid, then revokes it" | M26 |
| I28 | The client never sends a consent version; the server stamps it. | `EventQueue` events have no consent field; the server ignores one anyway (I17). | [events_test](../../apps/server/test/tspec/events_test.exs): "stamps the server-side consent version, ignoring anything the client sends" | — |
