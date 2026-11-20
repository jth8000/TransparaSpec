# Contract fixtures

Example requests and responses for the ML service's HTTP API
(`tspec_ml/schemas.py`). The service's tests check that each one parses
against its schema. Phoenix's client tests (Phase 1b, M3) decode the same
files, so a change to either side that breaks the other fails a test.

Real responses carry about 350 topics per modality and 768-dimensional
embeddings; these are trimmed to stay readable.

Errors are `{"error": code, "detail": text}` (`detail` is optional). A 4xx
is permanent for that input (the job gives up); a 5xx may pass (the job
retries). A 503 `busy` carries `Retry-After`. `detail` names fields, hosts
and stages, never what the request carried: an `invalid_request` lists the
fields and the kind of problem, not their values.

The codes: 400 `media_url_not_allowed`; 401 `unauthorized`; 409
`frame_model_mismatch`; 413 `request_too_large` (the body is capped in
bytes, not texts in characters: each text is cut before it's embedded);
422 `invalid_request`, `unsupported_media`, `media_too_large`,
`media_decode_failed`, `no_video`; 500 `media_tool_killed`, `internal`;
502 `media_fetch_failed`; 503 `busy`; 504 `deadline_exceeded`.
