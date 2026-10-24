# ADR 0011: Feed sessions and live re-rank

- **Status:** Accepted
- **Date:** 2026-10-21 (amended 2026-10-23 and 2026-10-24 after reviews: cluster-wide ownership, rebuild on start, client keeps the on-screen item, pruning, position reports by impression id, re-rank on start after missed settings, monitored refills via async_nolink, clustering requirement)

## Context
Changing a control must re-rank the feed **live**: the re-ranked feed should be pushed over WebSocket within 500 ms (requirements), and Phase 1's "done when" allows 1 s. Rebuilding every candidate source from SQL on each slider move is too slow and wasteful. The architecture therefore calls for a per-user `Feed` process that caches scored candidates and re-scores them in memory.

Planning showed that "one process per user" is the wrong unit. A user can have a phone and a browser open at once, each with its own position in its own feed. A single process can't know which position to re-rank from, and one device's position messages would corrupt the other's feed.

## Decision

### Users own preferences; feed sessions own feeds
- The **user** owns settings and the interest model. Both live in Postgres and are the source of truth.
- A **feed session** is one client's For You feed. It owns:
  - its candidate cache, with raw feature values;
  - the items it has served, in order;
  - the client's current position;
  - a revision counter, `rev`.
- **One `Feed.Session` process per feed session, cluster-wide.** It's registered with `:global` under `{user_id, session_id}` and started on demand under a local `DynamicSupervisor`. A request that lands on another node reaches the same process, so one session never has two owners with diverging served lists. It stops itself after 10 minutes idle.

### The process is a cache; Postgres is the record
- **Rebuilt on start.** When a session process starts, whether for the first time or after an idle timeout, crash or deploy, it rebuilds the client's list from the session's `impressions`. It replays them in `(rev, position)` order: a new `rev`'s first impression truncates the list at its position, as the re-rank did, then the rest append.
  - `rev` resumes from the highest stored revision.
  - The position is the furthest item the client reported showing (`view_start` events carrying the impression id).
  - So the client's revision stays valid, its `at` messages keep working, and nothing it already holds is served again.
- **Settings that changed while no process was running** (it idled out, or the change came from the Algorithm tab) are caught at start: if the client's list was ranked under an older `settings_version` than the current one, the session re-ranks its tail at once. The channel subscribes *before* starting the session, so that push isn't lost, and `update_settings` makes sure the session is running *before* saving.
- **The client's `rev` wins if it's higher.** An empty re-rank writes no impressions, so the client can be ahead of the rebuild. The client sends its `rev` when it (re)joins the channel and with every `at`, and the session adopts a higher one.
- **"Seen" means viewed.** Across sessions, items the user *viewed* in the last 48 hours (`view_engagements`) are filtered out of candidates. Items that were only served, never shown, may come back.

### Two counters, two questions
| Counter | Scope | Answers |
|---|---|---|
| `settings_version` | per user, in Postgres, incremented atomically on every change | *Which preferences* produced this ranking? Stored on every impression. |
| `rev` | per feed session, in memory | *Which feed update* is newest? Carried on every page and every push. |

### Channel protocol (`feed_session:<session_id>`)
Joining checks that the session belongs to the user.

| Direction | Message | Meaning |
|---|---|---|
| client → server | `at {impression_id, rev}` | The visible item changed. Matched by impression id whatever `rev` it carries (ids are unique, and channel messages arrive in order); a higher `rev` is adopted. If the session no longer lists that impression, the client kept it on screen through a re-rank: its video is never served again. The client re-sends `at` for its current item whenever it (re)joins. |
| client → server | `update_settings {changes}` | Fast path: save the changes, re-rank this session, broadcast to the user's other sessions, and reply in one round trip. |
| server → client | `feed_reranked {rev, after_impression_id, items}` | Keep everything up to and including `after_impression_id` and replace the rest. The client drops any push with an older `rev`. **It also keeps everything through the item on screen, if that's further:** a push from a refill or another device can cross an `at` message still in flight. |

Joining sends `{rev}` (the revision the client holds); see "The process is a cache".

