# Server concurrency

Processes, locks and the invariants they protect, each with the test that proves it. For the design rationale, see [ADR 0011](../adr/0011-feed-sessions-and-live-rerank.md) (feed sessions) and [ADR 0012](../adr/0012-interest-model-and-controls.md) (interest model). What we're unsure of is in [unsure.md](unsure.md).

## Processes

`TSpec.Application` starts one `one_for_one` tree ([application.ex](../../apps/server/lib/tspec/application.ex)):

| Child | What it is | Scope |
|---|---|---|
| `TSpec.Repo` | Ecto pool (`POOL_SIZE`, default 10) | node |
| `DNSCluster` | connects nodes when `DNS_CLUSTER_QUERY` is set; idle otherwise | node |
| `Phoenix.PubSub` (`TSpec.PubSub`) | pg-based PubSub | cluster |
| `Oban` | queues `default: 10, media: 4, affinity: 5, ranking: 2, maintenance: 1`; cron jobs run on the leader only | cluster (via Postgres) |
| `TSpec.RateLimit` | Hammer, ETS | **node** |
| `:pg` scope `TSpec.Feed.Session` | groups `{:user, user_id}`: each user's live sessions | cluster |
| `TSpec.Feed.SessionSupervisor` | `DynamicSupervisor` for `Feed.Session` (`restart: :temporary`) | node |
| `TSpec.TaskSupervisor` | refill tasks (`async_nolink` from a session) | node |
| `TSpecWeb.Endpoint` | one transport process per socket, one process per joined channel | node |

### `Feed.Session` ([session.ex](../../apps/server/lib/tspec/feed/session.ex))

One GenServer per `{user_id, session_id}`, registered with `:global`. It caches about 500 scored candidates, the list it has served, the client's position and a revision `rev`. It's a cache: Postgres holds settings, impressions and exposures, and a new process rebuilds from them (`rebuild/1`).

- **Started by** `Session.ensure/3`. `GET /api/feed/for-you` calls it, and so does `FeedChannel` on the join and on every `at` and `update_settings` message, so any channel message can restart an idle session. If the user is at the cap, it first stops existing sessions (`make_room/1`, `GenServer.stop/3` with a 5 s timeout).
- **Stops itself** after 10 minutes idle. A crash isn't restarted; the next request starts a fresh process, which rebuilds.
- **Writes to Postgres from inside the process.** `Ranking.serve` inserts impressions for every page and re-rank.
- **Runs candidate SQL in two places:**
  - in `handle_continue(:load)`, synchronously: the first `next_page` call waits for it, with a 15 s call timeout;
  - in refill tasks, asynchronously: the task replies `{:refill, settings_version, candidates}`, and its `:DOWN` is handled if it crashes.
- **Receives** `{:settings_changed, settings}` on `feed_settings:<user_id>`, and **broadcasts** `{:feed_reranked, ...}` on `feed_session:<user_id>:<session_id>`. The `FeedChannel` relays the latter.

### Settings change, end to end

1. `Transparency.update_settings/2` runs one transaction under `FOR NO KEY UPDATE` on the user row. It writes the settings, bumps `users.settings_version`, and, when turning non-personalized mode on, ratchets open views to `learnable = false`.
2. After commit, it broadcasts `{:settings_changed, settings}` to `feed_settings:<user_id>`.
3. Each of the user's sessions, on any node, re-ranks the items after the client's position, writes impressions for the new page and broadcasts `feed_reranked`. If boosted topics are missing from the cache, it starts a refill.
4. A broadcast that isn't newer than the session's `settings_version` is ignored. A refill result is merged only if the session is still on the version the refill ran under.

### Learning from a view

1. `POST /api/events` → `Events.record/2`, in one transaction:
   - takes `FOR SHARE` on the user row, to read the personalization mode;
   - inserts the events;
   - `Interests.track_views/4` creates or merges `view_engagements` rows under `FOR UPDATE` and recomputes `target_delta`;
   - if any view is dirty, queues an `AffinityWorker` job.
2. The `AffinityWorker` job runs `Interests.apply_dirty_views/2`, in one transaction:
   - takes a per-user advisory lock (`pg_advisory_xact_lock`);
   - claims dirty views `FOR UPDATE SKIP LOCKED`;
   - upserts `target_delta - applied_delta` into the affinities (in sorted key order, with a decay-aware upsert);
   - sets `applied_delta = target_delta`.
3. `AffinitySweepWorker` (every 10 minutes) re-queues users who still have dirty views, in case a job was discarded.

## Locks

