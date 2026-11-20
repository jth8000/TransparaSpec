"""One request at a time, a deadline per request, and a cap on request size.

The service runs on one CPU machine with one uvicorn worker, and one
analysis uses all of it. Phoenix's Oban queue limit is per Phoenix node, and
a deploy can restart Phoenix mid-request while this service keeps working on
the abandoned request, so the service enforces the limit itself: a request
that arrives while another is running is refused at once (503), and the job
retries later.
"""

import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .config import Settings


class Busy(Exception):
    """Another request holds the service."""


class DeadlineExceeded(Exception):
    def __init__(self, stage: str):
        super().__init__(f"deadline exceeded during {stage}")
        self.stage = stage


class SingleFlight:
    def __init__(self) -> None:
        # A plain Lock: FastAPI may run the release on a different thread
        # from the acquire, which an RLock wouldn't allow.
        self._lock = threading.Lock()

    @contextmanager
    def hold(self) -> Iterator[None]:
        if not self._lock.acquire(blocking=False):
            raise Busy
        try:
            yield
        finally:
            self._lock.release()


class Deadline:
    def __init__(self, seconds: float, clock=time.monotonic):
        self._clock = clock
        self._end = clock() + seconds

    def remaining(self) -> float:
        return max(0.0, self._end - self._clock())

    def check(self, stage: str) -> None:
        if self.remaining() <= 0:
            raise DeadlineExceeded(stage)


def deadline_for(
    settings: Settings, duration_ms: int | None, client_deadline_ms: int | None
) -> Deadline:
    media_s = (duration_ms or 0) / 1000
    seconds = min(
        settings.deadline_cap_s,
        settings.deadline_base_s + settings.deadline_per_media_s * media_s,
    )
    if client_deadline_ms is not None:
        seconds = min(seconds, client_deadline_ms / 1000)
    return Deadline(seconds)


class BodyLimit:
    """ASGI middleware: a request body over `max_bytes` gets 413 before
    anything parses it.

    FastAPI reads and parses the JSON body before it runs the bearer check,
    so without a cap anyone who can reach the port could make the service
    hold an arbitrarily large document in memory. The body is read here (the
    app would buffer it anyway) and handed on whole.
    """

    def __init__(self, app: ASGIApp, max_bytes: int):
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        too_large = JSONResponse({"error": "request_too_large"}, status_code=413)
        length = dict(scope["headers"]).get(b"content-length")
        if length is not None and (not length.isdigit() or int(length) > self.max_bytes):
            await too_large(scope, receive, send)
            return

        body = bytearray()
        while True:
            message = await receive()
            if message["type"] != "http.request":  # the client went away
                return
            body += message.get("body", b"")
            if len(body) > self.max_bytes:
                await too_large(scope, receive, send)
                return
            if not message.get("more_body", False):
                break

        sent = False

        async def replay() -> Message:
            nonlocal sent
            if sent:
                return await receive()
            sent = True
            return {"type": "http.request", "body": bytes(body), "more_body": False}

        await self.app(scope, replay, send)
