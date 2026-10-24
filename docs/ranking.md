# How the For You ranker works

This is the plain-language specification of T-Spec's recommendation math as it is **actually implemented** (ranker `v1`, Phase 1a). It's written for three readers:
- people working on T-Spec;
- AI agents working on the repo;
- eventually, curious users who want more than the "Why?" sheet.

The design decisions behind it are in [ADR 0006](adr/0006-interpretable-ranker-persisted-traces.md) (explainable scores), [ADR 0011](adr/0011-feed-sessions-and-live-rerank.md) (feed sessions and live re-ranking) and [ADR 0012](adr/0012-interest-model-and-controls.md) (interest model and controls).

> **Keep this in sync.** The numbers in the [defaults table](#all-the-tunable-numbers) are checked against the code by `test/tspec/docs/ranking_doc_test.exs`. Change a weight in code without updating this page, and `make test` fails.

## The idea in one paragraph

T-Spec keeps track of what you've shown interest in (by watching), combines that with what you've explicitly asked for (your sliders and switches), and gives each eligible video a score. The score is a plain weighted sum, so every point of it can be attributed to one named reason. That breakdown is saved the moment the video is sent to you, and "Why am I seeing this?" shows exactly that saved breakdown. Nothing is a black box: no neural network decides your feed. It's arithmetic you can inspect and change.

Three kinds of input are kept strictly apart:

| Kind | What it is | Examples |
|---|---|---|
| **Evidence** | what you did | finished a video, skipped one, looped one |
| **Inferred interest** | what T-Spec concludes from the evidence | "likes Cooking", "often watches @chef" |
| **Explicit control** | what you told T-Spec | Cooking slider at 1.5×, Fitness off, follow @chef |

Inferred and explicit inputs are separate contributions in every explanation. "You watch a lot of Cooking" and "You set Cooking to 1.5×" are never blended into one number.

## The pipeline

```
what you watch ──► views ──► interest model (topic + creator affinities, decaying)
                                        │
candidate sources (SQL) ──► eligibility filters ──► scoring (Σ weight × value)
                                                          │
                                         diversity re-rank (greedy)
                                                          │
                                  served to you + trace saved (impression)
                                                          │
                              "Why?" reads the saved trace, never recomputes
```

---

## 1. Learning what you're interested in

### Views, not raw events
The app reports events as you watch: `view_start`, `watch_progress` every 5 seconds, `complete` each time the video reaches its end, and `skip` if you swipe away first.

All events from one **playback episode** share a `view_id`. Watching the same video twice is two views. T-Spec learns **once per view**, not once per event, so a view can't be double-counted however many events or network batches it spans.

### What one view is worth
Each view has a single **target delta**, recomputed from everything known about it so far:

| How the view went | Target delta |
|---|---|
| Watched to the end | **+1.0** |
| Watched to the end and looped at least once (watched ≥ 2× the length) | **+1.25** |
| Swiped away within the first **2 seconds** | **−0.5** |
| Otherwise | **+0.8 × fraction watched** (fraction capped at 1) |
| A text post was shown (there's no duration to measure) | **+0.1** |

Examples: watching half of a video and moving on gives `0.8 × 0.5 = +0.4`; a quarter gives `+0.2`.

The fraction is relative to the video's length, so half of a 20-second clip and half of a 3-minute video are worth the same. Long videos aren't rewarded just for having more seconds.

### Applying a view exactly once: `target − applied`
A view grows while you watch. The background worker applies only what's new:

```
Δ = target_delta − applied_delta
```

It then records `applied_delta = target_delta`, in the same database transaction. Watching one video:

| Moment | Target | Already applied | Δ applied now |
|---|---|---|---|
| 25% watched | 0.20 | 0.00 | +0.20 |
| 50% watched | 0.40 | 0.20 | +0.20 |
| finished | 1.00 | 0.40 | +0.60 |
| **total** | | | **+1.00** |

Re-running the worker applies nothing (Δ = 0), so retries are harmless. The result doesn't depend on the order or timing in which events arrive.

### Which interests a view credits
A video's topic labels are **snapshotted when the view starts**. A creator editing the labels mid-view can't redirect what you've already watched.

Each Δ is credited:
- to each labeled topic, × the label's confidence (creator labels are 1.0 in Phase 1a);
- to that topic's tier-1 parent at **half** weight. For example, Fitness and Exercise → Healthy Living gets 0.5× (a topic labeled at both levels takes the larger);
- to the video's creator, × 1.

### Interests fade: 14-day half-life
Each affinity is stored as a score plus the time it was last updated (`as_of`). Its effective value now is:

```
effective = stored × 0.5 ^ (days since as_of / 14)
```

A score of 8 is worth 4 after two weeks, 2 after four weeks and 1 after six. Decay is proportional: the score halves every 14 days whatever its size.

When a new Δ arrives, the old score is **decayed to now first**, then the Δ is added. Otherwise an old score would suddenly count as fresh. That update is a single atomic database statement, and a per-user lock makes concurrent updates queue up.

### From score to ranking signal: `tanh(score / 3)`
The ranker never uses the raw score. It squashes it into the range −1 to +1:

| Effective score | Value the ranker uses |
|---|---|
| −6 | −0.964 |
| −3 | −0.762 |
| 0 | 0 |
| +1 | +0.322 |
| +3 | +0.762 |
| +6 | +0.964 |
| +30 | ≈ +1.0 |

Strong interests stay strong, but no single interest can grow without bound and drown out everything else. The first few views matter a lot; the 30th matters little.

### Forgetting
"Forget this interest" zeroes it and records a reset time.
- Views that **started before** the reset never credit it again, including ones still being processed.
- New views are learned normally.
- Until it's re-learned, a forgotten topic counts as a **known zero**: a forgotten subtopic like Fitness also loses the half-of-its-parent fallback described below.

---

## 2. Finding candidates

Before scoring, cheap database queries nominate a few hundred plausible videos. Each candidate is tagged with the source(s) that found it:

| Source | Finds | Limit |
|---|---|---|
| `following` | recent items from accounts you follow | 150 |
| `topic` | recent items in your top 5 interest topics, **plus every topic you've boosted** (slider above 1×) | 150 |
| `trending` | the global trending pool | 150 |
| `co_engagement` | items finished by people who finished what you finished (last 14 days) | 100 |
| `explore` | random recent items in topics you have no history with | 50 |
| `fresh` | the newest public items | 100 |

**Trending score** = how many **distinct people** finished the item in the last 24 hours × `0.5 ^ (item age / 48 hours)`. It's refreshed every 5 minutes.

**Every candidate must pass these filters:**
- ready and public;
- not yours;
- published within 30 days;
- not viewed by you in the last 48 hours;
- not already sent in this feed session;
- not hard-off.

**Hard-off is a filter, not a low score.** An item is removed if it has a label with confidence **≥ 0.5** on a topic you switched off, or on a subtopic of one. Switching off Healthy Living also removes Fitness and Exercise.

In Phase 1a, labels come only from creators. So the guarantee is "nothing *labeled* Fitness", not "no fitness content": a mislabeled video can slip through. Phase 1b adds automatic labels.

---

## 3. Scoring

```
score(you, item) = Σ  weight_k × value_k        (summed over the features below)
weight_k         = default_weight_k × your_multiplier_k
```

Each `weight × value` is one **contribution**, one row of the "Why?" sheet. The score is *defined* as their sum, added in the order listed, so a saved explanation always adds up to the saved score exactly.

The score is not a probability. It only orders candidates.

### The features

| Feature | Value | Default weight | Your control |
|---|---|---|---|
| `topic_affinity` (one per topic label) | your interest in the topic (−1…1) × label confidence | 1.0 | × topic slider *m* |
| `topic_preference` (one per topic label, only when *m* ≠ 1) | label confidence | 1.5 | weight is 1.5 × (*m* − 1) |
| `creator_affinity` | your learned interest in the creator (−1…1) | 0.6 | — |
| `following` | 1 if you follow the creator | 0.5 | follow / unfollow |
| `source_prior` | 1, for the best source that found the item | per source (see below) | × source slider |
| `freshness` | `0.5 ^ (age in hours / 24)`: 1 when new, 0.5 after a day | 0.4 | — |
| `quality` | smoothed completion rate (below) | 0.3 | — |
| `diversity` | penalty for repeating what you just saw (below) | 0.5 | — |

A learned feature with value 0 is left out of the trace rather than shown as "+0.00".

**Topic fallback:** if you have no history with a subtopic (say Fitness) but do with its parent (Healthy Living), the item's `topic_affinity` value is **half the parent's**, unless you forgot that subtopic.

**Topic sliders apply to subtopics:** a subtopic without its own slider follows its parent's slider.

### Topic sliders: why "more" always means more
A topic slider *m* (from 0 to 2, default 1) does two things, and each shows up separately in "Why?":
- **Learned interest:** it scales your learned interest: `1.0 × m × affinity × confidence`.
- **Explicit preference:** it adds or subtracts on its own terms: `1.5 × (m − 1) × confidence`. This is 0 at the default, positive above 1×, and negative below it.

The explicit part is what lets "more Cooking" work even when you've never watched Cooking, and when your learned interest is negative.

**The guarantee.** The topic's total is `c × (1.0 × m × a + 1.5 × (m − 1))`, and its rate of change as the slider moves is `c × (1.0 × a + 1.5)`.
- The learned value `a` is always above −1, so that rate is always above `c × 0.5`, which is positive.
- So moving a slider toward "more" **always** raises that topic's score, even for a topic you've skipped a lot.
- The code refuses to compile if `topic_preference` isn't larger than `topic_affinity`, and a property test sweeps the slider.

One caveat: this is about the item's *score*. Its final *position* can still shift because of the diversity pass.

Example: your learned Cooking value is −0.5 (you skip it), and the label confidence is 1.0.

| Slider | Learned | Explicit | Topic total |
|---|---|---|---|
| 0× | 0.00 | −1.50 | −1.50 |
| 1× | −0.50 | 0.00 | −0.50 |
| 1.5× | −0.75 | +0.75 | 0.00 |
| 2× | −1.00 | +1.50 | +0.50 |

**Slider at 0× is not the same as off.** Zero only lowers the score; the off switch removes the items.

### Sources
An item found by several sources gets **one** `source_prior` row, for whichever source gives the highest `default × your multiplier`:

| Source | following | co_engagement | topic | trending | explore | fresh |
|---|---|---|---|---|---|---|
| Default prior | 0.3 | 0.25 | 0.2 | 0.2 | 0.1 | 0.1 |

### Quality: smoothed completion rate
```
quality = (people who finished it + 10 × 0.3) / (people who watched it + 10)
```
Every item starts as if 10 people had watched it at a 30% completion rate. That prior fades as real viewers arrive, so one viewer finishing a brand-new video doesn't make it look perfect.

Viewers are counted as **distinct people**, so replaying (or faking) views from one account counts once. Completion rate is a signal of behavior, not an objective measure of worth.

### Diversity: the greedy pass
Sorting purely by score could show you five videos in a row from one creator. So the first 50 positions are filled **one at a time**. Each remaining candidate gets a penalty against the items picked just before it, and the best adjusted score wins:

```
diversity value = −1   for each item by the same creator among the previous 5 picks
                  −0.5 for each item with the same main topic among the previous 3 picks
contribution    = 0.5 × diversity value
```

The window continues across pages and re-ranks: the items already sent count as "previous picks". Positions after the first 50 are ordered by score alone.

### A worked example (real numbers)
A Cooking video, computed by the actual ranker:
- your Cooking interest has an effective score of 1.8, so its value is `tanh(0.6)` = 0.537;
- your Cooking slider is at 1.5×;
- you've watched this creator before (score 1.0, value 0.322), and you follow them;
- it was found by `topic` and `fresh`, and posted 6 hours ago;
- 7 of 10 viewers finished it;
- the item just before it was also about Cooking.

| Row in "Why?" | Weight × value | Contribution |
|---|---|---|
| You watch a lot of Cooking (`topic_affinity`) | 1.5 × 0.537 | +0.806 |
| You set Cooking to 1.5× (`topic_preference`) | 0.75 × 1.0 | +0.750 |
| You follow this creator (`following`) | 0.5 × 1.0 | +0.500 |
| How recently it was posted (`freshness`) | 0.4 × 0.841 | +0.336 |
| Found via topics you like (`source_prior`) | 0.2 × 1.0 | +0.200 |
| You often watch this creator (`creator_affinity`) | 0.6 × 0.322 | +0.193 |
| How often people finish it (`quality`, (7 + 3) / (10 + 10) = 0.5) | 0.3 × 0.5 | +0.150 |
| Spacing out a creator or topic you just saw (`diversity`) | 0.5 × −0.5 | −0.250 |
| **Score** | | **2.685** |

The `topic_affinity` weight is 1.5, which is the default 1.0 × your 1.5× slider.

---

## 4. Explanations are records, not reconstructions

Every item sent to you creates an **impression** row, saved at that moment. It holds:
- the full contribution list and the score;
- the candidate sources;
- the ranker version (`v1`);
- your settings version, and a snapshot of your settings at that moment;
- your consent version.

"Why am I seeing this?" reads that row. It never recomputes, so if you change a slider tomorrow, today's explanation still shows today's settings.

Two kinds of impression are distinguished:

| Term | Meaning | Counts toward |
|---|---|---|
| **served** | sent to your app (in a page or a live update) | the saved explanation |
| **shown** | actually appeared on your screen (the app reports `view_start` with the impression's id) | the dashboard; later, data-dividend attribution |

Served-but-never-shown impressions are deleted after 30 days.

---

## 5. Changing settings live

Each open For You feed has a small **feed session** process on the server, one per device feed (not one per user). It holds:
- about 500 scored candidates;
- the list of items it has sent;
- your current position in that list;
- a revision number `rev`.

When you move a slider or flip a switch:
1. **Saving:** the change is saved and your `settings_version` goes up by 1.
2. **Every open feed session of yours re-ranks.** The candidates are re-scored in memory (milliseconds), hard-off items are dropped, and everything **after the item you're watching** is replaced and pushed to the app with `rev + 1`. The item you're watching is never taken away.
3. **Refills:** if the filters left fewer than 30 candidates, or you boosted a topic the cache barely has, the session fetches more in the background. The result is used only if your settings haven't changed again meanwhile.
4. **New explanations:** newly sent items get new impressions with the new settings version.

Measured end to end in the browser test: about 230 ms from tap to re-ranked feed, including a deliberate 150 ms pause that batches slider movements.

---

## 6. Non-personalized mode

| Off | Still on |
|---|---|
| learned topic and creator interest (`topic_affinity`, `creator_affinity`) | following (an explicit choice) |
| the `topic`, `co_engagement` and `explore` sources | the `trending` and `fresh` sources |
| learning from what you watch (views are marked not learnable when they start, and when you switch the mode on) | your explicit settings: off switches, topic preference, source weights |
| your views in other people's "people like you" recommendations | freshness, quality, diversity |

Your viewing still counts in anonymous totals: trending and completion rates, counted as one per person per item.

---

## 7. What this is, and isn't

- It's a **deterministic scoring rule with hand-picked defaults**, not a trained model. The same inputs always produce the same ranking, which is what makes it explainable and testable.
- The numbers are **starting points**, not science. They're listed in `docs/open-questions.md` for tuning from real beta usage.
- Engagement is an imperfect signal. You might finish a video you disliked, or skip one you'd have loved. The model makes rough inferences from behavior, not readings of your mind.
- Phase 1b adds automatic topic labels (from transcripts and video frames) through the same label mechanism. That improves what T-Spec knows about *videos*, not how it ranks for *you*. Later rankers must stay decomposable in the same way ([ADR 0006](adr/0006-interpretable-ranker-persisted-traces.md)).

---

## All the tunable numbers

Checked against the code by `test/tspec/docs/ranking_doc_test.exs`.

<!-- defaults:start -->
| Name | Value | Where |
|---|---|---|
| `feature.topic_affinity` | 1.0 | `Feed.Ranker.Defaults` |
| `feature.topic_preference` | 1.5 | `Feed.Ranker.Defaults` |
| `feature.creator_affinity` | 0.6 | `Feed.Ranker.Defaults` |
| `feature.following` | 0.5 | `Feed.Ranker.Defaults` |
| `feature.freshness` | 0.4 | `Feed.Ranker.Defaults` |
| `feature.quality` | 0.3 | `Feed.Ranker.Defaults` |
| `feature.diversity` | 0.5 | `Feed.Ranker.Defaults` |
| `source.following` | 0.3 | `Feed.Ranker.Defaults` |
| `source.co_engagement` | 0.25 | `Feed.Ranker.Defaults` |
| `source.topic` | 0.2 | `Feed.Ranker.Defaults` |
| `source.trending` | 0.2 | `Feed.Ranker.Defaults` |
| `source.explore` | 0.1 | `Feed.Ranker.Defaults` |
| `source.fresh` | 0.1 | `Feed.Ranker.Defaults` |
| `interest.complete` | 1.0 | `Feed.Interests.Weights` |
| `interest.loop_bonus` | 0.25 | `Feed.Interests.Weights` |
| `interest.early_skip` | -0.5 | `Feed.Interests.Weights` |
| `interest.early_skip_ms` | 2000 | `Feed.Interests.Weights` |
| `interest.partial` | 0.8 | `Feed.Interests.Weights` |
| `interest.text_view` | 0.1 | `Feed.Interests.Weights` |
| `interest.half_life_days` | 14 | `Feed.Interests.Weights` |
| `interest.squash` | 3.0 | `Feed.Interests.Weights` |
| `interest.parent_share` | 0.5 | `Feed.Interests.Weights` |
| `ranker.hard_off_threshold` | 0.5 | `Feed.Ranker` |
| `quality.prior_views` | 10 | `Feed.Candidates` |
| `quality.prior_rate` | 0.3 | `Feed.Candidates` |
<!-- defaults:end -->

Fixed in code and described above (not yet tunable):
- **Freshness:** 24 h half-life.
- **Trending:** 48 h age half-life over 24 h of completions.
- **Diversity:** the first 50 positions; previous 5 for creators (−1 each), previous 3 for topics (−0.5 each).
- **Topic fallback:** half the parent's affinity.
- **Candidates:**
  - window: 30 days;
  - seen filter: 48 h;
  - co-engagement window: 14 days;
  - top topics: 5;
  - per-source limits as in the candidate table.
- **Sessions:**
  - page size 10;
  - idle stop after 10 minutes;
  - refill below 30 candidates, or when a boosted topic has fewer than 5;
  - 60 s back-off after an empty or failed refill.

## Where it lives in the code

| Piece | Module |
|---|---|
| Views, deltas, decay, forgetting | `TSpec.Feed.Interests` (`apps/server/lib/tspec/feed/interests.ex`) |
| Candidate sources and filters | `TSpec.Feed.Candidates` |
| Scoring, traces, diversity | `TSpec.Feed.Ranker` (pure) and `Ranker.Defaults` |
| Your controls | `TSpec.Feed.Settings`, stored by `TSpec.Transparency` |
| Live feeds | `TSpec.Feed.Session` |
| Saved explanations | `TSpec.Events.Impression`, read by `TSpec.Transparency.explain/2` |
| The "Why?" wording | `apps/client/src/lib/explanation.ts` |
