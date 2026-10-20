# T-Spec Architecture

The key decisions behind this design are recorded in [`adr/`](adr/), and the requirements are in [requirements.md](requirements.md).

## System overview

```
Expo clients (iOS / Android / Web)            ── one TypeScript codebase (ADR 0001)
        │  REST (OpenAPI)  +  WebSocket (Phoenix Channels)
        ▼
Elixir / Phoenix core                          ── monolith, Phoenix contexts (ADR 0002)
  │  Accounts · Content · Social · Feed/Ranking · Transparency · Moderation · Ledger · Billing
  │  Oban (Postgres-backed durable jobs)
  │  per-active-user Feed process (Registry + DynamicSupervisor)
  │
  ├── Postgres + pgvector     relational data, events, impressions, ledger, Oban jobs
  ├── VideoProvider           Cloudflare Stream or Mux: direct upload, HLS, webhooks (ADR 0005)
  ├── R2 + CDN                images, avatars, thumbnails
  ├── Python ML service       FastAPI: topics, embeddings, moderation scores (ADR 0003)
  └── (later) Rust            Rustler NIF for scoring and/or a graph-walk service (ADR 0004)
```

### Hosting (beta default)
- **Phoenix on Fly.io**: two small machines, clustered (Erlang distribution over Fly's private network) so PubSub and Channels work across nodes.
- **Python ML service on Fly.io**: one CPU machine. Beta volume is low enough that Whisper-small and CLIP can run on CPU from Oban jobs, asynchronously.
- **Managed Postgres with pgvector.**
- **Cloudflare**: Stream (video), R2 (objects), CDN.

## Client (`apps/client`)
- **Expo + Expo Router**: file-based routes shared by native and web.
- **Video**: `expo-video` (HLS) for playback; a feed list with preload and recycling for vertical swipe.
- **Data**: TanStack Query on top of a typed client generated from the server's OpenAPI spec (`packages/api-schema`, via `openapi-typescript` + `openapi-fetch`).
- **Real time**: the `phoenix` npm client joins `feed:<user_id>` and `notifications:<user_id>` channels.
- **Auth storage**: bearer token in `expo-secure-store` on native; httpOnly cookie session on web.
- **Video uploads**: the client asks the server for a one-time direct-upload URL and uploads straight to the provider. Video bytes never pass through Phoenix.

## Server (`apps/server`)

### Phoenix contexts

| Context | Responsibility |
|---|---|
| `Accounts` | users, profiles, auth identities (magic link, passkeys, Apple, Google), sessions/tokens, consents |
| `Content` | content items, typed payloads, topics, embeddings, upload lifecycle |
| `Social` | follows, blocks, mutes, likes, comments (as content items) |
| `Events` | append-only engagement event ingestion (batched from the client) |
| `Feed` | candidate generation, ranker, per-user Feed processes, impressions |
| `Transparency` | explanation queries, dashboard aggregates, user algorithm settings |
| `Moderation` | reports, queue, actions, hash matches, NCMEC/DMCA workflows |
| `Ledger` | double-entry accounts and entries, revenue periods, accrual jobs |
| `Billing` | subscriptions (Stripe / RevenueCat webhooks). Later phase. |
| `Ads` | campaigns, ad slot serving outside the ranker, click IDs, conversion postbacks. Later phase. |
| `Payouts` | Stripe Connect onboarding, creator (later user) payouts. Later phase. |

### Background jobs (Oban queues)
- `media`: provider webhooks → mark ready → enqueue `ml`.
- `ml`: call the Python service for topics, embeddings and moderation scores → write the results.
- `affinity`: update user topic affinities from engagement events (incremental + periodic decay).
- `ranking`: refresh trending pools and co-engagement aggregates.
- `ledger`: per-period accruals (later).
- `safety`: hash matching, report routing.

### API style
- REST/JSON, described with `open_api_spex`. The spec is exported to `packages/api-schema` and the TS client is regenerated from it.
- Channels for server push: re-ranked feed pages, notifications, upload status.
- Cursor pagination on all lists.

## Data model (Postgres)

```
users ─┬─ profiles
       ├─ auth_identities          (provider, subject)
       ├─ consents                 (version, scopes, granted_at, revoked_at)
       ├─ user_topic_affinity      (topic_id, score, evidence_count, updated_at)
       └─ user_algorithm_settings  (feature_key, weight, hard_off)

content_items (id, author_id, kind, parent_id, root_id, status, visibility, created_at)
   ├─ short_videos   (content_id, provider, asset_id, playback_id, duration_ms, aspect)
   ├─ text_posts     (content_id, body)
   ├─ content_topics (content_id, topic_id, confidence, source: creator|model|moderator)
   └─ content_embeddings (content_id, model, embedding vector(N))

topics (id, slug, parent_id, name)      ── hierarchical, seeded from IAB Content Taxonomy

follows, blocks, mutes, likes

engagement_events (id, user_id, content_id, type, value, occurred_at, session_id, consent_version)
   ── append-only, monthly partitions. type ∈ view_start, watch_progress, complete, rewatch, like, share, skip, not_interested

impressions (id, user_id, content_id, served_at, ranker_version, candidate_source,
             final_score, contributions jsonb, settings_snapshot_id)
   ── append-only. Source of truth for "Why am I seeing this?" and for dividend attribution

ledger_accounts (id, owner_type, owner_id, kind)          ── e.g. creator:<id>:pending / :available, user:<id>:accrued, platform:*
ledger_transactions (id, kind, period_id, split_policy_id, reverses_id?, created_at, memo)
ledger_entries (id, transaction_id, account_id, amount_micro bigint, direction)
revenue_periods (id, starts_at, ends_at, status)
revenue_split_policies (id, version, source: subscription|ad, platform_bps, creator_bps, dividend_bps, effective_from)

subscriptions (user_id, provider, status, current_period)            ── later phase
subscription_payments (id, user_id, period_id, gross_micro, fees_micro, net_micro)
subscriber_creator_watch (period_id, subscriber_id, creator_id, qualified_watch_ms)   ── derived at period close

ad_categories (id, slug, parent_id, name)   ── seeded from IAB Ad Product Taxonomy; separate from content topics
ad_campaigns, ad_creatives (advertiser, ad_category_id, billing_model: cpm|cpc|cpa, excluded_topics, video asset via VideoProvider)  ── later phase
creator_ad_settings (creator_id, content_id?, blocked_ad_category_ids, overlay_on, lead_in_on, post_roll_on)
ad_impressions (id, user_id, creative_id, host_content_id, placement: overlay|lead_in|post_roll (later pre_roll|mid_roll for long-form), served_at, viewable_at?, revenue_micro)
creator_earnings (creator_id, period_id, source: subscription|ad, placement?, billing_model?, ad_category_id?, content_id, status: pending|available, amount_micro)
   ── analytics facts derived from the ledger; reconciled to it per period
ad_clicks (id, impression_id, click_id, clicked_at)
ad_conversions (id, click_id, value_micro, reported_at, status: pending|confirmed|reversed)
payout_accounts (owner_id, stripe_connect_id, kyc_status), payouts (id, account_id, amount_micro, status)

moderation_reports, moderation_actions, hash_matches
```

Comments and replies are `content_items` with `parent_id` set and `root_id` pointing to the top of the thread. That gives X- and Reddit-style threading without a separate comments system. Communities come later as a `communities` table plus a nullable `community_id` on `content_items`.

## Recommendation system

### Pipeline (per feed request)
1. **Candidate generation.** Each candidate is labeled with its source:
   - `following`: recent items from followed creators.
   - `topic`: top recent or quality items from the user's highest-affinity topics.
   - `co_engagement`: "people who completed X also completed Y". Starts as a SQL aggregate over recent completions and evolves into a Pixie-style random walk over the user–item bipartite graph.
   - `trending`: per-topic and global velocity pools, refreshed by Oban.
   - `explore`: under-sampled topics, so the profile doesn't narrow into a filter bubble.
2. **Filtering.** Remove seen, blocked, muted, hard-off topics, and anything moderated or unready.
3. **Scoring.**
   `score = Σ_k  w_k(user) · f_k(item, user)`
   - Features: one per topic affinity, creator affinity, source prior, freshness, quality (completion rate), diversity penalty.
   - `w_k` = system default × user override from `user_algorithm_settings`.
4. **Trace.** Every scored item carries
   `contributions: [{feature, topic?, user_weight, value, contribution}]`,
   and the invariant `final_score == Σ contribution` is enforced by a property test.
5. **Impression logging.** Each item served is written to `impressions` along with its contributions, the `ranker_version` and a pointer to a snapshot of the user's settings.

### Live control
Each active user gets a lightweight `Feed` process (started on demand, shut down when idle) that caches ~500 scored candidates and their raw feature values. When the user changes a weight, the process re-scores the cache (multiply and sum, which takes microseconds), re-sorts it and pushes the new page over `feed:<user_id>`. Nothing has to be re-fetched from the database.

### Interest model
- `user_topic_affinity.score` is updated from engagement events with weights (complete > rewatch > like > view; skip and not-interested are negative) and exponential time decay.
- Users can see the evidence count and recent contributing events for each affinity, and edit or delete it.

### Evolution
1. **v1**: hand-tuned default weights.
2. **v2**: learned weights (logistic regression or GBDT), still decomposable into per-feature contributions.
3. **v3**: SimClusters-style community embeddings. These are sparse and interpretable, so each community can be shown to the user as a "topic".
4. **Rust**: an in-memory graph-walk service, added when profiling shows the BEAM is the bottleneck (ADR 0004).

Each version bumps `ranker_version`, so old explanations stay true to the algorithm that produced them.

## Content understanding (Python ML service)
- **Input**: content id plus the provider's download URL or thumbnails, caption and creator topics.
- **Pipeline**:
  - transcript (Whisper)
  - frame + text embeddings (CLIP or similar)
  - topic classification against the taxonomy (zero-shot over embeddings, optionally an LLM pass over caption + transcript)
  - moderation scores
- **Output**: `{topics: [{slug, confidence}], embedding, moderation: {category: score}}`.
- **Calling pattern**: Oban jobs call the service over HTTP, so Oban provides retries and durability. The service itself is stateless.

## Revenue sharing (creators + data dividend)

Revenue is split three ways (platform / creators / viewers) by a versioned, public `revenue_split_policies` row. Every ledger transaction references the policy version it used ([ADR 0009](adr/0009-creator-monetization.md)).

| Revenue | Creators | Viewers (data dividend) |
|---|---|---|
| Subscriptions | **Per subscriber.** Each subscriber's `net × creator_bps` goes to the creators *they* watched, by qualified watch time. | `net × dividend_bps`, shared by contribution units (engagement and impressions that consented data produced). |
| Ads | `ad revenue × creator_bps` to the impression's **host content** creator, for any billing model (CPM/CPC/CPA). | `ad revenue × dividend_bps` attributed to the viewing user. |

- **Purchase attribution is tap-only.** Tapping an ad creates `ad_clicks.click_id`, and the advertiser reports the purchase server-to-server with that ID. Last click wins within 7 days. No pixels, no view-through.
- **Pending → available.** Purchase-based earnings are credited to `creator:<id>:pending` and move to `:available` after the refund window. Refunds and chargebacks post compensating transactions (`reverses_id`), never edits.
- **Period close** (Oban `ledger` queue):
  1. derive `subscriber_creator_watch`
  2. compute the splits
  3. post balanced transactions
  4. publish subscriber receipts ("where your money went") and creator statements
- **Payouts**: Stripe Connect Express. Requires identity and tax onboarding plus a minimum balance. The rails are built for creators first and reused for the dividend.
- **Ranking integrity**: monetization signals never feed the content ranker. Ads fill labeled slots outside it.

### Ad serving ([ADR 0010](adr/0010-ad-placements-and-creator-analytics.md))
1. The content ranker builds the feed page. It never sees monetization inputs.
2. For free-tier viewers, the `Ads` context runs a **decision pass over the finished page**:
   - It checks the viewer's ad budget: one lead-in per N minutes, a minimum number of content items between video ads, and video ads per session.
   - It checks the host creator's `creator_ad_settings` and the advertiser's excluded topics.
   - It assigns `overlay` / `post_roll` creatives to host items, and inserts `lead_in` feed items **paired** with the host that follows them. If a live re-rank drops the host, its lead-in is dropped too.
   - Premium viewers skip this pass entirely.
3. **The client renders**:
   - a lead-in as its own swipe-to-skip feed clip labeled "Ad · supports @creator"
   - the overlay chip during playback
   - the post-roll on first completion, in place of the loop, skippable after a few seconds

   It preloads ad media and reports **viewability** (video: ≥50% in view for 2 continuous seconds; overlay: 1 second).
4. **Only viewable impressions** are billed and credited to the host creator.
5. **Creator analytics** read `creator_earnings`:
   - subscription vs ad split
   - ads broken down by category, placement and type
   - per-video earnings
   - Aggregates only; small subscriber counts are bucketed.
- **Built now**: consent versioning, events, impressions, ledger schema, "estimated value" page.
- **Built later**:
  - Creator monetization: Phase 3.
  - Dividend payouts: after legal review, with sybil and bot-farm detection.

## Trust & safety
- **Upload path**: hash matching (Cloudflare CSAM Scanning Tool / PhotoDNA) → on a match, block, preserve evidence and file an NCMEC report.
- **ML moderation scores**: high scores go to human review, and the content is hidden pending review above a threshold.
- **Reports**: a report creates a `moderation_reports` row and enters the queue. Every action is recorded in `moderation_actions` as an audit log.
- **DMCA**: designated agent, takedown intake, counter-notice, repeat-infringer policy.

## Testing strategy
- **Server**: ExUnit plus StreamData property tests. Key properties:
  - `score == Σ contributions`
  - each ledger transaction's entries sum to zero
  - the Feed process re-ranks deterministically
  - `creator_earnings` reconciles to the ledger each period
  - the content ranker's output is identical with and without the ads pass (ranking integrity)
- **Client**: Jest + React Native Testing Library.
- **End to end**:
  - Maestro (mobile) and Playwright (web) for sign-in → upload → feed → "Why this?" → adjust weight → feed changes.
  - The upload → provider webhook → HLS playback path, against the provider's test mode.
- **CI**: runs everything above on each push.
