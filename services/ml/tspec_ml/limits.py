"""One request at a time, and a deadline per request.

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
