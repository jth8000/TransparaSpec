"""The HTTP app. Run with one worker (`make ml`):

    uvicorn tspec_ml.main:create_app --factory --workers 1

One worker because the one-request-at-a-time lock lives in the process: a
second worker would have its own. The work endpoints are plain `def`, so
FastAPI runs them in its thread pool and the event loop stays free to answer
`/health` and to refuse a second request with 503 while one is running.
"""

import logging
from pathlib import Path

import httpx
from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import HTTPException, RequestValidationError
from fastapi.responses import JSONResponse

from . import extract, policy, scoring
from . import taxonomy as taxonomy_mod
from .auth import bearer_dependency
from .backends import fake
from .backends.base import Backends
from .config import Settings
from .limits import BodyLimit, Busy, DeadlineExceeded, SingleFlight, deadline_for
from .media import ffmpeg
from .media.fetch import Fetcher, MediaFetchFailed, MediaTooLarge, MediaURLNotAllowed
from .media.hls import UnsupportedPlaylist
from .schemas import ExtractVideoRequest, ExtractVideoResponse, ScoreRequest, ScoreResponse

ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "policy" / "v0.json"

log = logging.getLogger("tspec_ml")

# Exceptions → (status, error code). 4xx are permanent for this input (the
# job gives up); 5xx may pass (the job retries). Details never include
# request values: captions, transcripts or embeddings. Also, outside this
# map: 401 `unauthorized`, 413 `request_too_large` (`BodyLimit`), 422
# `invalid_request`, 503 `busy`, 500 `internal`.
ERRORS = {
    MediaURLNotAllowed: (400, "media_url_not_allowed"),
    UnsupportedPlaylist: (422, "unsupported_media"),
    MediaTooLarge: (422, "media_too_large"),
    ffmpeg.MediaDecodeFailed: (422, "media_decode_failed"),
    ffmpeg.NoVideoStream: (422, "no_video"),
    scoring.FrameModelMismatch: (409, "frame_model_mismatch"),
    ffmpeg.MediaToolKilled: (500, "media_tool_killed"),
    MediaFetchFailed: (502, "media_fetch_failed"),
    DeadlineExceeded: (504, "deadline_exceeded"),
}


def create_app(
    settings: Settings | None = None,
    backends: Backends | None = None,
    transport: httpx.BaseTransport | None = None,
) -> FastAPI:
    settings = settings or Settings()
    backends = backends or fake.backends()
    taxonomy = taxonomy_mod.load(ROOT)
    label_policy = policy.load(POLICY, taxonomy)
    scorer = scoring.Scorer(backends, taxonomy, settings.max_text_chars)
    fetcher = Fetcher(settings, transport)
    runner = ffmpeg.Runner(ffmpeg.Tools.find(), settings)
    flight = SingleFlight()
    auth = Depends(bearer_dependency(settings))

    app = FastAPI(title="T-Spec ML", docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(BodyLimit, max_bytes=settings.max_request_bytes)

    @app.exception_handler(Busy)
    def busy(_request: Request, _exc: Busy) -> JSONResponse:
        return JSONResponse(
            {"error": "busy"},
            status_code=503,
            headers={"Retry-After": str(settings.busy_retry_after_s)},
        )

    for exc_type, (status, code) in ERRORS.items():

        def handler(_request: Request, exc: Exception, status=status, code=code) -> JSONResponse:
            log.info("request failed: %s (%s)", code, type(exc).__name__)
            return JSONResponse({"error": code, "detail": str(exc)}, status_code=status)

        app.add_exception_handler(exc_type, handler)

    @app.exception_handler(RequestValidationError)
    def invalid_request(_request: Request, exc: RequestValidationError) -> JSONResponse:
        # Where and what kind, never the value: Pydantic's errors carry the
        # input, which may be a caption, and Phoenix may log error bodies.
        problems = sorted(
            {
                ".".join(str(p) for p in e.get("loc", ())) + ": " + e.get("type", "?")
                for e in exc.errors()
            }
        )
        return JSONResponse(
            {"error": "invalid_request", "detail": "; ".join(problems)}, status_code=422
        )

    @app.exception_handler(Exception)
    def internal(_request: Request, exc: Exception) -> JSONResponse:
        # uvicorn still logs the traceback; the response says nothing more.
        return JSONResponse({"error": "internal"}, status_code=500)

    @app.exception_handler(HTTPException)
    def http_error(_request: Request, exc: HTTPException) -> JSONResponse:
        body = exc.detail if isinstance(exc.detail, dict) else {"error": str(exc.detail)}
        return JSONResponse(body, status_code=exc.status_code, headers=exc.headers)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/extract/video", dependencies=[auth])
    def extract_video(req: ExtractVideoRequest) -> ExtractVideoResponse:
        with flight.hold():
            deadline = deadline_for(settings, req.duration_ms, req.deadline_ms)
            result = extract.extract_video(
                req,
                settings=settings,
                fetcher=fetcher,
                runner=runner,
                backends=backends,
                deadline=deadline,
            )
            log.info("extracted %s in %s", req.content_id, result.timings_ms)
            return result

    @app.post("/v1/score", dependencies=[auth])
    def score(req: ScoreRequest) -> ScoreResponse:
        with flight.hold():
            raw, embeddings = scorer.score(
                {"caption": req.caption, "body": req.body, "transcript": req.transcript},
                req.frames.embeddings if req.frames else None,
                req.frames.model if req.frames else None,
            )
            return ScoreResponse(
                content_id=req.content_id,
                models={"image": backends.image.model_id, "text": backends.text.model_id},
                prompts_version=taxonomy.version,
                policy_version=label_policy.version,
                raw_scores=raw,
                text_embeddings=embeddings,
                labels=policy.labels(label_policy, None, taxonomy),
            )

    return app
