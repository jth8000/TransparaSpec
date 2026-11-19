"""One request at a time, tested on a real uvicorn server.

A request is held inside the transcriber (a fake that waits on an event),
so the lock is really taken while the second request arrives. `/health`
answering meanwhile shows the work isn't blocking the event loop.
"""

import threading

import httpx
import pytest
import uvicorn
from conftest import AUTH, CONTENT_ID, extract_body, make_settings

from tspec_ml.backends import fake
from tspec_ml.main import create_app


class GatedTranscriber(fake.FakeTranscriber):
    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()

    def transcribe(self, wav, deadline):
        self.entered.set()
        assert self.release.wait(10)
        return super().transcribe(wav, deadline)


@pytest.fixture
def server(host):
    transcriber = GatedTranscriber()
    backends = fake.backends()
    backends.transcriber = transcriber
    app = create_app(make_settings(), backends, host.transport())
    config = uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning", workers=1)
    srv = uvicorn.Server(config)
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()
    for _ in range(500):
        if srv.started:
            break
        threading.Event().wait(0.01)
    port = srv.servers[0].sockets[0].getsockname()[1]
    try:
        yield f"http://127.0.0.1:{port}", transcriber
    finally:
        transcriber.release.set()
        srv.should_exit = True
        thread.join(10)


def test_a_second_request_is_refused_while_one_runs(server):
    base, transcriber = server
    first: dict = {}

    def run_first():
        first["response"] = httpx.post(
            f"{base}/v1/extract/video",
            json=extract_body("muxed/index.m3u8"),
            headers=AUTH,
            timeout=20,
        )

    thread = threading.Thread(target=run_first)
    thread.start()
    assert transcriber.entered.wait(10)

    # A short client timeout: a service that queued the request instead of
    # refusing it would fail here rather than hang the suite.
    with httpx.Client(base_url=base, timeout=3) as client:
        busy = client.post(
            "/v1/score", json={"content_id": CONTENT_ID, "caption": "x"}, headers=AUTH
        )
        assert busy.status_code == 503
        assert busy.json() == {"error": "busy"}
        assert busy.headers["retry-after"] == "5"
        assert client.get("/health").status_code == 200

        transcriber.release.set()
        thread.join(10)
        assert first["response"].status_code == 200

        # Released: the next request runs.
        after = client.post(
            "/v1/score", json={"content_id": CONTENT_ID, "caption": "x"}, headers=AUTH
        )
        assert after.status_code == 200