| Lock | Taken in | Serializes | Waits? |
|---|---|---|---|
| `users` row `FOR NO KEY UPDATE` | `Accounts.within_login_email_limits/2` | counting and issuing sign-in emails for one address | yes |
| conditional `UPDATE login_codes … WHERE attempts < max` | `Accounts.claim_login_attempt/2` | spending one code guess | row lock for the statement |
| `users` row `FOR NO KEY UPDATE` | `Transparency.update_settings/2`, `reset_settings/1` | `settings_version` increments; mode switch vs. recording | yes |
| `users` row `FOR SHARE` | `Events.record/2` | reading the personalization mode for new views | yes, behind a pending `FOR NO KEY UPDATE` |
| `users` row `FOR KEY SHARE` (implicit) | any insert of a row with a foreign key to `users`: affinities, views, events, impressions, tokens | the user still existing | only behind a `FOR UPDATE`-strength lock. Besides `FOR UPDATE`, Postgres takes one for a `DELETE` of the row, and for an `UPDATE` that changes a uniquely indexed column (`users.email`, `users.handle`). That means onboarding (sets `handle`), the under-13 deletion, and account deletion in Phase 2. None of those waits on anything a foreign-key insert holds, so they can't form a cycle. |
| `view_engagements` rows `FOR UPDATE` | `Interests.track_views/4` | merging concurrent batches into one view | yes |
| advisory `affinity:<user_id>` (transaction-scoped) | `Interests.apply_dirty_views/2`, `Interests.forget/4` | all writes to one user's affinities | yes |
| `view_engagements` rows `FOR UPDATE SKIP LOCKED` | `Interests.apply_dirty_views/2` | claiming dirty views; skips rows a recording transaction holds | never |
| conditional `UPDATE content_items … WHERE status = 'processing'` | `Content.expire_stale_uploads/1`, `Content.finish/3` | leaving `processing` (expiry vs. provider event) | row lock for the statement |
| `:global` name lock | `Feed.Session.start_link/1` | one session process per `{user_id, session_id}` among connected nodes | yes, cluster-wide |

**User-row locks are `FOR NO KEY UPDATE`, never `FOR UPDATE`.** Every insert of a row that references `users` (a new affinity, view, event, impression or token) checks the foreign key, which takes `FOR KEY SHARE` on that user's row. `FOR UPDATE` blocks that check; `FOR NO KEY UPDATE` doesn't, and it still conflicts with `FOR SHARE` and with itself.

With `FOR UPDATE`, this interleaving deadlocked (I20):
1. The affinity worker claims a dirty view.
2. The switch to non-personalized locks the user row, and its ratchet waits for that view.
3. The worker inserts the user's first affinity for a topic, and the foreign-key check waits for the switch.

**Acquisition order.** A transaction that takes several of these takes them in this order:
- `users` row, then `view_engagements` rows. Both `Events.record/2` and the non-personalized ratchet do this.
- Advisory lock, then `view_engagements` rows (with `SKIP LOCKED`, so it never waits), then affinity rows (in sorted key order). New affinity rows also take `FOR KEY SHARE` on the `users` row, which only `FOR UPDATE` would block.

Only that one pair (I20) is tested. The ordering is otherwise argued, not tested for deadlocks under load (see [unsure.md](unsure.md), U7).

## Invariants

Each row names the guard, the test that proves it, and the mutation (in [`scripts/mutation_checks.py`](../../scripts/mutation_checks.py)) that breaks the guard and makes that test fail. `make mutation-check` re-runs all of them. A row without a mutation is enforced by the code's structure rather than one breakable line.

