# ADR 0005: Managed video behind a provider abstraction

- **Status:** Accepted
- **Date:** 2026-10-20

## Context
A self-hosted upload → transcode → HLS → CDN pipeline is weeks of work plus ongoing operations. For a private beta, getting to the product pillars (transparency and control) faster matters more than per-minute video cost.

## Decision
- Use **a managed video provider**. The default is **Cloudflare Stream**, since it pairs with R2 and the CDN; Mux is the alternative. The final pick happens at Phase 0 implementation.
- Wrap it in a `VideoProvider` Elixir behaviour:
  - `create_direct_upload/1`
  - `get_asset/1`
  - `delete_asset/1`
  - `playback_url/1`
  - `thumbnail_url/2`
  - `verify_webhook/2`
- **Upload flow:**
  1. The client requests a direct-upload URL.
  2. The client uploads straight to the provider.
  3. The provider calls our webhook, which enqueues an Oban `media` job.
  4. The job marks the content ready and enqueues the `ml` analysis.
- Store our own canonical metadata (`short_videos`: provider, asset_id, playback_id, duration, aspect). That way a later migration only re-points assets.

## Consequences
- Upload-to-playback in days rather than weeks. No video bytes pass through Phoenix.
- Per-minute storage and delivery costs, which are acceptable at beta scale.
- A later move to self-hosted (Oban + ffmpeg CLI → HLS on R2 + CDN) is a new `VideoProvider` implementation plus a backfill job.

## Implementation notes (Phase 0)
- **`TSpec.Video.Provider`** implements this behaviour, with two providers:
  - **`CloudflareStream`**: the production default.
  - **`LocalProvider`**: dev/test only. It mimics Cloudflare's shape: a one-time multipart upload URL, an ffmpeg HLS transcode in Oban, and a signed webhook to our own endpoint. That lets the whole pipeline run offline and in CI. It's the single sanctioned exception to "video bytes never pass through Phoenix", and its routes and media serving are compiled out of production.
- **Webhooks**:
  - Verified over the raw request body, then queued and applied idempotently.
  - Upload status is pushed to the creator on their `user:<id>` channel.

