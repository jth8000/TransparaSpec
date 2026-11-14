# `Feed.Session` for Go developers

A walkthrough of [`TSpec.Feed.Session`](../../apps/server/lib/tspec/feed/session.ex), the per-feed GenServer behind the For You tab. It explains the OTP pieces in Go terms, then walks the real code, then gives six exercises to run yourself. Read it with the code open beside it.

What the session *does* is in [ADR 0011](../adr/0011-feed-sessions-and-live-rerank.md). Its concurrency guarantees, and what we're unsure of, are in [`docs/review/`](../review/README.md). This page is about *how it works*.

## The mental model

| Elixir / OTP | Closest Go idea | The difference that matters |
|---|---|---|
| A process (`spawn`, `GenServer.start_link`) | A goroutine | It has its own heap: nothing is shared. If it crashes, only it dies, never the whole program. |
| Its mailbox | A `chan` that only this goroutine reads | Unbounded, and the process can pick messages out of order with pattern matching. A slow process doesn't block senders; its mailbox just grows. |
| A GenServer | A goroutine running `for { select { … } }` that owns some state | OTP writes the loop. You write one callback per kind of message, each returning the new state. |
| `GenServer.call(pid, msg, timeout)` | Send a request carrying a reply channel, then `select` on the reply or `time.After(timeout)` | If it times out, the *caller* exits (like an unrecovered panic), unless it catches the exit. |
| `GenServer.cast(pid, msg)` / `send(pid, msg)` | `ch <- msg` on a channel that never blocks | No reply, and no error if the process is dead: the message is just lost. |
| `handle_info/2` | A `select` case for anything that isn't a call or cast | Timers, PubSub broadcasts, task replies and monitor notices all arrive here. |
| A monitor (`Process.monitor/1`) | Being told when a goroutine exits, and why, as a message | Like an errgroup's error, but for one specific process. |
| A supervisor | No direct equivalent: a parent that restarts children by a policy | Our sessions are `restart: :temporary`, so the supervisor never restarts them. It only owns them, so shutdown is orderly. |
| `:global` registration | A cluster-wide `map[name]pid`, guarded by a cluster-wide lock | Only spans nodes that are connected (Exercise 4 shows what happens during a split). |
| `:pg` groups | A cluster-wide `map[group][]pid` that drops a pid when it dies | Membership is eventually consistent across nodes. |
| `Phoenix.PubSub` | A fan-out broadcast to every subscriber, on every node | Each subscriber gets a copy in its own mailbox. |
| `Task.Supervisor.async_nolink` | `go func() { … }()` plus a channel for its result, with `recover` turning a panic into a message | The task's crash can't take the caller down with it. |

Two consequences shape the whole design:

- **No mutexes.** Only the session process ever reads or writes its state. Other processes send it messages, and it handles them one at a time. That's the Go advice "share memory by communicating", enforced by the runtime.
- **A crash loses the state.** A process that dies takes its heap with it. So `Feed.Session` is designed as a *cache*: everything it needs is in Postgres, and a new process rebuilds from there (Exercise 2).

## The session as a Go sketch

This isn't real code. It's the shape of `Feed.Session`, written the way you'd write it in Go:

```go
type session struct {
    scope      Scope
    id         string                  // the client's feed session id
    settings   Settings                // carries Version
    cache      map[ContentID]Candidate // ~500 scored candidates
    served     []Served                // what the client holds, in order
    position   int                     // index of the item on screen
    rev        int                     // bumps on every re-rank
    refilling  *int                    // settings version a refill runs under
}

func (s *session) loop(mailbox <-chan any) {
    const idle = 10 * time.Minute
    timer := time.NewTimer(idle)
    for {
        select {
        case m := <-mailbox:
            timer.Reset(idle)
            switch m := m.(type) {
            case nextPage:        // GenServer.call      → handle_call({:next_page, limit}, ...)
                items := s.serve(s.nextItems(m.limit)) // writes impressions to Postgres
                s.maybeRefill()
                m.reply <- page{Rev: s.rev, Items: items}
            case at:              // GenServer.cast      → handle_cast({:at, impression_id, rev}, ...)
                s.rev = max(s.rev, m.rev)
                s.position = s.indexOf(m.impressionID)
            case settingsChanged: // PubSub broadcast    → handle_info({:settings_changed, settings}, ...)
                if m.settings.Version > s.settings.Version {
                    s.settings = m.settings
                    s.rerankTail() // replace everything after s.position, push to the client
                    s.maybeRefill()
                }
            case interestsChanged: // PubSub broadcast   → handle_info({:interests_changed, reason}, ...)
                if m.reason == learned {
                    s.featuresStale = true // re-read before the next page, not now
                } else { // forgot: an explicit control
                    s.features = loadFeatures(s.user, s.settings)
                    s.rerankTail()
                }
            case refillDone:      // task's reply        → handle_info({ref, {:refill, version, candidates}}, ...)
                if m.version == s.settings.Version {
                    s.merge(m.candidates)
                }
            case refillCrashed:   // monitor's :DOWN     → handle_info({:DOWN, ref, ...}, ...)
                s.refilling = nil
            }
        case <-timer.C:           // the idle timeout    → handle_info(:timeout, ...)
            return                // {:stop, :normal, state}
        }
    }
}
```

