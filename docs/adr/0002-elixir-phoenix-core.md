# ADR 0002: Elixir/Phoenix core backend

- **Status:** Accepted
- **Date:** 2026-10-20

## Context
The candidates were Go (the user's strongest language), Rust and Elixir (the user has some experience with both). At beta scale, raw concurrency doesn't decide between them: all three handle the connection counts easily. The real bottlenecks are CDN delivery, transcoding and ranking compute. The deciding factors are:
- **Real-time push**: live feed re-ranking and notifications.
- **Durable background jobs**: media pipeline, ML, affinity updates and ledger accruals.
- **Fault tolerance**: two people running production.
- **Productivity on social-app plumbing.**

## Decision
Use **an Elixir/Phoenix monolith**, organized as Phoenix contexts, for the API, auth, feed, ranker, real-time and jobs:
- **Phoenix Channels and PubSub** for push.
- **Oban** (Postgres-backed) for durable jobs.
- **Ecto** for data access.
- **One supervised `Feed` process per active user** to cache candidates and re-rank live.

## Consequences
- Real-time messaging across a cluster, Presence and durable jobs all come built in. With Go we'd have to build a WebSocket hub, Redis pub/sub and a queue (River) ourselves.
- Supervision trees isolate crashes. LiveDashboard gives observability for free.
- **Weakness**: CPU-heavy number crunching. Mitigated by keeping v1 scoring simple and moving to Rust when profiling shows the need (ADR 0004).
- **Learning curve** for the user. Mitigated because Claude writes most of the code and the user reviews and steers, plus consistent context boundaries and docs.

## Alternatives considered
- **Go core**, as in Gemini's proposal: Go API + Rust transcode worker + Python ML. Fully viable and the fastest for the user to read. Rejected because of the extra real-time and job plumbing we'd have to build.
- **Rust core.** Slowest to iterate on for a two-person team. Rust is better as a focused sidecar.
