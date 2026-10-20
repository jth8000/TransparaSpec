# T-Spec Roadmap

Each phase ends with a working, demoable system. Phases are sized for a two-person team (the user + Claude).

## Phase 0: Foundations — done (2026-10-20)
- Monorepo scaffold: Expo client, Phoenix server, generated API client, CI workflow (format, lint, typecheck, unit, API drift, web E2E).
- Accounts: email sign-in (6-digit code for native, magic link for web), profiles, handles, 13+ gate (birthdate checked, never stored), consent record v1.
- Content model (ADR 0008), with `short_video` and `text_post` kinds.
- `Video.Provider` behaviour with a dev/test **LocalProvider** (ffmpeg → HLS, signed webhooks) and a **Cloudflare Stream** implementation: direct upload → webhook → Oban → ready → HLS playback.
- `Events.record/2` stamps the server-side consent version; the client batches events.
- Following and Latest (global chronological) feeds; vertical swipe player.
- OpenAPI spec → generated TS client pipeline.
- **Done when:** sign in on the Android emulator and web; upload a video; see it play in another account's feed. ✅ Verified on web (Playwright) and the Android 17 emulator.
- **Not yet done** (carried forward):
  - iOS has never been run. It needs an Apple Developer account and a device or Mac. Phase 2, before beta.
  - Cloudflare Stream is only stub-tested. A live check needs an account (`VIDEO_PROVIDER=cloudflare` + `CF_*`).
  - CI is written but has never run. There's no git remote yet.

## Phase 1: Transparent ranking
- Topic taxonomy (IAB-seeded) and creator topic selection.
- Python ML service: transcript, embeddings, topic classification, moderation scores, called via Oban.
- Interest model: topic affinities with decay, plus an evidence view.
- Candidate sources: following, topic, trending, explore, and co-engagement (SQL v1).
- Explainable ranker with contribution traces; `impressions` logging; property tests.
- "Why am I seeing this?" sheet; Algorithm Dashboard.
- Per-user `Feed` process; weight sliders and hard-off toggles; live re-rank over Channels.
- Non-personalized feed toggle.
- **Done when:** turning off "fitness" visibly re-ranks the feed within a second, and every item's explanation matches its stored trace.

## Phase 2: Social and safety → private beta
- Passkeys and Sign in with Apple / Google (deferred from Phase 0); first iOS build and run.
- Rate limiting on sign-in requests and code attempts per IP/email (Phase 0 only caps attempts per code).
- Threaded comments, likes, blocks/mutes, share links.
- Real-time in-app notifications; push notifications.
- Reporting, moderation queue/actions/audit log, ML-score routing.
- CSAM hash matching + NCMEC reporting process; DMCA agent and flow.
- Data export and account deletion.
- ToS and privacy policy; beta invite system; basic admin tools.
- Fly.io production deploy, backups, monitoring.
- **Done when:** invite-only US beta is live.

## Phase 3: Monetization (creators first)
- Double-entry ledger, revenue periods, versioned split policies, period-close jobs.
- **3a. Subscriptions + creator share:**
  - Stripe on web + RevenueCat on mobile.
  - Per-subscriber creator allocation.
  - Subscriber receipts ("where your money went").
  - Creator earnings dashboard.
  - Stripe Connect Express onboarding and creator payouts. **This is the first real money out.**
- **3b. Ads:**
  - Overlay link, post-roll, and labeled lead-in clips paired with host videos, chosen after the ranker. Free tier only.
  - Per-viewer ad budget; viewability measurement.
  - Ad transparency ("why this ad").
  - Tap-only purchase attribution.
  - Creator ad controls: category blocks and placement toggles.
  - Creator ad share with pending → available.
  - **Creator revenue analytics**: subscription vs ad split; ads by category, placement and type; per-video earnings.
- "Your data's estimated value" page (dividend accruals, no payout yet).
- Legal review of the dividend model.

## Phase 4: Expansion
- Long-form video, link and quote posts, communities, search.
- Learned ranker v2 (still decomposable); SimClusters-style communities v3.
- Rust: scoring NIF or graph-walk service, wherever profiling shows the need.
- Dividend payouts (after legal clearance): reuse the creator payout rails, plus anti-sybil defenses.
