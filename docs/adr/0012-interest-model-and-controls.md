# ADR 0012: Interest model v1 and user controls

- **Status:** Accepted
- **Date:** 2026-10-21 (amended 2026-10-23 and 2026-10-24 after reviews: forget boundaries and no parent fallback for forgotten topics, per-use view eligibility, distinct-user aggregates, no job dedupe; amended 2026-10-29: the mode change locks the user row `FOR NO KEY UPDATE`)

## Context
The ranker (ADR 0006) needs a per-user interest profile: how much this person likes each topic and creator. It also needs controls whose meaning users can rely on:
- topic sliders;
- hard-off switches;
- a non-personalized mode.

Planning surfaced several ways a naive design gives wrong answers:
- **Lost or double-counted events:** walking the event log with a cursor loses events whose transactions commit out of order.
- **Batch double-counting:** applying a delta per batch counts one long view several times.
- **Dead sliders:** a slider that multiplies a learned affinity does nothing at affinity 0, and can *reduce* a topic when the affinity is negative.
- **Delayed workers:** a worker that runs late can learn from viewing done in non-personalized mode.
- **Topic edits:** a creator changing topics mid-view can split one view across topics.
- **Lost updates:** concurrent workers can overwrite each other's affinity updates.

This ADR fixes the semantics that prevent each of these.

## Decision

### Views are the unit of learning
- **`view_id`:** the client mints a UUID each time an item becomes the active, playing item: one *playback episode*. Every `view_start`, `watch_progress`, `complete` and `skip` event carries it.
  - It is distinct from the app-level `session_id` and from the feed session (ADR 0011).
  - Events without a `view_id` are logged but never affect affinity.
- **`view_engagements`** holds one row per view: watched ms, completed, loops, early skip, `learnable`, `topic_snapshot`, `target_delta`, `applied_delta` and `dirty`.
  - It is derived, mutable state; `engagement_events` stays append-only.
  - `Events.record/2` upserts it **in the same transaction as the event insert**, merging monotonically (`GREATEST`, `OR`), recomputing `target_delta` and setting `dirty`.
  - Events and their view state therefore become visible together on commit, or not at all.

### One delta per view
| View outcome | `target_delta` |
|---|---|
| completed | +1.0, plus 0.25 if it looped at least once |
| skipped in under 2 s | −0.5 |
| otherwise | +0.8 × fraction watched |

The fraction is capped at 1, so a long video is worth no more than a short one watched to the same fraction. The weights live in config (`TSpec.Feed.Interests.Weights`) and will be calibrated from beta data.

### Applying views: exactly once, converging, order-independent
The `AffinityWorker` runs one transaction per user:
1. It takes `pg_advisory_xact_lock` for the user, so all of that user's affinity writes happen one at a time. A single lock taken up front also means no deadlocks.
2. It locks the user's dirty views with `FOR UPDATE SKIP LOCKED`.
3. For each view it applies `Δ = target_delta − applied_delta` to the view's snapshot topics and its creator, then sets `applied_delta = target_delta, dirty = false`.

This is correct for each failure case:
- **Retries or a second run:** Δ comes out as 0, so nothing is applied twice.
- **A view spread across many batches:** each run adds only the difference, so the total equals the final target.
- **Late commits:** a late commit is simply a dirty row that becomes visible later. There's no cursor for it to fall behind, so commit order and timing don't matter.

Each committed batch gets its own job. Jobs are deliberately not deduplicated: a unique job could be folded into one that runs before the batch's transaction commits, leaving the new views waiting for the sweep. Extra runs cost almost nothing, since applying is idempotent. The sweep cron only covers jobs that were discarded.

### Decay
Interest fades unless it's reinforced, with a half-life of 14 days:

`s_eff(t) = s · 0.5^((t − as_of) / 14 days)`

- **On read**, the stored score is decayed to the current time.
- **On update**, the old score is decayed forward *before* the delta is added. Adding a delta to an undecayed score would make the whole old score fresh again.
- The update is **one atomic SQL upsert per affinity row**, never a read-modify-write in Elixir:
  - It decays whichever side is older to the newer timestamp, so it stays correct even if a write stamped later commits first.
  - It sets `as_of = GREATEST(old, new)`.
- **Timing skew:** a Δ is counted from when it's applied, not from when the view happened. The gap is minutes, against a 14-day half-life.
- **Feature value:** `tanh(s_eff / 3)`, which lies in (−1, 1).
- **Tier roll-up:** a tier-2 topic also credits its tier-1 parent at half weight.

### Frozen per-view state
- **"View start"** is when the server **accepts the first event of a `view_id`**. Normally that's `view_start`, which the client queues first. If `view_start` is rejected, the first accepted event initializes the view.
  - The client buffers events for up to 10 s, so a creator's topic edit inside that window is captured in the snapshot. That's accepted.