| # | Invariant | Enforced by | Test | Mutation |
|---|---|---|---|---|
| I1 | A sign-in code allows at most 5 guesses, even under a parallel burst. | The attempt is claimed by a conditional `UPDATE` before the comparison. | [login_code_concurrency_test](../../apps/server/test/tspec/accounts/login_code_concurrency_test.exs): "a burst of parallel wrong guesses can't spend more than the limit" | M1 |
| I2 | At most 5 sign-in emails an hour and 10 a day per address, even under a parallel burst. | The count and the insert run under `FOR NO KEY UPDATE` on the user row. | [login_code_concurrency_test](../../apps/server/test/tspec/accounts/login_code_concurrency_test.exs): "a burst of parallel sign-in requests can't send more emails than the cap" | M2 |
| I3 | A magic-link token signs in only with the address it was sent to. | `verify_login_token/2` matches `user.email` in the token query. | [api_login_test](../../apps/server/test/tspec/accounts/api_login_test.exs): "refuses a token presented with another address, and leaves it usable" | M3 |
| I4 | Signing out closes that token's sockets, and only those. | The socket id is a hash of the token; sign-out broadcasts `"disconnect"` to it. | [user_channel_test](../../apps/server/test/tspec_web/channels/user_channel_test.exs): "signing out closes that token's sockets, not the user's other devices" | M4 |
| I5 | One `Feed.Session` per `{user_id, session_id}` across connected nodes. | `:global` registration. | [session_cluster_test](../../apps/server/test/tspec/feed/session_cluster_test.exs): "another node reaches the same session instead of starting its own" | M5 |
| I6 | At most 10 live sessions per user (soft: concurrent starts can overshoot until the next start). | `:pg` group per user; `make_room/1`. | [session_test](../../apps/server/test/tspec/feed/session_test.exs): "are capped: starting one more stops an existing one" | M6 |
| I7 | A session only applies settings newer than the ones it has. | The `settings_version` guard on `{:settings_changed, _}` (`v > state.settings.version`). | [session_test](../../apps/server/test/tspec/feed/session_test.exs): "a settings broadcast older than the session's version is ignored" | M7 |
| I8 | A refill that ran under older settings is discarded. | `apply_refill/3` matches on the current version. | [session_test](../../apps/server/test/tspec/feed/session_test.exs): "a refill that finishes after newer settings is discarded; the newer one wins" | M8 |
| I9 | A refill task that dies doesn't stall future refills. | The `:DOWN` handler for `refill_ref`. | [session_test](../../apps/server/test/tspec/feed/session_test.exs): "a refill task that crashes doesn't stall future refills" | M9 |
| I10 | Each view contributes exactly one delta, however many batches, retries or late commits. | `target_delta - applied_delta` is applied, then `applied_delta` catches up. | [interests_test](../../apps/server/test/tspec/feed/interests_test.exs): "one view contributes one delta, however many batches it spans"; [interests_test](../../apps/server/test/tspec/feed/interests_test.exs): "replaying a batch or re-running the worker changes nothing"; [interests_concurrency_test](../../apps/server/test/tspec/feed/interests_concurrency_test.exs): "a view committed late, after newer views were applied, is still applied" | M10 |
| I11 | "Forget" can't be undone by a worker already in flight. | The per-user advisory lock, plus `reset_at`. | [interests_concurrency_test](../../apps/server/test/tspec/feed/interests_concurrency_test.exs): "forgetting an interest can't be overwritten by a worker already in flight" | M11 |
| I12 | Nothing watched in non-personalized mode is learned, including a recording that races the switch. | `FOR SHARE` (record) against `FOR NO KEY UPDATE` (switch) on the user row; the ratchet only clears `learnable`. | [interests_concurrency_test](../../apps/server/test/tspec/feed/interests_concurrency_test.exs): "a record that starts during an uncommitted mode switch waits for it and sees the new mode"; [interests_concurrency_test](../../apps/server/test/tspec/feed/interests_concurrency_test.exs): "switching to non-personalized waits for an in-flight record, then ratchets its view" | M12, M13 |
| I13 | Every committed batch of view state gets an affinity job. | The job is inserted in the recording transaction and deliberately not unique. | [interests_concurrency_test](../../apps/server/test/tspec/feed/interests_concurrency_test.exs): "a view committed after the user's queued job already ran still gets its own job" | M14 |
| I14 | An event can mark only the caller's own impression as exposed. | `Events.verify_impressions/2`. | [ranking_test](../../apps/server/test/tspec/feed/ranking_test.exs): "a view_start can mark its impression exposed; someone else's impression id is dropped" | M15 |
| I15 | `final_score == Σ contributions`, bit for bit, through the stored JSON trace. | `Ranker.sum/1` defines the score; contributions are normalized for `jsonb`. | [ranker_test](../../apps/server/test/tspec/feed/ranker_test.exs): "final_score is exactly the sum of the trace, and each contribution is weight × value"; [ranker_test](../../apps/server/test/tspec/feed/ranker_test.exs): "the trace survives a JSON round-trip bit for bit" | M16 |
| I16 | A provider event can't revive an upload that expiry already failed. | Both status changes are conditional `UPDATE`s on `status = 'processing'`. | [content_test](../../apps/server/test/tspec/content_test.exs): "an event read before expiry commits can't revive the item" | M17 |
| I17 | Events and impressions carry the consent version from the server-side scope, never from the client. | `Events.record/2` and `record_impressions/2` take it from `%Scope{}`. | [events_test](../../apps/server/test/tspec/events_test.exs): "stamps the server-side consent version, ignoring anything the client sends" | — |
| I18 | "Why am I seeing this?" returns the trace and settings stored at serve time, never a recomputation. | `GET /api/impressions/:id` reads the `impressions` row and its settings snapshot. | [transparency_controller_test](../../apps/server/test/tspec_web/controllers/transparency_controller_test.exs): "returns the stored trace, and the settings as they were when served" | — |
| I19 | A user's impressions are private to them. | Every lookup filters on `user_id` and computes `served_at` from the id. | [transparency_controller_test](../../apps/server/test/tspec_web/controllers/transparency_controller_test.exs): "is private, and unknown ids are 404" | — |
| I20 | The affinity worker and a switch to non-personalized can't deadlock. | The switch locks the user row `FOR NO KEY UPDATE`, which doesn't block the worker's foreign-key check on a new affinity row. | [interests_concurrency_test](../../apps/server/test/tspec/feed/interests_concurrency_test.exs): "the affinity worker and a switch to non-personalized can't deadlock" | M18 |
