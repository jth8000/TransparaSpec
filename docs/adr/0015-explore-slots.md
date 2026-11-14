# ADR 0015: Explore slots (ranker v1.2)

- **Status:** Accepted
- **Date:** 2026-11-13
- **Amends:** [ADR 0012](0012-interest-model-and-controls.md) (what the Explore source slider means)

## Context
`explore` was a candidate source like any other: random recent items in topics the user had no history with. Its items were then scored by the same function they were meant to counterbalance:
- `explore` has the lowest source prior (0.1);
- its items have zero learned topic affinity by construction.

Once a profile forms, an explore item almost never wins on score. It surfaces only when the other pools run dry, and a small beta catalog hides that. A review on 2026-11-06 also found that the source's SQL accepted any item with *one* unfamiliar label, so a Cooking video with one extra label counted as exploring for a Cooking fan.

Exploration matters for a recommender: without it the profile only ever confirms itself (a "filter bubble"), and the system never learns about interests the user hasn't shown yet.

Options considered:

| Option | Problem |
|---|---|
| **An explore bonus** (a feature in the score) | It must be large enough to beat a mature profile, so it lifts every explore item everywhere in the feed. Fragile to tune, and it still guarantees no rate. |
| **Reserved slots** (chosen) | A placement rule outside the score, which has to be shown as one. |

## Decision
**Every `round(10 / m)`-th feed position is an explore slot**, where `m` is the Explore slider (default 1×, so every 10th).
- Positions count across the whole feed session (`Ranker.rank/5`'s `:start_position`; the session passes the length of what it has served). Pages and live re-ranks keep the spacing.
- **The slot is filled inside the greedy diversity pass**, by the explorable item with the best score plus diversity penalty. The diversity window then sees that pick, so the next item can't repeat its creator for free.
- If no explorable item is left, the slot is filled normally.
- Slots exist only within the diversity depth (50), which every served page falls within.

**Explorable:** the item has labels, and none of them is a *blocked* topic (`Ranker.explore_blocked_topic_ids/3`). A topic is blocked if the user knows it or its parent. The user knows a topic when:
- its learned value is at least **0.05** from 0, either way. Affinity rows stay in the map forever, however far they've decayed, so "has a row" can't be the test: the explore pool would only ever shrink. One finished view fades below 0.05 in about five weeks.
- its slider, or its parent's, is anything but 1×. A topic the user boosted isn't "something new".
- it was forgotten within the last **30 days** (`Ranking.features/3`'s `known_topic_ids`). After that it can be offered again.

The tier-2 rule is strict on purpose: a Fitness item for someone who loves Healthy Living is nearby, not new. The explore source's SQL uses the same blocked set.

**The Explore slider sets the rate, and only the rate.** The explore source's prior is always `0.1 × 1`, so one control doesn't move two things. At 0 there are no slots and the explore source doesn't run. Non-personalized mode has no slots.

**Transparency:**
- A slot changes where an item goes, never its score. The trace and `final_score == Σ contributions` are unchanged.
- The impression gets a nullable `placement` column (`"explore"`), returned by `GET /api/impressions/:id`.
- The "Why?" sheet says "Shown to broaden your feed: this spot is kept for a topic you haven't watched".

**`ranker_version` becomes `v1.2`.**

## Consequences
- **Order is no longer score order plus diversity alone.** Every position that isn't score-ordered is recorded on its impression, so "Why?" can still say exactly why the item is there.
- **Cold start:** for a user with no history, every labeled item is explorable. The slot then takes the best item anyway and labels it, which is true but uninformative.
- **Diversity already explores a little.** In small catalogs the topic-repeat penalty lifts a lone item from another topic well before its slot (a controller test had to account for this). Slots are what guarantees a rate once the catalog is large.
- **Unlabeled items are never explorable.** They have nothing to be new about. Phase 1b's model labels will make most items labeled.
- **The numbers are guesses** (every 10th, 0.05, 30 days), listed in `docs/ranking.md`'s defaults table for tuning from beta data.
