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
  - ~~CI is written but has never run.~~ CI first ran green on GitHub on 2026-10-21 (all four jobs).

## Phase 1: Transparent ranking
Split into two parts. 1a uses creator-picked topics and must meet the "done when" test on its own. 1b adds model topics through the same `content_topics` table.

### 1a: Ranker, explanations and live controls — done (2026-10-21)
- Topic taxonomy: IAB Content Taxonomy tiers 1–2, plus creator topic selection (up to 3).
- Interest model ([ADR 0012](adr/0012-interest-model-and-controls.md)):
  - per-view deltas;
  - decay;
  - exactly-once application;
  - an evidence view.
- Candidate sources (SQL v1): following, topic, trending, explore, co-engagement, fresh.
- Explainable ranker with contribution traces; `impressions` logging (served vs exposed); property tests.
- Per-feed-session `Feed.Session` processes; live re-rank and refill over Channels ([ADR 0011](adr/0011-feed-sessions-and-live-rerank.md)).
- Topic sliders (preference + affinity), hard-off toggles, source weights, a non-personalized mode.
- "Why am I seeing this?" sheet; Algorithm Dashboard.
- **Done when:** turning off "fitness" visibly re-ranks the feed within a second, and every item's explanation matches its stored trace. ✅
  - **Web:** Playwright (`e2e/tests/transparent-ranking.spec.ts`). The tap reaches a pushed, re-ranked feed in about 230 ms, including the 150 ms debounce, with no reload and no fitness item after the current one. Every new explanation sums exactly to its stored score. A second device re-ranks its own session. After a further settings change, an item still explains itself with the settings it was served under.
  - **Android 17 emulator:** For You, the Why sheet, and Tune → Fitness off, with the following items free of fitness.
  - **Server timing:** ranking 500 candidates takes about 15 ms; a settings change reaches the client in about 6 ms.
- **Known limits:**
  - Hard-off covers creator labels only until 1b adds model labels.
  - Ranker weights and affinity deltas are hand-tuned (open questions).
  - iOS still not run (Phase 2).

### 1b: Content understanding (Python ML service)
- `services/ml` (FastAPI), called from Oban jobs (ADR 0003). The default pipeline is multimodal:
  - a Whisper transcript;
  - CLIP/SigLIP embeddings of about 8 frames;
  - caption text;
  - zero-shot scoring against the taxonomy.

  Frames matter because many short videos have no speech or caption.
- Writes `content_topics` with `source = model`, and adds `content_embeddings` (pgvector) and moderation scores (scores only, never approve/reject).
- Hard-off coverage widens to model labels, with the same meaning.
- An optional LLM pass over the caption and transcript, behind the same output contract, if accuracy needs it.

## Phase 2: Social and safety → private beta
- Passkeys and Sign in with Apple / Google (deferred from Phase 0); first iOS build and run.
- ~~Rate limiting on sign-in requests and code attempts per IP/email~~ Done (see open questions).
- Engagement abuse: rate limits on events, view-lifecycle validation, sybil/bot heuristics before signals feed shared rankings (see open questions).
- Threaded comments, likes, blocks/mutes, share links.
- Real-time in-app notifications; push notifications.
- Reporting, moderation queue/actions/audit log, ML-score routing.
- CSAM hash matching + NCMEC reporting process; DMCA agent and flow.
- Data export and account deletion.
- ToS and privacy policy; beta invite system; basic admin tools.
- Fly.io production deploy, backups, monitoring. Nothing exists yet: `infra/` is empty, and there's no release config, Dockerfile or `fly.toml` (`mix phx.gen.release --docker` / `fly launch` generate most of it).
  - **One Phoenix machine for the private beta** ([ADR 0013](adr/0013-single-machine-private-beta.md)):
    - deploy with Fly's rolling strategy, never blue-green or canary (both run two unclustered machines at once);
    - pass `--ha=false` on the first `fly launch` or `fly deploy`, which otherwise creates two machines;
    - in `fly.toml`, set `auto_stop_machines = "off"` and `auto_start_machines = false`. A stopped machine runs no Oban cron and drops feed sessions;
    - check those `fly.toml` settings in CI, the way `prod_config_test` checks the production config.
  - **Clustering comes later.** ADR 0013 lists its prerequisites (a partition test for feed sessions, a shared rate limiter). Then it needs:
    - `DNS_CLUSTER_QUERY=<app>.internal`;
    - a node name built from each machine's private IP (`RELEASE_NODE` in `rel/env.sh.eex`);
    - the same `RELEASE_COOKIE` on every machine;
    - IPv6 distribution (`ERL_AFLAGS="-proto_dist inet6_tcp"`), since Fly's private network is IPv6;
    - a check on two machines that a feed session keeps one owner.

  Postgres connections use verified TLS by default, checked against the OS CA store, so the release image needs `ca-certificates`. Set `DATABASE_SSL=false` only for a database reachable solely over a private network that doesn't offer TLS.
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
