# Contract fixtures

Example requests and responses for the ML service's HTTP API
(`tspec_ml/schemas.py`). The service's tests check that each one parses
against its schema. Phoenix's client tests (Phase 1b, M3) decode the same
files, so a change to either side that breaks the other fails a test.

Real responses carry about 350 topics per modality and 768-dimensional
embeddings; these are trimmed to stay readable.

Errors are `{"error": code, "detail": text}`. A 4xx is permanent for that
input (the job gives up); a 5xx may pass (the job retries). A 503 `busy`
carries `Retry-After`.
