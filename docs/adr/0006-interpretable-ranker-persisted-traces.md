# ADR 0006: Interpretable ranker with persisted traces

- **Status:** Accepted
- **Date:** 2026-10-20

## Context
Algorithm transparency is a core pillar. Users must be able to see *why* an item was recommended and change the weights that put it there. Black-box end-to-end deep rankers can't give faithful explanations. Explanations computed after the fact are wrong too: by the time a user clicks "Why?", their affinities have already shifted.

## Decision
- **The score decomposes.** `score = Σ_k w_k(user) · f_k(item, user)`, using named features (topic affinities, creator affinity, source prior, freshness, quality, diversity penalty).
- **User controls override `w_k`** (soft) or apply hard filters (topic off).
- **Every scored item carries a trace**: `[{feature, topic?, user_weight, value, contribution}]`.
- **The trace is saved when the item is shown**, in `impressions` along with `ranker_version` and a settings snapshot. "Why am I seeing this?" reads that saved row and never recomputes.
- **Invariant**: `final_score == Σ contribution`, enforced by a property test.
- **Future rankers must stay decomposable**: learned linear models, GBDT with per-feature contributions, or interpretable community embeddings.

## Consequences
- Explanations are exactly true to the algorithm that produced them.
- `impressions` grows fast, so it's partitioned by time with a retention policy. Raw rows can be aggregated after N months while summary explanations are kept.
- The same impression log is the attribution source for the data dividend (ADR 0007).
- We give up some ranking quality compared with opaque deep models. That trade is deliberate and is the product's thesis.

## Note on the trace shape
A fixed struct (e.g. `WatchTimeBonus`, `CategoryMatch` fields) was considered and rejected. A generic contribution list handles new features, many topics and user overrides without schema changes.
