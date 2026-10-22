# Open Questions

Undecided items. When one is resolved, record the answer here and write an ADR if it shapes the architecture.

## Product
- [ ] **Do ad-free subscribers still accrue dividends** for their data being used in ranking? (Affects the attribution model; ADR 0007.)
- [ ] **Split percentages** (platform / creator / dividend) for subscriptions and for ads. Should they differ by source?
- [ ] **Subscribers who watch no creators** in a period: where does their creator share go (platform, carried over, or a global pool)?
- [x] ~~**Ad placement format**~~ Overlay link + post-roll on first completion + labeled swipe-to-skip lead-in clip paired with the next video. No forced pre-roll on short-form. Free tier only; Premium fully ad-free ([ADR 0010](adr/0010-ad-placements-and-creator-analytics.md)).
- [ ] **Ad budget numbers**: N minutes between lead-ins, the minimum number of content items between any two video ads, video ads per session, and how many seconds before post-rolls can be skipped.
- [ ] **Very short videos**: should post-rolls be suppressed on videos under ~10 seconds, where the ad would be longer than the content?
- [ ] **Subscriber-count bucket threshold** in creator analytics (default: show "fewer than 10").
- [ ] **Qualified watch time rules**: minimum seconds per view, cap per subscriber–creator pair (to blunt loop-watching), and bot-session heuristics.
- [ ] **Refund window** (default 30 days), **click window** (default 7 days), and **minimum payout balance**.
- [x] ~~**Topic taxonomy granularity**~~ IAB Content Taxonomy tiers 1 + 2. The controls show tier 1, and each expands to tier 2. A tier-2 slider overrides its parent's ([ADR 0012](adr/0012-interest-model-and-controls.md)).
- [x] ~~**Hard-off semantics**~~ Hides items labeled with the topic or a descendant at confidence ≥ 0.5. In Phase 1a labels come from creators only, so the guarantee is "nothing *labeled* X", and the UI says so ([ADR 0012](adr/0012-interest-model-and-controls.md)).
- [ ] **Affinity weight calibration**: the per-view deltas (completed +1.0, early skip −0.5, partial +0.8 × fraction), the 14-day half-life and the `tanh(s/3)` squash are hand-tuned guesses. Calibrate them from beta data.
- [ ] **Default ranker weights**: the v1 feature weights in `Feed.Ranker.Defaults` are hand-tuned. Revisit them once there's engagement data (ranker v2 learns them).
- [x] ~~**Creator side**: do creators get a revenue share?~~ Yes: per-subscriber subscription split, a share of all ad revenue, tap-only attribution ([ADR 0009](adr/0009-creator-monetization.md)).
- [ ] **Beta invite mechanics**: waitlist, invite codes, or both?

## Technical
- [x] ~~**Video provider pick**~~ Cloudflare Stream is implemented (Phase 0). Mux remains a drop-in alternative behind `Video.Provider`. A live check is still pending an account.
- [ ] **Topic classification approach**: zero-shot embeddings alone, or plus an LLM pass over caption + transcript? Weigh cost per upload against accuracy.
- [ ] **Impression retention**: how long to keep raw *exposed* impressions before aggregating them? It must cover any attribution and audit window. Served-but-never-exposed impressions are pruned after 30 days ([ADR 0011](adr/0011-feed-sessions-and-live-rerank.md)).
- [ ] **Postgres host** with pgvector: Fly managed Postgres, Neon, or Supabase.
- [ ] **Web sessions**: Phase 0 uses bearer tokens everywhere, with web storing the token in localStorage. Before beta, decide whether web moves to an httpOnly cookie session (XSS exposure vs. one auth path).
- [ ] **Sign-in abuse**: per-IP/email rate limits on `/api/auth/request` and verify. Phase 0 only limits attempts per code.

## Legal / compliance (needs counsel before Phase 3–4)
- [ ] Is paying a data dividend money transmission, a securities issue, or a tax-reporting obligation? Which threshold triggers 1099 forms?
- [ ] State privacy laws (CCPA/CPRA and others) and state age-verification laws affecting a 13+ social app.
- [ ] Wording of the consent records for dividend eligibility.
- [ ] Creator payouts: confirm Stripe Connect Express covers 1099 issuance for creators, and the terms for forfeiting pending earnings on removed content.
- [ ] Advertiser terms for server-to-server purchase reporting: data minimization and what advertisers may send.
