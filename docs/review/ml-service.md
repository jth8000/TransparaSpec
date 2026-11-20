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
| Every request | — | The body is capped at 16 MiB and refused with 413 before it's parsed (`BodyLimit`). FastAPI parses a JSON body before the bearer check runs, so this is what bounds an unauthenticated request. | |
| `POST /v1/extract/video` | `Authorization: Bearer <secret>`, compared with `hmac.compare_digest` | One request at a time (I36); a deadline (the sooner of the client's `deadline_ms` and 30 s + 1 s per second of media, at most 300 s); the media limits below | Fetches the media, probes it, extracts up to 8 frames (one from the middle of each eighth of the video) and the audio, transcribes. |
| `POST /v1/score` | as above | One request at a time; ≤ 64 frame embeddings. No character limits on text: Phoenix counts graphemes, and a grapheme can be any number of code points, so a limit here could permanently refuse a caption Phoenix accepted. Each text is cut to 20,000 code points before it's embedded, past what the models read. | No network or file access; only the models. |
| Outbound media fetch | — | https only (http in dev); host and port on `TSPEC_ML_ALLOWED_MEDIA_HOSTS`; redirects followed by hand, at most 3, each re-checked; playlists ≤ 1 MB; media ≤ 300 MB; ≤ 600 segments; ≤ 200 s | Every URL is checked (I37): the playlist, variants, audio playlists, init segments, segments and redirect hops. Encrypted, byte-range and live playlists are refused. |
| ffmpeg and ffprobe | — | A wall-clock timeout at the deadline, after which the process is killed; `prlimit --as` (4 GB) and `--cpu`. CPU time adds up across ffmpeg's threads, so the CPU limit is the time left times the CPUs the process may use: a backstop for an ffmpeg orphaned by a dead service, which can't fire before the timeout does. | Reads only files the service downloaded, with `-protocol_whitelist file` and an explicit input format, after a check of the container's first bytes (I38). |

Errors are `{"error": code, "detail": text}`, the codes listed in [contract/README.md](../../services/ml/contract/README.md). A 4xx is permanent for that input; a 5xx may pass, and the job retries (M3). The `detail` names fields, hosts and stages, never what the request carried: an invalid request lists its fields and the kind of problem, not their values, and an unexpected error is just `internal`. A tool killed by a signal is `media_tool_killed` (retryable), not `media_decode_failed` (permanent): a kill says nothing about the media.

## Invariants

| # | Invariant | Enforced by | Test | Mutation |
|---|---|---|---|---|
| I36 | A request that arrives while another is running is refused at once with 503 and `Retry-After`, never queued, and `/health` still answers. | `SingleFlight.hold()` takes a lock without blocking. The work endpoints are plain `def`, so they run in FastAPI's thread pool, not on the event loop. uvicorn runs one worker, since the lock lives in the process. Phoenix's Oban limit can't do this alone: it is per Phoenix node, and a deploy can restart Phoenix while the service is still working on the abandoned request. | [test_busy.py](../../services/ml/tests/test_busy.py): "test_a_second_request_is_refused_while_one_runs" | M39 |
| I37 | The service fetches nothing that isn't on the allowlist: not a variant, an audio playlist, a segment or a redirect target. | `Fetcher.get` checks every URL before fetching it, and follows redirects itself, checking each hop. ffmpeg never fetches (I38). | [test_hls.py](../../services/ml/tests/test_hls.py): "test_every_segment_must_be_on_the_allowlist"; [test_fetch.py](../../services/ml/tests/test_fetch.py): "test_redirects_are_followed_only_onto_the_allowlist"; [test_extract.py](../../services/ml/tests/test_extract.py): "test_media_off_the_allowlist_is_a_permanent_error" | M40 |
| I38 | ffmpeg reads only local files, in a container format HLS allows for that playlist and that it is told explicitly, so a "segment" that is really a playlist can't make it read other files. | `hls._container` checks the first bytes before ffmpeg runs: an fMP4 `ftyp` box after an init segment, else the MPEG-TS sync byte, or, for an audio playlist only, packed AAC (an ADTS frame, after an ID3 tag). ffmpeg gets `-f mov`, `-f mpegts` or `-f aac`, and `-protocol_whitelist file`. | [test_hls.py](../../services/ml/tests/test_hls.py): "test_a_segment_that_isnt_media_is_refused_before_ffmpeg_sees_it"; [test_hls.py](../../services/ml/tests/test_hls.py): "test_packed_audio_is_refused_for_the_video" | M41 |

Also tested, without a mutation:
- **Silent audio isn't confused with missing audio.** Audio in its own playlist (`#EXT-X-MEDIA:TYPE=AUDIO`) is downloaded and transcribed; a video with no audio stream returns `has_audio: false`. [test_extract.py](../../services/ml/tests/test_extract.py): "test_audio_in_its_own_playlist_is_transcribed"; [test_extract.py](../../services/ml/tests/test_extract.py): "test_a_video_without_sound_says_so".
- **Packed audio is transcribed.** [test_extract.py](../../services/ml/tests/test_extract.py): "test_packed_audio_in_its_own_playlist_is_transcribed".
- **The limits are real, and a limit is never mistaken for bad media.** [test_ffmpeg.py](../../services/ml/tests/test_ffmpeg.py): "test_the_address_space_limit_is_real"; [test_ffmpeg.py](../../services/ml/tests/test_ffmpeg.py): "test_a_run_past_the_deadline_is_killed"; [test_ffmpeg.py](../../services/ml/tests/test_ffmpeg.py): "test_a_multithreaded_run_is_stopped_by_the_deadline_not_the_cpu_limit"; [test_ffmpeg.py](../../services/ml/tests/test_ffmpeg.py): "test_a_tool_killed_by_a_signal_is_retryable_not_bad_media"; [test_extract.py](../../services/ml/tests/test_extract.py): "test_the_service_gives_up_at_the_clients_deadline".
- **Frames come from the middle of each slice**, so the first frame (often black or a title card) isn't always one of them and the end of the video is seen. Checked against a clip whose brightness says when each frame was taken, so an ffmpeg upgrade that changes `fps`'s sampling fails it. [test_ffmpeg.py](../../services/ml/tests/test_ffmpeg.py): "test_frames_come_from_the_middle_of_each_slice".
- **Errors never repeat the request, and nothing Phoenix accepts is refused for its length.** [test_errors.py](../../services/ml/tests/test_errors.py): "test_an_invalid_request_names_the_fields_but_not_their_values"; [test_errors.py](../../services/ml/tests/test_errors.py): "test_an_unexpected_error_says_internal_and_nothing_else"; [test_errors.py](../../services/ml/tests/test_errors.py): "test_a_caption_phoenix_accepts_is_never_refused_for_its_length"; [test_errors.py](../../services/ml/tests/test_errors.py): "test_a_body_over_the_cap_is_refused_before_it_is_parsed_or_authenticated".

## Not covered yet

- **Real models (M2).** Model weights are code: they'll be pinned to commits, loaded from `safetensors` (SigLIP, e5) or CTranslate2 (Whisper), never from pickle files. A deadline can't interrupt one model call, so the transcriber will check it between segments.
- **The container (deploy, Phase 2).** Non-root, read-only filesystem except the temporary directory, no outbound network except the allowlisted hosts.
- **Allowlisted hosts are trusted by name.** See [unsure.md](unsure.md), U15.
