# ADR 0003: Python ML service for content understanding

- **Status:** Accepted
- **Date:** 2026-10-20 (amended 2026-11-19: see [the amendment](#amendment-phase-1b-the-contract-as-built))

## Context
Ranking and transparency depend on knowing what each piece of content is about (topics) and how similar items are (embeddings). Moderation needs classifiers. The best open models and tooling for this live in the Python ecosystem: Whisper, CLIP, Hugging Face transformers. Elixir's Bumblebee/Nx exists, but the model coverage is narrower.

## Decision
Build **a stateless Python FastAPI service** (`services/ml`). Phoenix calls it over HTTP **from Oban jobs**, so retries and durability live in Oban rather than in the ML service.

| Endpoint | Purpose |
|---|---|
| `POST /analyze/video` | Transcript, frame/text embeddings, topic classification, moderation scores |
| `POST /analyze/text` | Embeddings, topics, toxicity scores |

- **Output contract**: `{topics: [{slug, confidence}], embedding: [...], moderation: {category: score}}`.
- **Moderation output is scores, never approve/reject booleans.** Thresholds and human review live in the Phoenix `Moderation` context.
- **CSAM detection is hash matching** (a legal requirement handled by the `Moderation` context via Cloudflare / PhotoDNA), not this service.

## Consequences
- We get the best model ecosystem without putting Python in the request path.
- A second runtime to deploy. Kept small: CPU-only on one Fly machine for the beta.
- Topic classification may optionally use an LLM pass over caption + transcript. That's an implementation detail behind the same contract.

## Alternatives considered
- **Elixir Bumblebee in-process.** Fewer models, and heavy inference would compete with web traffic on the same VM.
- **Hosted inference APIs only.** Simpler, but costs grow with volume and the models are less controllable. Still usable behind the same contract.

## Amendment (Phase 1b): the contract as built
Planning Phase 1b changed the contract above, and settled where the service runs.

**Extract and score are separate calls.** Re-scoring an item (after a caption edit, new prompts or a new label policy) must not mean fetching and decoding its video again:

| Endpoint | Purpose |
|---|---|
| `POST /v1/extract/video` | Fetches the media and returns what's expensive: the transcript, and per-frame image embeddings. Phoenix stores both. |
| `POST /v1/score` | From caption, body, transcript and stored frame embeddings: per-topic raw scores per modality, text embeddings, and labels under the current label policy. Cheap. |

`/analyze/text` is gone: a text post is a `/v1/score` call. Example requests and responses are in `services/ml/contract/`.

**Moderation scores wait for Phase 2,** where the `Moderation` context will use them and set their thresholds. The rule stands: scores, never decisions.

**One request at a time, enforced by the service.** One analysis uses a whole CPU machine. Oban's queue limit is per Phoenix node, and a deploy can restart Phoenix while the service is still working on the abandoned request, so the service refuses a second request with 503 and the job retries later. Each request also has a deadline shorter than Phoenix's HTTP timeout, so the service always gives up first.

**The service fetches media itself, from allowlisted hosts.** It reads HLS playlists itself, checks every URL against an allowlist, and gives ffmpeg only local files under CPU, memory and time limits. Video bytes still never pass through Phoenix. The review packet covers it ([`docs/review/ml-service.md`](../review/ml-service.md)).

**Labels start in shadow mode.** Model labels reach `content_topics` only for topics whose labels pass an evaluation, and the label policy starts with none enabled. That is decided in ADR 0016 (Phase 1b M2).

**Where it runs.** In development, on the same machine as Phoenix and Postgres (`make ml`). Production placement (a Fly machine, or other hardware) is decided with the Phase 2 deploy. The service avoids x86-only dependencies so either stays possible.
