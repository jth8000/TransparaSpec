# ADR 0010: Ad placements and creator revenue analytics

- **Status:** Accepted
- **Date:** 2026-10-20 (revised the same day before commit: the short-form pre-roll bumper was replaced by a labeled `lead_in` feed clip)
- **Extends:** ADR 0009 (resolves its "host content item" open question)

## Context
ADR 0009 credits a creator for ads on their content, which means every ad needs a **host content item**. In a TikTok-style feed, ads are usually their own anonymous swipe slot and belong to no one.

Creators also want to understand their revenue: how much comes from subscriptions versus ads, and which ad categories it comes from.

## Decision

### Placements (short-form)
Every ad is attached to one host video and credited to that video's creator.

| Placement | Behavior | Who sees it |
|---|---|---|
| `overlay` | A tappable chip near the caption, labeled "Ad/Sponsored", shown while the video plays. A tap creates the click ID (tap-only attribution, ADR 0009). | Free tier |
| `post_roll` | Plays on the **first completion, instead of the loop**. Skippable after a few seconds. No post-roll if the viewer swipes away before the end, so creators earn ad revenue from viewers who finished. | Free tier |
| `lead_in` | Its **own full-screen feed clip**, placed immediately before its host video. **Swipe to skip at any time**, with no forced wait. Labeled **"Ad · supports @creator"**, where @creator is the host coming up next. | Free tier |

- **`lead_in` is never secretly attached.** The label always names the creator it supports. That turns the attachment into a transparency feature instead of a hidden mechanic, and satisfies FTC ad-disclosure rules.
- **A `lead_in` and its host move as a pair.** If a live re-rank removes the host video, its lead-in is removed too, so the label never names a creator who isn't next.
- **One ad budget per viewer** covers all placements:
  - at most one `lead_in` per N minutes
  - **never two video ads in a row** (e.g. A's post-roll followed by B's lead-in): a minimum number of content items between video ads
  - a cap on video ads per session

  That keeps free users at a predictable ad level.
- **`pre_roll` is reserved for long-form video** (with `mid_roll`), where those formats are standard. Short-form never forces a wait before the video the viewer chose.
- **Premium is fully ad-free**: no overlays and no video ads. Creators earn from Premium viewers through the per-subscriber share (ADR 0009).
- **Ads are chosen at serve time, after the content ranker** has built the feed. A video's ad eligibility or ad performance never influences whether it gets recommended. Viewers get "Why this ad?".
- **Only viewable impressions count**, for both advertiser billing and creator credit. Media Rating Council baseline: at least half the ad in view for 2 continuous seconds for video, 1 second for overlays.
- **Ad videos go through the same `VideoProvider`** as regular videos (ADR 0005).
- **The `placement` enum is extensible**: later `pre_roll` and `mid_roll` (long-form), `community_banner`.

### Creator ad controls
- **Block ad categories**, e.g. gambling or alcohol. Categories come from an ad-category taxonomy seeded from the IAB Ad Product Taxonomy, separate from content topics.
- **Turn placements off**: lead-in, post-roll or overlay, per account with optional per-video overrides. Category blocks matter more for lead-ins, because the creator's name appears next to the advertiser's brand.
- **Advertisers can exclude content topics** (brand safety).
- **The ad server honors both sides.** The dashboard tells creators when their controls reduce how often ads fill their videos.

### Creator revenue analytics
- **Earnings facts.** `creator_earnings` holds one row per creator × period × dimension set:
  - source: subscription or ad
  - placement
  - billing model: CPM, CPC or CPA
  - ad category
  - video
  - status: pending or available
  - amount in micro-units
- **Derived from the ledger, which stays the source of truth.** A reconciliation test checks that `Σ creator_earnings == Σ creator ledger credits` per period.
- **Dashboard drill-down:**
  - Revenue = X% subscriptions (Premium viewers) + Y% ads.
  - Ads, broken down by **category**: donut with the top 5 plus "Other", and a table beside it.
  - Ads, broken down by **placement** and by **type**: views, clicks, purchases.
  - Per video: subscription share and ad share.
  - Pending and available balances.
- **Privacy:**
  - Creators see only aggregates, never which viewers or subscribers generated revenue.
  - Small subscriber counts are bucketed, e.g. "fewer than 10".

## Consequences
- Creators are paid fairly for the attention their own videos earn. Post-rolls reward videos people finish.
- **Client work:**
  - the feed list must support ad items (lead-ins) paired with their host video
  - the player must swap the loop for the post-roll on first completion
  - ad media is preloaded
  - viewability is measured, since billing depends on it
- **Lead-ins are skippable instantly**, and an ad swiped away within 2 seconds isn't viewable, so it earns nothing. Earnings per ad shown will be lower than with forced pre-rolls. That's the deliberate cost of not annoying viewers.
- The ad server is a separate step after the content ranker. That keeps ranking integrity checkable: the ranker never sees monetization inputs.
- One extra table (`creator_earnings`), kept in sync with the ledger and protected by the reconciliation test.

## Alternatives considered
- **Anonymous in-feed ad slots**, TikTok style. There's no fair way to credit a creator.
- **Pre-roll on short-form**, either a skippable standard pre-roll or a bumper of 6 seconds or less. Rejected: a forced wait before a 15–60-second video the viewer chose is too annoying.
- **An unlabeled lead-in that's secretly credited to the next creator.** Rejected: a hidden attachment contradicts the transparency pillar.
- **Premium hides video ads but keeps overlays.** Muddies what "ad-free" means.