The real code differs from this in three ways, all OTP idioms:

- **There's no loop to write.** `use GenServer` provides it. Each `case` above is a separate callback clause, and Elixir picks the clause by **pattern matching** on the message's shape: `handle_call({:next_page, limit}, ...)`, `handle_info({:settings_changed, settings}, ...)` and so on. Several clauses of the same function act like a `switch`.
- **State is a value, not a pointer.** Each callback receives the current state and *returns* the new one: `{:noreply, new_state, timeout}` or `{:reply, value, new_state, timeout}`. `%{state | rev: 1}` builds a new map with `rev` changed; nothing is mutated in place.
- **The idle timer is the last element of every return tuple** (`@idle_ms`). OTP sends `:timeout` if no message arrives within that time, which plays the role of `timer.Reset` and `case <-timer.C`.

## Walking the real code

Each heading names the function to read in [`session.ex`](../../apps/server/lib/tspec/feed/session.ex).

### Finding or starting a session: `ensure/3`, `make_room/1`, `start_link/1`
- **Callers don't hold a pid.** `GET /api/feed/for-you` and every `FeedChannel` message call `Session.ensure/3`, which looks the session up by name, `{Session, user_id, session_id}`, in `:global`. If no node has it, it starts one under `TSpec.Feed.SessionSupervisor`.
  - **In Go terms:** `registry.LoadOrStart(key, func() { go newSession(...).loop(mb) })`, with the registry spanning every connected node.
- **Two callers starting at once.** One wins the name. The other gets `{:error, {:already_started, pid}}`, and `ensure` uses that pid.
- **The per-user cap.** `make_room/1` counts the user's sessions with `:pg` (`Session.list/1`) and stops the oldest beyond 10. It's a synchronous `GenServer.stop/3`, so the caller waits for it (U5 in [`unsure.md`](../review/unsure.md)).
- **A just-died process.** It can stay registered for a moment, so `ensure` retries with short sleeps before giving up (U2).

### Starting up: `init/1`, `handle_continue(:load, ...)`, `rebuild/1`
- **`init/1` must return fast,** because the caller of `start_link` blocks until it does. So it only joins the `:pg` group, subscribes to the user's settings broadcasts and reads the settings. Then it returns `{:continue, :load}`.
- **`handle_continue(:load, ...)` runs next, before any message.** It rebuilds what the client already holds from the session's stored impressions (`rebuild/1`), then gathers candidates. In Go terms, that's the setup code at the top of the goroutine, before the `for`.
- **`rebuild/1` is what makes a crash cheap.** It replays the session's impressions in `(rev, position)` order. Each new `rev` truncates the list where that re-rank started, then appends. The client's position is the furthest impression it reported actually showing. Exercise 2 kills a session and checks that the rebuilt list matches.

### Serving a page: `handle_call({:next_page, limit}, ...)`, `next_items/2`, `serve/2`
- **`next_items/2` picks the best unserved candidates.** It's the pure ranker (`Ranker.rank/5`) over the cache, skipping what's already served or kept on screen.
- **`serve/2` writes an impression row for each item** through `Ranking.serve/3`, with its contribution trace, `rev` and `settings_version`, then appends to `served`.
- **The reply goes back to the caller,** who waited with a 15 s timeout (`Session.next_page/2`). Note that this database write happens *inside* the session process. While it runs, the mailbox waits (U4).

### Position reports: `handle_cast({:at, impression_id, rev}, ...)`
- **It's a cast:** the channel doesn't wait for a reply. The session finds the impression in `served` and moves `position`.
- **An unknown impression** is one the client kept on screen through a re-rank. `remember_kept/2` records its content, so it's never served again.
- **A higher `rev` from the client is adopted.** The client can be ahead after the session restarted, because an empty re-rank leaves no impressions to rebuild from.

### Settings changes: `handle_info({:settings_changed, settings}, ...)`, `rerank_tail/1`
- **This is a `handle_info`, not a call or cast.** It comes from `Phoenix.PubSub`, which `Transparency.update_settings/2` broadcasts after its transaction commits.
- **The guard `when v > state.settings.version` drops stale broadcasts.** PubSub across nodes doesn't promise order, and a separate clause swallows the stale ones.
- **`rerank_tail/1` keeps everything up to the client's position** (`kept_count/1`), bumps `rev`, serves a new page and broadcasts `{:feed_reranked, ...}` on the session's own topic. `FeedChannel` relays that to the client. Exercise 3 watches it happen.