### Re-ranking a session
1. **Immediately, from the cache:**
   - re-score in memory (a weighted sum per item; microseconds each);
   - apply hard-off filters;
   - replace only the items **after** the client's current position.

   The item being watched is never taken away. Server-side target: under 100 ms for 500 candidates.
2. **Refill in the background** when fewer than 30 eligible candidates remain, or when a topic was boosted but is poorly represented in the cache. The task is monitored: if it dies before reporting (say, a database timeout), the session stops waiting. An empty or failed refill starts a 60 s cooldown before a page can trigger another.
   - The candidate sources run under the new settings, including a targeted query for the boosted topic.
   - The results are merged, and a second push follows with `rev + 1`.
3. **Breadth:** the `topic` source draws from the user's top affinity topics *plus every topic they've explicitly boosted*, so a slider can surface content the profile has never seen.

### Stale work is discarded, not merged
- Settings broadcasts on `feed_settings:<user_id>` carry their `settings_version`. A session ignores any broadcast older than the one it has, which covers out-of-order PubSub delivery across nodes.
- Each refill is tagged with the `settings_version` it ran under. Its result is merged **only if the session is still on that version**; otherwise it's thrown away.
- Merged candidates are also re-filtered against the current settings.

### Impressions: served vs exposed
| Term | Meaning | Stored |
|---|---|---|
| ranking decision | every candidate scored in memory | never |
| **served** | an item sent to the client, in a page or a push | one `impressions` row, with its trace, `rev` and `settings_version`. "Why?" reads this row. |
| **exposed** | the item actually became visible | a `view_start` event carrying that `impression_id` |

- The dashboard and dividend attribution count **exposed** impressions only.
- A re-rank writes impressions for the pushed page only (about 10 rows), never for the whole cache. The client debounces slider changes by 150 ms.
- Served-but-never-exposed impressions are deleted after 30 days by a daily job (`Events.ImpressionPruneWorker`).

### Partitioning
`impressions` is range-partitioned by month on `served_at`, like `engagement_events`. Dropping old partitions is how ADR 0006's retention works.
- **Primary key:** Postgres requires a partitioned table's key to include the partition key, so the key is `(id, served_at)`.
- **Lookups:** `id` is a UUIDv7, and `served_at` is set to **the timestamp embedded in that UUID**. A lookup by id alone can therefore compute `served_at` and hit exactly one partition.
- **No foreign key from events:** `engagement_events.impression_id` has no database foreign key, since both tables are partitioned. `Events.record/2` checks that the impression belongs to the caller and matches the content.

## Consequences
- Multiple devices work independently, while sharing one set of preferences.
- A process crash, idle timeout or deploy costs a cache rebuild from Postgres, never correctness.
- A session's calls may cross nodes to reach its owner (one extra hop at most).
- **Deployment requirement:** `:global` only spans nodes that are connected. In production the machines must actually cluster, or the app must run on one machine. On Fly, clustering takes four things (the Phase 2 deploy item has the details):
  - `DNS_CLUSTER_QUERY`;
  - a node name built from each machine's private IP;
  - a shared release cookie;
  - IPv6 distribution. The server warns at boot when it's unset. The two-node behavior is covered by `session_cluster_test.exs` locally and in CI; a live multi-machine check belongs to the Phase 2 deploy.
- Per-session processes use more memory than per-user ones. At about 500 candidates per session, that's acceptable at beta scale.
- The client has to track `rev` and its position, which adds a little protocol complexity in exchange for never interrupting the current video.

## Alternatives considered
- **One process per user.** Simpler, but it breaks with two devices (see Context).
- **Stateless re-rank** (rebuild candidates from SQL on every change). No process to manage, but it can't meet the latency target, and slider drags would hammer the database.
- **A node-local `Registry`** (the first implementation). Rejected after review: a request on a second node would start a second process for the same session, and the two would diverge on what they'd served. The cache argument doesn't save it, because the *served list* is mutable state.
- **Horde** (a CRDT-based distributed registry). Heavier than needed. `:global`'s cost is a cluster-wide lock on registration, and registrations are rare (session starts).