- **`topic_snapshot`** (immutable): the item's effective topic weights at view start (label confidence, including the parent roll-up). All of a view's deltas go to these topics, so relabeling mid-view can't split one view across topics.
- **`learnable`** is set at view start and can only ever go from **true to false**.
  - It is true if the user was personalized at view start.
  - Turning non-personalized mode on sets `learnable = false` on the user's in-progress views, in the same transaction as the setting change.
  - **No race:** `record/2` reads the mode under `FOR SHARE` on the user row, and the mode change takes `FOR NO KEY UPDATE` (not `FOR UPDATE`, which deadlocked against the affinity worker's foreign-key checks). A view therefore can't be inserted as learnable from a stale read of the mode.
  - **The worker reads `learnable`, never the current mode.** Views that aren't learnable are marked applied without touching affinities, so a worker delayed past a mode change still respects the mode the viewing happened under.
  - Before a mode change, the client flushes its event queue and waits for the server's acknowledgement.

### Topic sliders: preference plus affinity, monotonic by construction
Each topic slider `m` runs from 0 to 2, with a default of 1. It has two effects, and each appears as its own contribution in the trace:

| Contribution | Weight | Value |
|---|---|---|
| `topic_affinity` (learned) | `w_aff · m` | affinity × label confidence |
| `topic_preference` (explicit) | `w_pref · (m − 1)` | label confidence |

- "More Cooking" now works for someone with no cooking history, because the preference term doesn't depend on affinity.
- The topic's total is `C(m) = c·(w_aff·m·a + w_pref·(m − 1))`, so `dC/dm = c·(w_aff·a + w_pref)`. Since `a ∈ (−1, 1)`, **requiring `w_pref > w_aff`** makes moving the slider toward "more" *always* raise that topic's score, even when the learned affinity is negative.
  - `Feed.Ranker.Defaults` enforces the inequality at compile time.
  - A property test sweeps the slider.
- The guarantee is about the item's **score**. Its final **position** can also shift because of the diversity pass.

### Hard-off
- **What it hides:** items labeled with the topic or one of its descendants at confidence **≥ 0.5**.
- **The limit in Phase 1a:** labels come only from creators, stored with `source = creator` and confidence 1.0. The guarantee is therefore "nothing *labeled* Fitness", not "no fitness content".
  - The UI says so.
  - Explanations show which source each label came from.
- Phase 1b's model labels widen coverage without changing this meaning.

### Forgetting an interest
"Forget" zeroes the affinity and stamps `reset_at`, under the same per-user advisory lock the worker uses.
- Views that **started before** the stamp never credit that topic or creator again. That includes views still waiting to be applied and views that keep growing afterwards.
- Views that start after it are learned normally.
- Until it's re-learned, a forgotten topic counts as a **known zero** for ranking. A forgotten tier-2 topic doesn't fall back to half its parent's affinity: "forget Fitness" removes Fitness's learned credit entirely, while Healthy Living keeps its own.
- The lock closes the gap where a worker has already read the boundaries but not yet written. A test pauses the worker exactly there.

### Non-personalized mode: no inferred signals
| Off | Still on |
|---|---|
| `topic`, `co_engagement` and `explore` candidate sources | `trending` and `fresh` sources |
| `topic_affinity` and `creator_affinity` features | `following` source and feature (follows are explicit choices) |
| affinity learning (views aren't learnable) | explicit settings: hard-off, `topic_preference`, source weights |
| | `freshness`, `quality` and `diversity` |
| | the seen filter, which keeps the feed from repeating itself and isn't used for profiling |

Events are still recorded. What a view may be used for is decided per view:

| Use | Example | Which views |
|---|---|---|
| Personal learning | the user's own affinities | `learnable` only |
| Collaborative | co-engagement ("people who finished this also finished…") | `learnable` only, on both sides. A view watched in non-personalized mode never recommends anything to anyone. |
| Aggregate | trending, completion-rate quality | all views, counted as **distinct users**, so one account (or one replaying client) counts once per item |

Fabricated engagement from many accounts (sybils) and rate limits on events are Phase 2 work (see open questions).

The Algorithm tab describes non-personalized mode as exactly this: what you watch doesn't build your interest profile or feed "people like you" recommendations, but it still counts toward anonymous totals like trending and completion rates, which shape what everyone sees.

### Creator signals are split
- `creator_affinity` is inferred from behavior.
- `following` is an explicit choice.

They're separate contributions, so an explanation says "you follow @x" rather than implying the algorithm inferred it.

## Consequences
- Every control has a stated, testable meaning. The invariants are covered by property and concurrency tests that run the real `Events.record/2` and worker path.
- `view_engagements` is one more table written on the event path, one row per view. The transaction is longer, but still a single round trip per batch.
- Affinity writes are serialized per user. That's fine at this volume, since one user generates few views per second.
- The event weights are hand-tuned guesses until there's beta data.

## Alternatives considered
- **Event-log cursor with a lag window.** A lag only makes a late commit *unlikely* to be missed.
- **Per-event "applied" records.** Correct, but one row per event, which is far more than per view.
- **Slider as a pure multiplier.** Dead at zero affinity, and not monotonic for negative affinity.
- **Checking the current mode in the worker.** Wrong when the worker runs after a mode change.
