# ADR 0013: One machine for the private beta

- **Status:** Accepted
- **Date:** 2026-10-29

## Context
Feed sessions have one owner per `{user_id, session_id}` through `:global` ([ADR 0011](0011-feed-sessions-and-live-rerank.md)), which only spans nodes that are connected. So production must either cluster its machines or run one. The roadmap's Phase 2 had planned two clustered machines on Fly.

The review packet ([`docs/review/unsure.md`](../review/unsure.md)) found that a cluster brings risks nothing tests yet:
- **U1:** during a netsplit, each side can start its own process for the same feed session. Both write impressions, and the later rebuild may replay a list the client never had.
- **U3:** the per-client-address rate limits live in each node's memory, so N machines give each address N times the limit.

An invite-only beta is small. One machine handles its load, and a cluster's main benefit, surviving the loss of a machine, matters less while the users are invited testers.

## Decision
- **The private beta runs the Phoenix app on one Fly machine.** `DNS_CLUSTER_QUERY` stays unset. The machine scales vertically if it needs to.
- **Deploys use Fly's rolling strategy (the default).** Blue-green boots a new machine alongside each running one, and canary first boots an extra machine to check its health. Either way, two unclustered machines run at once, so one feed session could briefly have two owners. Don't use them.
- **Two Fly defaults must be overridden,** or they undo this decision:
  - **Redundancy:** the first `fly launch` or `fly deploy` creates two machines for a process group with services. Use `--ha=false`.
  - **Auto-stop:** `fly launch` writes `auto_stop_machines = "stop"`, `auto_start_machines = true` and `min_machines_running = 0`. A stopped machine runs no Oban cron jobs (partition creation, the affinity sweep, impression pruning, upload expiry) and drops every feed session. Set `auto_stop_machines = "off"` and `auto_start_machines = false`.

  Both were checked against Fly's docs on 2026-10-29 ([app availability](https://docs.fly.io/apps/app-availability), [autostop/autostart](https://docs.fly.io/launch/autostop-autostart), [deploy strategies](https://docs.fly.io/launch/deploy)). When `fly.toml` is added, the Phase 2 deploy should check them in CI.
- **What a restart costs:** a deploy or crash restarts the node. Clients reconnect, and feed sessions rebuild from Postgres (ADR 0011). Expect a few seconds of unavailability per deploy.
- **The ML service** (Phase 1b) is a separate machine either way, and Postgres is managed separately, so neither changes.

## Moving to a cluster
Before a second Phoenix machine runs, all of these are needed:
1. **A partition test for feed sessions (U1):** split two `:peer` nodes, serve on both sides, reconnect, rebuild, and check the result. Then fix whatever it finds.
2. **A decision on rate limits (U3):** a limiter shared through Postgres or Redis, or knowingly accepting N times the limit.
3. **The clustering configuration from the roadmap:** `DNS_CLUSTER_QUERY`, node names from private IPs, a shared release cookie, and IPv6 distribution.
4. **A live check on two machines** that a feed session keeps one owner.

## Consequences
- The beta's capacity is one machine's. That's ample at invite scale. Hitting the ceiling is the signal to do the steps above.
- A machine failure is an outage until Fly restarts it. No data is lost, since state lives in Postgres.
- The cluster code stays: `:global` registration, `:pg` session counting and `session_cluster_test.exs`. Moving later is configuration plus the prerequisites above, not a rewrite.

## Alternatives considered
- **Two clustered machines (the previous plan).** Survives one machine failing, but ships U1 and U3 untested to real users.
- **Two unclustered machines.** Each would own its own copy of a feed session. ADR 0011 rules this out.
