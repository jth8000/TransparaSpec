# Things we're unsure about (server)

Where an experienced Elixir or distributed-systems reviewer is most likely to find something. Each item says what we believe, why we're not sure, and what would settle it. Nothing here is known to be broken; anything known to be broken is fixed or tracked as a bug.

## Distribution

**U1. Feed sessions across a netsplit.**
- **What we believe:** `:global` gives one session process per `{user_id, session_id}` among *connected* nodes (I5 in [concurrency.md](concurrency.md)).
- **Why we're not sure:** during a partition, each side can start its own process for the same session. If one client's requests land on both sides, both write impressions with overlapping `rev` values. When the partition heals, `:global`'s default resolver keeps one process and kills the other, but the stored impressions stay interleaved. Later, `rebuild/1` replays them in `(rev, position)` order and may build a list the client never had. Nothing tests partitions.
- **What would settle it:** a `:peer` test that disconnects the nodes, serves on both sides, reconnects and rebuilds. The private beta runs on one machine ([ADR 0013](../adr/0013-single-machine-private-beta.md)), so this can't happen there. The test is a prerequisite for clustering.

**U2. `Session.ensure/3` retries with `Process.sleep/1`.**
- **What we believe:** a session that just died can stay registered for a moment, because `:global` cleans up asynchronously, so when `ensure` finds a dead local pid it retries up to 20 times, 5 ms apart.
- **Why we're not sure:** it's a timing-based workaround.
  - After the 20th retry, it returns the dead pid anyway. A call to it exits (`next_page`); a cast to it is silently lost (`at`, `sync_rev`).
  - A remote pid isn't checked at all.
  - `FeedChannel` matches `{:ok, pid} = Session.ensure(...)` on every message, so an error there crashes the channel process (the client rejoins).
- **What would settle it:** a reviewer's view on monitoring the pid, or on retrying the call itself.

**U3. Per-node state that assumes one node.**
- **What we believe:** the per-client-address rate limits (Hammer ETS) and `TSpec.TaskSupervisor` are per node. That's fine on one machine, which is the plan for the private beta ([ADR 0013](../adr/0013-single-machine-private-beta.md)).
- **Why we're not sure:** on N machines, an address gets N times the limit. The per-email sign-in caps live in Postgres, so they stay exact.
- **What would settle it:** a decision before clustering (an ADR 0013 prerequisite), either a Postgres- or Redis-backed limiter or accepting N times the limit.

## Process design

**U4. Database work inside the session GenServer.**
- **What we believe:** `Feed.Session` writes impressions from inside its own process (`Ranking.serve`), and gathers its first candidates synchronously in `handle_continue(:load)`.
- **Why we're not sure:** a slow database stalls that one session's mailbox. `at` casts queue up, and `next_page` calls can hit their 15 s timeout. A refill already runs in a task.
- **What would settle it:** load testing with a slow database. Possibly move the initial gather into a task too.

**U5. `make_room/1` stops sessions synchronously inside a request.**
- **What we believe:** starting the 11th session stops an existing one with `GenServer.stop/3` (5 s timeout), from the request or channel-join process. The cap is soft: concurrent starts can overshoot until the next start trims (I6).
- **Why we're not sure:** a busy session delays someone else's request by up to 5 s.
- **What would settle it:** a reviewer's view, or making the stop asynchronous.

**U6. Unbounded duplicate `AffinityWorker` jobs.**
- **What we believe:** each committed batch with dirty views inserts a job, deliberately not unique (I13), and extra runs are cheap and idempotent.
- **Why we're not sure:** a user posting events quickly creates one job per batch. The `affinity` queue runs 5 at a time, and the per-user advisory lock serializes them.
- **What would settle it:** measuring the queue under realistic event rates, and possibly a uniqueness rule that only covers `available` jobs, not `executing` ones.

## Locking