### Profile changes: `handle_info({:interests_changed, reason}, ...)`
- **Same topic, different message.** `AffinityWorker` broadcasts `:learned` after it applied views, and "forget this interest" broadcasts `:forgot`, both after their transactions commit.
- **Two clauses, matched on the message's second element.** `{:interests_changed, :learned}` only sets `features_stale`; `handle_call({:next_page, ...})` calls `refresh_if_stale/1` first. That's a dirty flag, the same trick as a Go struct with a `stale bool` checked before use: a burst of views costs one database read, and none if nobody scrolls.
- **`drain_interests_changed/0` empties the mailbox of waiting profile messages** after a forget, with a zero-timeout `receive`: the Elixir version of a non-blocking drain loop over a Go channel (`for { select { case <-ch: ...; default: return } }`).
- **`maybe_refill/2` also looks for new top topics.** `gathered_top_topic_ids` remembers what the cache was gathered for; a top topic that's new since then and thin in the cache gets a targeted refill.

### Refills: `maybe_refill/2`, `start_refill/2`, `apply_refill/3`, the `:DOWN` clause
- **The slow SQL runs in a task,** so the session keeps answering. `Task.Supervisor.async_nolink` starts it and monitors it in one step.
- **When the task finishes, its result arrives as a message,** `{ref, {:refill, version, candidates}}`. `Process.demonitor(ref, [:flush])` then drops the matching `:DOWN`.
- **If the task crashes, only `:DOWN` arrives.** The session clears `refill_ref` and backs off, instead of waiting forever.
- **`apply_refill/3` merges only if the settings version still matches.** Its first clause pattern-matches the same `version` variable twice (`%{settings: %{version: version}}` and the `version` argument), which is Elixir's way of saying "these must be equal". The second clause discards stale results.

### Idle timeout: `handle_info(:timeout, ...)`
After 10 minutes with no message, the session returns `{:stop, :normal, state}`. The process exits, and `:global` and `:pg` drop it automatically. The next request starts a fresh one, which rebuilds.

## What tends to surprise Go developers

- **Unbounded mailboxes.** Nothing blocks a sender. A session stuck on a slow query keeps queueing `at` casts. Back-pressure is something you design (U4).
- **A call timeout exits the caller.** It isn't a returned error. `FeedChannel` matches `{:ok, pid} = Session.ensure(...)`, so a failure there crashes the channel process, and the client rejoins (U2).
- **A cast to a dead process is silently lost.** That's fine for position reports, because the next one corrects it. It wouldn't be fine for anything that must arrive.
- **"Let it crash" only works if the state can be rebuilt.** That's why the session writes impressions as it serves them: Postgres is the record, and the process is a cache.
- **Names are cluster-wide only while nodes are connected.** Exercise 4 shows two owners during a split. It's why the private beta runs on one machine ([ADR 0013](../adr/0013-single-machine-private-beta.md)).

## Exercises

Run these from `apps/server`, with the database up (`make db`), in `iex -S mix phx.server` unless an exercise says otherwise. The dev environment logs every SQL query, so start with:

```elixir
Logger.configure(level: :info)
alias TSpec.{Accounts, Transparency}
alias TSpec.Feed.Session
user = Accounts.get_user_by_handle("your_handle")   # any onboarded user in your dev DB
scope = Accounts.scope_for_user(user)
```

`:observer.start()` gives a GUI of the process tree, but only if your Erlang was built with `wx`. The mise build in this repo wasn't, so these exercises use the shell instead.

### 1. Find a session and look inside it
```elixir
session_id = Ecto.UUID.generate()
{:ok, pid} = Session.ensure(scope, session_id)
{:ok, page} = Session.next_page(pid)
state = Session.state(pid)
{length(state.served), state.rev, state.position, map_size(state.cache)}
Session.list(user.id)                                        # the user's live sessions, any node
Supervisor.which_children(TSpec.Feed.SessionSupervisor)      # every session on this node
```
**Expected:** something like `{10, 0, -1, 243}`. That's 10 served, `rev` 0, no position reported yet (`-1`), and a cache of a few hundred candidates. `state` is the struct the callbacks pass around; compare its fields with the Go sketch above.

### 2. Kill it and watch it rebuild
```elixir
ref = Process.monitor(pid)
Process.exit(pid, :kill)
flush()                                                      # {:DOWN, ^ref, :process, ^pid, :killed}
{:ok, pid2} = Session.ensure(scope, session_id)
state2 = Session.state(pid2)
Enum.map(state.served, & &1.impression_id) == Enum.map(state2.served, & &1.impression_id)
```
**Expected:** a new pid, and `true`. The new process rebuilt exactly the list the old one had served, from the `impressions` table. Nothing else noticed the crash. If the web client had been on this feed, its next `at` message would have started the new process the same way.

