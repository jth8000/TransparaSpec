# ADR 0003: Python ML service for content understanding

- **Status:** Accepted
- **Date:** 2026-10-20

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
