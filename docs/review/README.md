# Review packet

For experienced Elixir, distributed-systems and security reviewers looking at T-Spec before a beta.

**Context.** T-Spec is a personal project: one developer, whose background is Go, plus AI coding agents. Nearly all the server code was written by an AI agent. Its tests check the failure modes the agent thought of. This packet exists so a human expert can quickly check the claims that matter, and find what nobody thought of.

## What's here

| File | What it covers |
|---|---|
| [threat-model.md](threat-model.md) | Assets, attackers, trust boundaries, every entry point with its auth and limits, and the known gaps. |
| [concurrency.md](concurrency.md) | The process tree, every lock, the lock order, and an **invariant table**: each invariant with the code that enforces it, the test that proves it, and a mutation that breaks it. |
| [unsure.md](unsure.md) | Where we think a reviewer is most likely to find a problem, and what would settle each question. **Start here if your time is short.** |

This first part covers the server. The client (token storage, deep links, what the server trusts the client for) is still to come.

## Checking the claims

- **`make mutation-check`** ([`scripts/mutation_checks.py`](../../scripts/mutation_checks.py)) breaks each concurrency and security guard in the invariant table (a lock, a conditional `UPDATE`, a version check), runs the tests that should catch it, and restores the file. Every row with a mutation id should report CAUGHT. It takes a few minutes.
- **`test/tspec/docs/review_packet_test.exs`** runs in `make test`. It fails if this packet links to a file that doesn't exist, cites a test that isn't in its file, or the mutation ids in [concurrency.md](concurrency.md) and the script disagree.
- **Running the tests:** `make setup`, then `make test`. `AGENTS.md` lists the gotchas, such as which tests must be `async: false` and why.

## Where to start reading the code

1. `TSpec.Feed.Session` (`apps/server/lib/tspec/feed/session.ex`), the per-feed GenServer, with [ADR 0011](../adr/0011-feed-sessions-and-live-rerank.md).
2. `TSpec.Feed.Interests.apply_dirty_views/2` and `track_views/4` (`apps/server/lib/tspec/feed/interests.ex`), with [ADR 0012](../adr/0012-interest-model-and-controls.md).
3. `TSpec.Accounts` (`apps/server/lib/tspec/accounts.ex`): `request_login/2`, `verify_login_code/2`, `verify_login_token/2`.
4. `TSpec.Events.record/2` (`apps/server/lib/tspec/events.ex`).

## Reporting

Report security problems privately, as described in [`SECURITY.md`](../../SECURITY.md). Anything else can be a GitHub issue or a comment on the relevant file.

## Keeping it current

`AGENTS.md` requires any PR that changes a lock, process, channel, Oban job, auth path, entry point or money path to update this packet in the same PR.