### 3. Watch a settings change re-rank the feed
```elixir
Phoenix.PubSub.subscribe(TSpec.PubSub, Session.topic(user.id, session_id))
{:ok, _} = Transparency.update_settings(scope, %{topics: %{"travel" => %{multiplier: 1.5}}})
flush()                                  # {:feed_reranked, %{rev: 1, after_impression_id: ..., items: [...]}}
Session.state(pid2).rev                  # 1, or 2 if a refill pushed again
{:ok, _} = Transparency.reset_settings(scope)
```
Your iex process subscribed to the same topic `FeedChannel` relays, so you receive exactly what the client would. For the raw message flow, run `:sys.trace(pid2, true)` before the change and `:sys.trace(pid2, false)` after. It prints every message the process receives and every new state, in Erlang syntax and at length.

### 4. Two nodes, one name, and a netsplit
No app is needed here, just two terminals:

```
iex --sname a --cookie demo     # terminal A
iex --sname b --cookie demo     # terminal B
```

In terminal A, first build B's node name: `[_, host] = String.split(to_string(node()), "@"); b = String.to_atom("b@" <> host)`.

| Step | Terminal | Type | You'll see |
|---|---|---|---|
| 1 | A | `Node.connect(b)` | `true` |
| 2 | A | `pid = spawn(fn -> Process.sleep(:infinity) end); :global.register_name(:feed, pid)` | `:yes` |
| 3 | B | `:global.whereis_name(:feed)` | A's pid: one owner, cluster-wide |
| 4 | B | `:global.register_name(:feed, self())` | `:no`: the name is taken |
| 5 | A | `Node.disconnect(b)` | `true`: the split |
| 6 | B | `:global.whereis_name(:feed)` | `:undefined` |
| 7 | B | `pid = spawn(fn -> Process.sleep(:infinity) end); :global.register_name(:feed, pid)` | `:yes`: now **two owners** |
| 8 | A | `Node.connect(b)` | `true`, then `[info] global: Name conflict terminating {:feed, #PID<…>}` |
| 9 | B | `{:global.whereis_name(:feed), Process.alive?(pid)}` | A's pid, `false`: B's process was killed |

`:global` resolved the conflict by killing one owner, and the node that lost it got no error, just a dead process. Now imagine those were two `Feed.Session` processes that had each written impressions during the split. That's U1 in [`unsure.md`](../review/unsure.md), and the reason for [ADR 0013](../adr/0013-single-machine-private-beta.md).

### 5. Break a guard and watch a test catch it
From the repo root:
```
python3 scripts/mutation_checks.py M7
```
M7 removes the `when v > state.settings.version` guard (see the settings section above), runs the session tests, and restores the file. To see the failure itself, make the same edit by hand in `session.ex`, changing the guard to `when is_integer(v)`. Then run `mix test test/tspec/feed/session_test.exs` and read the failure in [session_test](../../apps/server/test/tspec/feed/session_test.exs): "a settings broadcast older than the session's version is ignored". Undo the edit afterwards.

### 6. Reproduce a real deadlock
This deadlock was found in review and fixed. Lock rows a foreign key points at with `FOR NO KEY UPDATE` (I20 in [`concurrency.md`](../review/concurrency.md)). To see what it looked like, change `lock_user/1` in `apps/server/lib/tspec/transparency.ex` from `"FOR NO KEY UPDATE"` back to `"FOR UPDATE"`, then run:
```
mix test test/tspec/feed/interests_concurrency_test.exs
```
**Expected:** `ERROR 40P01 (deadlock_detected)` in [interests_concurrency_test](../../apps/server/test/tspec/feed/interests_concurrency_test.exs): "the affinity worker and a switch to non-personalized can't deadlock". Read the test's comment for the two lock waits that form the cycle, then put the lock back.

## Further reading

- *Elixir in Action*, Saša Jurić: processes, GenServers, supervision and distribution, written for programmers coming from other languages.
- "The Soul of Erlang and Elixir", Saša Jurić's talk: an hour on why the BEAM is built this way.
- *Designing Data-Intensive Applications*, Martin Kleppmann, chapters 7–9: transactions, how distributed systems fail, and consistency.
- The PostgreSQL manual's "Concurrency Control" chapter, especially explicit row locks (`FOR UPDATE` vs `FOR NO KEY UPDATE`).
- Fred Hébert's free *Learn You Some Erlang* (the "Distribunomicon" chapter) and *Erlang in Anger*, for when clustering and production operations become real.