**U7. Deadlocks are mostly argued, not tested.**
- **What we believe:** the lock order in [concurrency.md](concurrency.md) avoids cycles, now that user-row locks are `FOR NO KEY UPDATE`.
- **Why we're not sure:** the first version of this packet said the affinity worker "never touches the users row". A reviewer pointed out that its foreign-key checks do, and that this deadlocked against the switch to non-personalized mode. A test reproduced it, and it's fixed (I20). That cycle was invisible in the code because the lock is implicit, so others like it may exist. Only that one interleaving is tested; no test runs recording, settings changes, forgetting and the affinity worker concurrently at volume.
- **What would settle it:** a concurrency soak test, perhaps with StreamData generating interleavings of those operations.

**U8. Concurrent settings changes.**
- **What we believe:** `settings_version` increments under `FOR UPDATE` on the user row, so two concurrent changes get distinct versions.
- **Why we're not sure:** the tests are sequential. M13 shows the lock matters for the non-personalized ratchet, but not for the version counter itself.
- **What would settle it:** a test with two parallel `update_settings/2` calls on `unboxed_run/2`.

## Deployment

**U9. WebSocket origin checks in production.**
- **What we believe:** Phoenix's default `check_origin` accepts only the endpoint's host (`PHX_HOST`).
- **Why we're not sure:** the Expo web client is served from `CLIENT_URL`. If that's a different host, browsers' socket connections would be refused. Native clients are unaffected. Nothing is deployed, so this is untested.
- **What would settle it:** setting `check_origin` from `CLIENT_URL` in `runtime.exs`, with a test like `prod_config_test`. Also, the `/live` socket is mounted in production although only the dev-only LiveDashboard uses it.

**U10. Oban cron leadership and rolling deploys.**
- **What we believe:** cron jobs (partitions, sweeps, pruning, expiry) are inserted by the Oban leader, and every job is safe to run twice.
- **Why we're not sure:** `Events.PartitionWorker` runs DDL, which deadlocks against concurrent sandboxed tests. Its behavior next to production traffic is untested.
- **What would settle it:** watching it in staging, and possibly creating partitions further ahead.

## Client

**U11. The web token is in `localStorage`, and the web build has no CSP.**
- **What we believe:** React Native `<Text>` never interprets HTML, and the client has no other HTML sink ([client.md](client.md)), so there's no known XSS.
- **Why we're not sure:** if script injection ever happens (a compromised dependency, or a future feature that renders HTML), it can read the bearer token from `localStorage`. And there's no Content-Security-Policy to limit it, because where the web build is hosted, and with which headers, isn't decided.
- **What would settle it:** decide on hosting with a strict CSP before beta, and resolve the web-sessions question in [open-questions](../open-questions.md) (an httpOnly cookie instead of `localStorage`).

**U12. The bearer token travels in the WebSocket URL.**
- **What we believe:** Phoenix's JS client sends connect params as a query string (`/socket/websocket?token=…`). Our server filters `token` from its logs.
- **Why we're not sure:** any proxy or load balancer in front of the server that logs request URLs (Fly's edge, a future CDN) may record it.
- **What would settle it:** checking what Fly's proxy logs, or passing the token another way (a short-lived socket token from the API, or Phoenix's `authToken` option, which sends it in the `Sec-WebSocket-Protocol` header).

**U13. Native builds are untested in CI, and iOS has never run.**
- **What we believe:** the native code paths (`expo-secure-store`, `expo-video`, the upload's `expo-file-system` `File`) work on Android, which was checked by hand.
- **Why we're not sure:** iOS has never been built. CI exercises only web and Jest. `npx expo install --fix` recently added config plugins (`expo-image`, `expo-web-browser`) that only a native build runs.
- **What would settle it:** an EAS development build for iOS (an Apple developer account is needed), and a Maestro smoke test on each native platform in CI.

**U14. Sign-out gives queued events 3 s.**
- **What we believe:** sign-out flushes the event queue before revoking the token (I25, I27), and anything still unsent is dropped, never misattributed.
- **Why we're not sure:** offline or on a slow connection, the last few events of a session are lost. Today that only costs some interest-model signal. Once events drive dividends or creator payouts, lost events are lost money.
- **What would settle it:** before the Ledger credits engagement, decide whether events must be durable on the device (persisted per account) or whether loss at sign-out is acceptable.

