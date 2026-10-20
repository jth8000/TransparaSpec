# ADR 0004: Rust deferred, reserved for ranking/graph hot paths

- **Status:** Accepted
- **Date:** 2026-10-20

## Context
One proposal was a Rust worker for video transcoding. But transcoding is done by ffmpeg's C libraries (libx264, libav*) whichever language calls them. Rust "native bindings" add API churn and `unsafe` code, and an ffmpeg crash takes down the whole worker process, all without any speed gain. The industry norm is to run the ffmpeg CLI as a supervised OS process. In any case, video is handled by a managed provider in the MVP (ADR 0005).

Where Rust *does* beat the BEAM by a wide margin is CPU- and memory-heavy recommendation work:
- scoring large candidate sets
- random walks over a large user–item graph (Pinterest's Pixie)
- in-memory feature stores

## Decision
- No Rust in the MVP.
- Add Rust only when profiling shows a ranking or graph bottleneck, in one of two forms:
  - a **Rustler NIF** for pure scoring functions (dirty-scheduler safe), or
  - a **standalone graph-walk service** that keeps the bipartite graph in memory.
- If we ever self-host transcoding, it will be an Oban job running the ffmpeg CLI on worker-only machines, not Rust.

## Consequences
- Two runtimes (BEAM + Python) instead of three until Rust actually earns its place.
- The ranker and candidate-source interfaces in the `Feed` context must be clean enough that we can swap an implementation without changing callers.
