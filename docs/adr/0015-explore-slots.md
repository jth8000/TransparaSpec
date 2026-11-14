# ADR 0015: Explore slots (ranker v1.2, amended in v1.3)

- **Status:** Accepted
- **Date:** 2026-11-13 (amended the same day after review: see [the amendment](#amendment-ranker-v13))
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

**Explorable** (as amended in v1.3): the item has labels, and none of them is a *blocked* topic (`Ranker.explore_blocked_topic_ids/3`). Topics are blocked by **tier-1 family** (a tier-1 topic and its subtopics): a whole family is blocked when the user knows any topic in it. The user knows a topic when:
- its learned value is at least **0.05** from 0, either way. Affinity rows stay in the map forever, however far they've decayed, so "has a row" can't be the test: the explore pool would only ever shrink. One finished view fades below 0.05 in about five weeks.
- the feed session has shown the client an item labeled with it (`Session`'s `seen_topic_ids`, restored from stored exposures on rebuild). The learned value only catches up when the session recomputes its features, at start or on a settings change.
- its slider, or its parent's, is **below** 1×.
- it was forgotten within the last **30 days** (`Ranking.features/3`'s `known_topic_ids`). After that it can be offered again.

Blocking whole families is strict on purpose: a Fitness item for someone who loves Healthy Living is nearby, not new. The explore source's SQL uses the same blocked set, including inside a session: its first gather, its refills and its ranking all add the seen topics through one helper (`Session.ranking_features/1`).

**No slots until the user knows some topic** (the blocked set is empty). With the session's seen topics, slots start once the client has shown its first labeled item.

**The Explore slider sets the rate, and only the rate.** The explore source's prior is always `0.1 × 1`, so one control doesn't move two things. At 0 there are no slots and the explore source doesn't run. Non-personalized mode has no slots.

**Transparency:**
- A slot changes where an item goes, never its score. The trace and `final_score == Σ contributions` are unchanged.
- The impression gets a nullable `placement` column (`"explore"`), returned by `GET /api/impressions/:id`.
- The "Why?" sheet says "Shown to broaden your feed: this spot is kept for a topic that's new to you". When the stored trace has a positive `topic_preference` row, it says "a topic you boosted but haven't watched lately" instead. It reads that from the trace and recomputes nothing.

**`ranker_version` becomes `v1.2`, then `v1.3` with the amendment.**

## Consequences
- **Order is no longer score order plus diversity alone.** Every position that isn't score-ordered is recorded on its impression, so "Why?" can still say exactly why the item is there.
- **Cold start:** a user who knows no topic gets no slots (v1.3). Until then every item is effectively exploration.
- **Other devices:** a session only knows what *its* client has shown. Another device's session picks the topic up when it recomputes its features (start, settings change).
- **A topic just discovered keeps its learned boost.** Once the client shows a Travel item from a slot, Travel's family is blocked from slots, so Travel has to compete on score. Its learned interest gets there because sessions refresh their features when the affinity worker applies views (ADR 0011, "When the learned profile changes"). Before that refresh existed, Travel dropped out for the rest of the session.
- **Whole families are coarse.** Some tier-1 areas are large (Sports has dozens of subtopics), and each shown item can block up to three families. A long session can run out of explorable families, and then slots fall back to normal picks: the rate is "up to" one in ten. How often that happens is measurable from stored impressions (slot positions without an explore placement), and is an open question for beta.
- **Diversity already explores a little.** In small catalogs the topic-repeat penalty lifts a lone item from another topic well before its slot (a controller test had to account for this). Slots are what guarantees a rate once the catalog is large.
- **Unlabeled items are never explorable.** They have nothing to be new about. Phase 1b's model labels will make most items labeled.
- **The numbers are guesses** (every 10th, 0.05, 30 days), listed in `docs/ranking.md`'s defaults table for tuning from beta data.

## Amendment: ranker v1.3
A review of v1.2 (2026-11-13) found four problems, all fixed in v1.3:

1. **Nudging up a new topic made you see less of it.** v1.2 counted any slider off 1× as known, to avoid calling a boosted topic "new". So someone who liked a Travel video from a slot and moved Travel to 1.25× took Travel out of the slots. The boost (1.5 × 0.25 ≈ 0.375) is rarely enough to win on score against an established profile, so "a bit more Travel" became roughly none, right when "Why?" invites the user to act. Now only sliders **below** 1× block. The wording problem is solved in "Why?" instead (see Transparency). A property checks that boosting a topic never changes the blocked set.
2. **"New to you" could go stale mid-session.** A session recomputes its features only at start and on a settings change. Someone who watched three Travel items from slots in one long scroll still had Travel counted as new, and later impressions would store that claim. The session now adds the topics of items its client has shown to the known set.
3. **Cold start:** with nothing known, every item is "new" and the label says nothing. No slots until something is known.
4. **Parents of known topics:** a known tier-2 topic didn't block its tier-1 parent, which gets only half the learning and fades first. Blocking whole families fixes this and keeps the rule simple to state. The wording also moved from "haven't watched" to "new to you", because a topic watched once becomes explorable again after about five weeks.
