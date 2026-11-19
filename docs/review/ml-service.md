# ML service (`services/ml`)

The Python service that will label content (Phase 1b, [ADR 0003](../adr/0003-python-ml-service.md)). This page covers it as of Phase 1b's first milestone: the HTTP API, media fetching and decoding, and the limits, running on **fake models**. Real models (M2) and Phoenix's jobs that call it (M3) come next, and will update this page.

It is stateless and keeps nothing: each request works in a temporary directory that is removed when the request ends, and transcripts and captions are never logged. It returns scores, never approve/reject decisions.

## Trust boundaries

```
Phoenix (Oban jobs) ──bearer secret──▶ ML service ──https, allowlisted hosts──▶ video provider CDN
                                          │
                                          └──▶ prlimit ▶ ffmpeg / ffprobe (local files only)
```

- **Callers.** Only Phoenix's Oban jobs, over a private network, with a shared secret. The service isn't meant to be reachable from the internet; the secret is defense in depth.
- **Media.** The URL comes from Phoenix (the provider's playback URL for an asset Phoenix tracks), never from a user. The playlists and segments come from the provider, which transcodes every upload, so ffmpeg parses the provider's output, not raw user files. Even so, each URL and each file is treated as hostile.

## Entry points

| Entry point | Auth | Limits | Notes |
|---|---|---|---|
| `GET /health` | none | — | Returns `{"status": "ok"}` and nothing else. |
| `POST /v1/extract/video` | `Authorization: Bearer <secret>`, compared with `hmac.compare_digest` | One request at a time (I36); a deadline (the sooner of the client's `deadline_ms` and 30 s + 1 s per second of media, at most 300 s); the media limits below | Fetches the media, probes it, extracts up to 8 frames and the audio, transcribes. |
| `POST /v1/score` | as above | One request at a time; request size: caption ≤ 2,200 characters, body ≤ 2,000, transcript ≤ 100,000, ≤ 64 frame embeddings | No network or file access; only the models. |
| Outbound media fetch | — | https only (http in dev); host and port on `TSPEC_ML_ALLOWED_MEDIA_HOSTS`; redirects followed by hand, at most 3, each re-checked; playlists ≤ 1 MB; media ≤ 300 MB; ≤ 600 segments; ≤ 200 s | Every URL is checked (I37): the playlist, variants, audio playlists, init segments, segments and redirect hops. Encrypted, byte-range and live playlists are refused. |
| ffmpeg and ffprobe | — | `prlimit --cpu` (from the deadline) and `--as` (4 GB); a wall-clock timeout, after which the process is killed | Reads only files the service downloaded, with `-protocol_whitelist file` and an explicit input format, after a check of the container's first bytes (I38). |

Errors are `{"error": code, "detail": text}`. A 4xx is permanent for that input; a 5xx may pass, and the job retries (M3). The `detail` names hosts and stages, never captions or transcripts.

## Invariants

| # | Invariant | Enforced by | Test | Mutation |
|---|---|---|---|---|
| I36 | A request that arrives while another is running is refused at once with 503 and `Retry-After`, never queued, and `/health` still answers. | `SingleFlight.hold()` takes a lock without blocking. The work endpoints are plain `def`, so they run in FastAPI's thread pool, not on the event loop. uvicorn runs one worker, since the lock lives in the process. Phoenix's Oban limit can't do this alone: it is per Phoenix node, and a deploy can restart Phoenix while the service is still working on the abandoned request. | [test_busy.py](../../services/ml/tests/test_busy.py): "test_a_second_request_is_refused_while_one_runs" | M39 |
| I37 | The service fetches nothing that isn't on the allowlist: not a variant, an audio playlist, a segment or a redirect target. | `Fetcher.get` checks every URL before fetching it, and follows redirects itself, checking each hop. ffmpeg never fetches (I38). | [test_hls.py](../../services/ml/tests/test_hls.py): "test_every_segment_must_be_on_the_allowlist"; [test_fetch.py](../../services/ml/tests/test_fetch.py): "test_redirects_are_followed_only_onto_the_allowlist"; [test_extract.py](../../services/ml/tests/test_extract.py): "test_media_off_the_allowlist_is_a_permanent_error" | M40 |
| I38 | ffmpeg reads only local files in the container format their playlist declared, so a "segment" that is really a playlist can't make it read other files. | `hls._check_container` checks the first bytes (MPEG-TS sync byte, or an fMP4 `ftyp` box) before ffmpeg runs; ffmpeg gets `-f mpegts` or `-f mov` and `-protocol_whitelist file`. | [test_hls.py](../../services/ml/tests/test_hls.py): "test_a_segment_that_isnt_media_is_refused_before_ffmpeg_sees_it" | M41 |

Also tested, without a mutation:
- **Silent audio isn't confused with missing audio.** Audio in its own playlist (`#EXT-X-MEDIA:TYPE=AUDIO`) is downloaded and transcribed; a video with no audio stream returns `has_audio: false`. [test_extract.py](../../services/ml/tests/test_extract.py): "test_audio_in_its_own_playlist_is_transcribed"; [test_extract.py](../../services/ml/tests/test_extract.py): "test_a_video_without_sound_says_so".
- **The limits are real.** [test_ffmpeg.py](../../services/ml/tests/test_ffmpeg.py): "test_the_address_space_limit_is_real"; [test_ffmpeg.py](../../services/ml/tests/test_ffmpeg.py): "test_a_run_past_the_deadline_is_killed"; [test_extract.py](../../services/ml/tests/test_extract.py): "test_the_service_gives_up_at_the_clients_deadline".

## Not covered yet

- **Real models (M2).** Model weights are code: they'll be pinned to commits, loaded from `safetensors` (SigLIP, e5) or CTranslate2 (Whisper), never from pickle files. A deadline can't interrupt one model call, so the transcriber will check it between segments.
- **The container (deploy, Phase 2).** Non-root, read-only filesystem except the temporary directory, no outbound network except the allowlisted hosts.
- **Allowlisted hosts are trusted by name.** See [unsure.md](unsure.md), U15.
