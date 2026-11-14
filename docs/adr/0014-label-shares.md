# ADR 0014: Topic labels share an item (ranker v1.1)

- **Status:** Accepted
- **Date:** 2026-11-06
- **Amends:** [ADR 0012](0012-interest-model-and-controls.md) (the topic contributions, the slider guarantee and `topic_snapshot`)

## Context
An outside review of ranker v1 found that a multi-label item's topic signal is **summed**:
- **Ranking:** `Ranker.topic_contributions` added one `topic_affinity` row per label, each worth `affinity × confidence`. A slider added one `topic_preference` row per label too.
- **Learning:** `Interests.topic_snapshot` gave each label its full confidence. It took the max only *per topic*, so a child and its parent reached twice counted once.

So a video with three labels the viewer likes got about 3× the topic signal of one labeled precisely. A tier-2 topic labeled together with its own parent counted the same interest twice. The same video also taught the viewer's profile three topics at full strength. Creators (up to 3 labels each at confidence 1.0) are paid in reach for always using every label. Phase 1b makes it worse: model labelers emit many labels, most of them at low confidence.

Options considered, all of which keep the score a weighted sum:

| Option | Problem |
|---|---|
| **Max over labels** | Sliders become only weakly monotonic: raising Cooking does nothing to an item whose best label is Travel. Adding a label can still only help, so the incentive to use every label stays. |
| **Confidence-weighted mean** | Drops absolute confidence: a lone label at 0.3 would count as certain. |
| **Cap the label count** | Arbitrary, and three labels at 1.0 still triple the signal. |
| **Shares capped at a total of 1** (chosen) | See below. |

## Decision
**Each label gets a share of the item:**

```
share(label) = confidence / max(1, Σ confidences of the item's labels)
```

- One label at full confidence keeps its whole weight, so single-label items rank exactly as before.
- Three labels at 1.0 get ⅓ each. A child labeled with its parent gets ½ each and no longer counts twice.
- A lone low-confidence label keeps its low weight. Shares never sum past 1.
- `TSpec.Feed.LabelShares` computes it, summing in sorted order so input order doesn't matter.

**Ranking** (`Feed.Ranker`):
- `topic_affinity`'s value is `affinity × share`, and `topic_preference`'s value is `share`.
- Every topic row in the trace also stores `confidence` and `label_share`, so the "Why?" sheet can say how much of the item the topic stands for.
- **The slider guarantee still holds:** a topic's slope in `m` is `share × (w_aff·a + w_pref)`. Since `share > 0` and `w_pref > w_aff`, it is always positive. `Defaults`' compile-time check is unchanged.

**Learning** (`Interests.topic_snapshot/3`):
- The order is: compute shares from the item's own labels, give a tier-2 label's parent `parent_share ×` the child's **share**, then take the max per topic.
- So an item teaches a profile in the same proportions it is ranked by.

**Hard-off keeps raw confidence:**
- `Ranker.eligible?/3` and the SQL filter in `Candidates` compare each label's confidence, never its share, with the 0.5 threshold.
- Otherwise three labels at 1.0 (share ⅓ each) would slip a switched-off topic through.
- A property test covers this, and a mutation check breaks it (review packet I29, M29).

**Diversity** keeps using the highest-confidence label as an item's primary topic. Shares preserve the ranking of a single item's labels, so the choice is the same.

**`ranker_version` becomes `v1.1`.** It is still the hand-tuned v1 family, and `docs/architecture.md` reserves v2 for learned weights. Stored v1 traces keep explaining themselves as they were; they simply have no `label_share`.

## Consequences
- **Profiles mix two scales for a while.** Views before this change credited full confidence per label, and later views credit shares. No migration: the snapshots are frozen per view, and the 14-day half-life fades the old credit out (a quarter of it is left after four weeks).
- **Learning per view is slower for multi-label items.** A view of a three-label video now credits each topic a third as much. That's the intent, but it lowers every multi-label item's learning rate, which the affinity calibration question in `docs/open-questions.md` should take into account.
- **Phase 1b dilution.** Many low-confidence model labels would shrink a creator's own label's share (1.0 + 0.3 + 0.2 + 0.4 gives the creator's label a share of 0.53). The ML milestone must settle confidence calibration, and probably a floor below which a label doesn't count for ranking or learning, before model labels reach `content_topics`. Hard-off is unaffected.
- **Fewer reasons to over-label.** Using every label now spreads an item's topic signal rather than multiplying it.

## Related, not decided here
The same review found that the `quality` feature (smoothed completion rate) favors short videos. Comparing completion with a duration-bucket baseline was deferred, because on a beta catalog the baseline would equal its prior for months. It's in `docs/open-questions.md`, to be decided before the private beta. The text-post bug it surfaced is fixed in this change: text posts can't be "completed", so their views no longer count against their quality.
