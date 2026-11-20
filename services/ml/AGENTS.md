# services/ml

The ML service (ADR 0003, amended for Phase 1b). The project-wide rules are in the root `AGENTS.md`; the review packet's page for this service is `docs/review/ml-service.md`.

## Commands
- `make ml-setup`, `make ml` (port 8000, fake models), `make test-ml` (ruff, then pytest).
- Run `uv` with `PYTHONPATH` unset (`env -u PYTHONPATH uv …`, as the Makefile does). This machine has ROS installed, whose `PYTHONPATH` loads its pytest plugins and fails the run with `No module named 'yaml'`.
- `uv add <pkg>` / `uv add --group dev <pkg>` to add dependencies; commit `uv.lock`.

## Rules
- **Work endpoints are plain `def`, never `async def`.** FastAPI runs them in its thread pool, so the event loop stays free for `/health` and for refusing a second request (I36). An `async def` doing CPU work would block both.
- **One uvicorn worker.** The one-request-at-a-time lock lives in the process.
- **Every fetch goes through `Fetcher.get`** (I37). Never give ffmpeg a URL, and never let an HTTP client follow redirects by itself.
- **ffmpeg and ffprobe run through `media.ffmpeg.Runner`**, which wraps them in `prlimit` and passes `-protocol_whitelist file` and an explicit input format (I38). Don't use `subprocess` with `preexec_fn`: it can deadlock in a threaded process.
- **Never log captions, transcripts or embeddings.** Log content ids, stages and timings.
- **Errors map to statuses in `main.ERRORS`:** a 4xx is permanent for that input, a 5xx retryable. Pick deliberately; Phoenix's jobs act on the difference. A limit or a kill is never the input's fault: a tool killed by a signal is `MediaToolKilled` (500), not `MediaDecodeFailed` (422).
- **Error bodies never carry request values.** `invalid_request` names fields and error types only; Pydantic's own errors include the input, which may be a caption.
- **No character limits on text fields.** Phoenix counts graphemes, which can be many code points each. The request is capped in bytes (`BodyLimit`), and texts are cut before embedding.
- **CPU time adds up across threads.** A `prlimit --cpu` (or any CPU budget) equal to wall-clock seconds kills a multi-threaded ffmpeg early. The wall-clock timeout enforces the deadline; the CPU limit is the time left times the usable CPUs.
- **`taxonomy.json` is generated** (`mix tspec.export_taxonomy`); edit `prompts.json` instead. Topics with `model: false` are never scored.
- **The contract** is `tspec_ml/schemas.py`, with examples in `contract/`. Change both together; Phoenix's tests read the same files.
- **Tests:** media fixtures are generated with ffmpeg in `tests/conftest.py`, and served through `httpx.MockTransport`, so tests never touch the network. A test that needs a request genuinely in progress uses a real uvicorn server and a backend that waits on an event (`test_busy.py`).
