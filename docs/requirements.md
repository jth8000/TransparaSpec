# T-Spec Requirements

TransparaSpec (T-Spec) is a social / video-sharing platform built on two pillars that set it apart:

1. **Data dividend.** Users get paid tiny amounts for the revenue their data generates. This won't be live at launch, but the system records everything needed to switch it on later (see [ADR 0007](adr/0007-ledger-and-consent-from-day-one.md)).
2. **Algorithm transparency and control.** Users can see which topics are being recommended to them and *why*. They can adjust the algorithm (e.g. turn off the "fitness" weight) and watch the feed re-rank live.

Launch target: **private beta, US only**, hundreds to low thousands of users.
Revenue model: **ads + subscriptions**. Neither is enabled in the beta.

Revenue is shared three ways: **platform, creators and viewers** (the data dividend). The split is versioned and public ([ADR 0009](adr/0009-creator-monetization.md)). **Money never quietly affects ranking.**

## Content scope

| Now (MVP) | Later |
|---|---|
| Short-form video (≤3 min, vertical) | Long-form video |
| Short text posts | Link posts, quote posts / reposts |
| Threaded comments | Reddit-style communities, X-style threads |

Everything is built on one polymorphic content model, so new kinds plug into the existing feed, ranker and transparency features ([ADR 0008](adr/0008-polymorphic-content-model.md)).

## Functional requirements: MVP (private beta)

### Accounts
- Sign up and sign in with email magic link, passkeys, Sign in with Apple, or Google.
- Profile: unique handle (pseudonymous), display name, avatar, bio.
- 13+ age gate at sign-up (COPPA).
- Data export and account deletion.

### Content
- Upload short video directly to the video provider from the client. Show processing state.
- Create text posts.
- Captions. Creators can pick topics, and the model adds topics of its own.
- Edit captions/topics. Delete content.

### Feeds
- **For You**: ranked by the explainable ranker.
- **Following**: accounts the user follows, reverse-chronological.
- **Non-personalized mode**: a toggle that turns off profiling (chronological / trending only).
- Vertical swipe player with preloading on native and web.

### Engagement
- Like, comment (threaded), share link, follow/unfollow, "not interested".
- Block and mute.

### Transparency
- **"Why am I seeing this?"** on every feed item. It shows the stored breakdown of contributions to the score: candidate source, and each feature's weight, value and contribution.
- **Algorithm Dashboard**:
  - topic mix of the user's feed over time
  - top drivers of their recommendations
  - their inferred interest profile (topic affinities), including how each affinity was learned

### Control
- Per-topic weight slider and a hard "off" switch.
- Per-source weights (following / topic / co-engagement / trending / explore).
- Reset to defaults.
- Changing a control re-ranks the feed **live** (pushed over WebSocket, no reload).
- Users can edit or remove inferred interests.

### Notifications
- In-app, real time (likes, comments, follows).
- Push notifications later in the beta.

### Trust & safety
- Report content or a user. Moderation queue with actions and an audit log.
- CSAM hash matching on uploads, with mandatory NCMEC reporting.
- DMCA designated agent, takedown and counter-notice flow.
- Moderation *scores* from the ML service go to human review. Content is never auto-approved by a boolean.

### Data value (late beta, optional)
- "Your data's estimated value" page backed by ledger accruals. No money moves.

## Functional requirements: later
- Ads, with **ad transparency** ("why this ad") that mirrors the content explanations ([ADR 0010](adr/0010-ad-placements-and-creator-analytics.md)):
  - **Placements** on a host video:
    - an overlay link near the caption
    - a post-roll on first completion, instead of the loop
    - an occasional **lead-in**: its own swipe-to-skip feed clip right before the host video, labeled "Ad · supports @creator"
  - **No forced pre-roll on short-form.**
  - **Free tier only**, under one ad budget per viewer: one lead-in per N minutes, never two video ads in a row. Premium is fully ad-free.
  - **Chosen after the content ranker.** Ad eligibility never influences recommendations.
  - **Billing and creator credit** count only viewable impressions.
  - **Creator controls**: block ad categories and turn off placements, per account or per video.
- Subscriptions: ad-free tier and extra controls. Stripe on web; App Store / Play billing on mobile, unified via RevenueCat.
- **Creator monetization** ([ADR 0009](adr/0009-creator-monetization.md)):
  - **Subscription share**: each subscriber's creator share goes to the creators *they* watched, by qualified watch time. No view or follower threshold.
  - **Ad share**: a percentage of all ad revenue earned on the creator's content (per view, per click or per purchase).
  - **Purchase attribution**: taps only. The advertiser reports the purchase server-to-server with a one-time click ID. No tracking pixels.
  - **Pending → available**: earnings become available after a refund window.
  - **Payouts**: via Stripe Connect Express, after identity and tax onboarding, above a minimum balance.
  - **Creator revenue analytics**: X% from subscriptions (Premium viewers) and Y% from ads. Ads drill down by category (donut, top 5 + Other, with a table), placement and type (views/clicks/purchases). Shows per-video earnings and pending/available balances. Aggregates only; small subscriber counts are bucketed.
  - **Subscriber receipts**: "where your money went".
- **Payouts** of the data dividend. Gated on legal review; needs KYC, tax reporting, minimum thresholds and anti-sybil defenses.
- Long-form video, communities, search, DMs, creator analytics.

## Non-functional requirements

| Area | Requirement |
|---|---|
| Latency | Server-side p95 under 300 ms for a feed page. Video starts in under 1 s on good connections (HLS via CDN). |
| Live control | Re-ranked feed pushed under 500 ms after a control change. |
| Durability | Engagement and impression events are append-only and never lost. Every event records the consent version in force. |
| Explanation fidelity | Explanations are **exact**: persisted when the item is shown, never recomputed later. `final_score == Σ contributions`. |
| Money | Integer **micro-units** only (no floats). Double-entry ledger; each transaction's entries sum to zero. Every revenue transaction references the split-policy version it used. Reversals are compensating entries, never edits. |
| Ranking integrity | Monetization signals (earnings, ad performance, subscription status) are not ranker features unless they show up in the explanation trace. |
| Privacy | Minimal PII; pseudonymous by default. Real identity collected only for payouts. Data export and deletion from day one (CCPA-style). |
| Cost | Beta infrastructure costs in the low hundreds of $/month. |
| Portability | Video provider, ML service and ranker sit behind interfaces so they can be swapped or rewritten (e.g. in Rust) without changing callers. |
