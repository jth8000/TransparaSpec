# Learning notes

Walkthroughs of how T-Spec's trickier parts work, written for a developer whose background is Go and who is learning Elixir and OTP. They explain; the [review packet](../review/README.md) is the terse version for outside experts.

| Walkthrough | Covers |
|---|---|
| [`Feed.Session` for Go developers](feed-session-for-go-developers.md) | Processes, GenServers, calls and casts, monitors, `:global` and `:pg`, through the per-feed ranking cache. Six hands-on exercises: inspect a live session, kill it and watch it rebuild, watch a re-rank, simulate a netsplit, break a guard, reproduce a deadlock. |

`test/tspec/docs/learn_docs_test.exs` keeps the links, the `Session.function/arity` references and the cited test names real.
