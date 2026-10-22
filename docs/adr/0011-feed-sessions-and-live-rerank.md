# ADR 0011: Feed sessions and live re-rank

- **Status:** Accepted
- **Date:** 2026-10-21

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
- **One `Feed.Session` process per feed session**, registered in a `Registry` under `{user_id, session_id}` and started on demand under a `DynamicSupervisor`. It stops itself after 10 minutes idle.

### The process is a cache, not a source of truth
- "Already seen" comes from `impressions` rows in Postgres, so it survives the process.
- If a process dies, or a request lands on a different Fly node, a fresh session starts with an empty cache. The seen filter keeps it from repeating items.
- Nothing is lost when a process stops, so there's no handoff protocol between nodes.

### Two counters, two questions
| Counter | Scope | Answers |
|---|---|---|
| `settings_version` | per user, in Postgres, incremented atomically on every change | *Which preferences* produced this ranking? Stored on every impression. |
| `rev` | per feed session, in memory | *Which feed update* is newest? Carried on every page and every push. |

### Channel protocol (`feed_session:<session_id>`)
Joining checks that the session belongs to the user.

| Direction | Message | Meaning |
|---|---|---|
| client → server | `at {impression_id, rev}` | The visible item changed. Messages with an old `rev` are ignored. |
| client → server | `update_settings {changes}` | Fast path: save the changes, re-rank this session, broadcast to the user's other sessions, and reply in one round trip. |
| server → client | `feed_reranked {rev, after_impression_id, items}` | Keep everything up to and including `after_impression_id` and replace the rest. The client drops any push with an older `rev`. |

### Re-ranking a session
1. **Immediately, from the cache:**
   - re-score in memory (a weighted sum per item; microseconds each);
   - apply hard-off filters;
   - replace only the items **after** the client's current position.

   The item being watched is never taken away. Server-side target: under 100 ms for 500 candidates.
2. **Refill in the background** when fewer than 30 eligible candidates remain, or when a topic was boosted but is poorly represented in the cache.
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
- Served-but-never-exposed impressions are pruned after 30 days.

### Partitioning
`impressions` is range-partitioned by month on `served_at`, like `engagement_events`. Dropping old partitions is how ADR 0006's retention works.
- **Primary key:** Postgres requires a partitioned table's key to include the partition key, so the key is `(id, served_at)`.
- **Lookups:** `id` is a UUIDv7, and `served_at` is set to **the timestamp embedded in that UUID**. A lookup by id alone can therefore compute `served_at` and hit exactly one partition.
- **No foreign key from events:** `engagement_events.impression_id` has no database foreign key, since both tables are partitioned. `Events.record/2` checks that the impression belongs to the caller and matches the content.

## Consequences
- Multiple devices work independently, while sharing one set of preferences.
- A process crash or node change costs only a cache rebuild, never correctness.
- Per-session processes use more memory than per-user ones. At about 500 candidates per session, that's acceptable at beta scale.
- The client has to track `rev` and its position, which adds a little protocol complexity in exchange for never interrupting the current video.

## Alternatives considered
- **One process per user.** Simpler, but it breaks with two devices (see Context).
- **Stateless re-rank** (rebuild candidates from SQL on every change). No process to manage, but it can't meet the latency target, and slider drags would hammer the database.
- **Global process registry (Horde / `:global`).** It would keep one process per session cluster-wide. That's unnecessary, because the process is only a cache.
