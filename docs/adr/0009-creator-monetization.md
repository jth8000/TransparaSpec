# ADR 0009: Creator monetization

- **Status:** Accepted
- **Date:** 2026-10-20
- **Extends:** ADR 0007 (ledger and consent)

## Context
Creators need to earn money. Two goals:
- **Ad earnings that reward real outcomes.** Creators should earn more when their audience actually buys something through ads on their content.
- **A subscription share with no view or follower threshold.** Unlike YouTube's or TikTok's partner programs, small creators should earn without first hitting a minimum.

Any design has to resist fraud (fake accounts, bot views) and fit T-Spec's transparency and privacy pillars. Revenue is now split three ways: platform, creators, and viewers (the data dividend).

## Decision

### 1. Subscriptions: per-subscriber allocation
For each billing period and each paying subscriber:
1. `net = gross − actual store/processor fees`. Fees come from RevenueCat / Stripe.
2. Split `net` by the active **revenue split policy** into `creator_share`, `dividend_share` and `platform_share`.
3. Divide `creator_share` among the creators *that subscriber* watched, in proportion to **qualified watch time**. These views don't count:
   - creators watching themselves
   - sessions flagged as bots
   - views under a minimum duration
   - content later removed by moderation
- **No eligibility threshold.** A creator watched by a single subscriber earns that subscriber's share.
- **Fraud resistance comes from the design.** Views from non-subscribers or bots earn nothing. To farm money you'd have to pay subscriptions costing more than they return.
- **Subscribers can see where their money went**: "your $X went to these creators."

### 2. Ads: a share of all ad revenue on a creator's content
- Each ad impression is attached to a **host content item** (`host_content_id`) when it's served.
- The host creator earns `creator_ad_share` of the revenue that impression produced, **whatever the billing model**:
  - CPM (pay per view)
  - CPC (pay per click)
  - CPA (pay per purchase)
- Advertisers who pay per purchase naturally reward creators with high-intent niche audiences.

### 3. Purchase attribution: taps only
- When a viewer taps an ad, we issue a one-time **click ID**.
- The advertiser reports any resulting purchase **server-to-server** with that click ID. Last click wins, within a window (default 7 days).
- **No tracking pixels, no view-through attribution, no cross-site tracking of users.**
- Purchase-based earnings stay **pending** through a refund window (default 30 days) before becoming available. Refunds and chargebacks are reversed with compensating ledger entries, never by editing existing ones.

### 4. A public, versioned revenue split
- `revenue_split_policies` stores the percentages in basis points, per revenue source, each with an effective date.
- Every ledger transaction references the policy version it used.
- The split is shown to everyone: subscription receipts break down where the money went, and creator earnings statements show amounts per source.

### 5. Money never quietly affects ranking
- Monetization signals (earnings, ad performance, subscription status) are **not ranker features**.
- Ads are served in **labeled slots outside the content ranker**.
- If a commercial signal ever enters ranking, it must appear in the explanation trace like any other feature (ADR 0006).

### 6. Eligibility and payouts
- **No view or follower minimum to earn.**
- **To withdraw**, a creator needs:
  - identity and tax onboarding via Stripe Connect Express
  - a minimum balance, so per-payout fees don't eat earnings
  - content in good standing: pending earnings on content removed for policy violations are forfeited
- Ledger accounts per creator: `creator:<id>:pending` → `creator:<id>:available` → paid out.

## Consequences
- **Creator payouts will probably be the first real money T-Spec moves.** They're a well-understood legal model, unlike the user dividend. The Stripe Connect onboarding, tax-form handling and payout jobs built for creators get reused when the dividend launches.
- **The per-subscriber split runs as a period-end Oban batch** over `engagement_events` (qualified watch time per subscriber–creator pair). That's well within Postgres's reach at beta and early scale.
- **Early creator earnings will be small**, because the subscriber base is small. The public split makes that honest rather than confusing.
- **Ads need a placement format that has a host content item.** Resolved by [ADR 0010](0010-ad-placements-and-creator-analytics.md): overlay link, post-roll, and a labeled lead-in clip before the host video.

## Alternatives considered
- **Global pro-rata pool** (Spotify / YouTube Premium style). Favors large creators and is more exposed to bot views.
- **A flat equal share for every creator.** Farmed immediately by fake accounts.
- **Purchase-only ad earnings.** Too sparse; most creators would earn nothing.
- **View-through attribution.** Needs cross-site tracking pixels, conflicts with the privacy pillar and Apple's tracking rules.
