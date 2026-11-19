import time

from conftest import AUTH, CONTENT_ID, extract_body

from tspec_ml.backends import fake
from tspec_ml.backends.base import TranscriptResult


def post(client, body):
    return client.post("/v1/extract/video", json=body, headers=AUTH)


def test_a_muxed_playlist_gives_frames_and_a_transcript(client):
    r = post(client, extract_body("muxed/index.m3u8"))
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["content_id"] == CONTENT_ID
    assert data["has_audio"] is True
    assert data["transcript"] == {"text": "fake transcript of 3.0 s of audio", "language": "en"}
    frames = data["frames"]
    assert frames["model"] == "fake-image-v1"
    assert len(frames["embeddings"]) == len(frames["timestamps_ms"]) >= 6
    assert {len(e) for e in frames["embeddings"]} == {fake.DIM}
    assert set(data["timings_ms"]) == {"fetch", "probe", "frames", "transcribe"}


def test_audio_in_its_own_playlist_is_transcribed(client):
    # The video variant has no audio of its own: without following the audio
    # group, this would be a silent file and an empty transcript.
    data = post(client, extract_body("split/master.m3u8")).json()
    assert data["has_audio"] is True
    assert data["transcript"]["text"].startswith("fake transcript of 3.0 s")


def test_fragmented_mp4_works(client):
    r = post(client, extract_body("fmp4/index.m3u8"))
    assert r.status_code == 200, r.text
    assert r.json()["has_audio"] is True


def test_a_video_without_sound_says_so(client):
    data = post(client, extract_body("silent/index.m3u8")).json()
    assert data["has_audio"] is False
    assert data["transcript"] is None
    assert "transcribe" not in data["timings_ms"]


def test_media_off_the_allowlist_is_a_permanent_error(client, host):
    body = {**extract_body("x"), "media_url": "https://evil.test/a.m3u8"}
    r = post(client, body)
    assert r.status_code == 400
    assert r.json()["error"] == "media_url_not_allowed"
    assert host.requests == []


def test_upstream_failures_are_retryable(client):
    r = post(client, extract_body("missing/index.m3u8"))
    assert r.status_code == 502
    assert r.json()["error"] == "media_fetch_failed"


class SlowTranscriber(fake.FakeTranscriber):
    """Runs past the deadline, then returns as if nothing happened."""

    def transcribe(self, wav, deadline):
        time.sleep(deadline.remaining() + 0.05)
        return TranscriptResult(text="late", language="en")


def test_the_service_gives_up_at_the_clients_deadline(make_client):
    backends = fake.backends()
    backends.transcriber = SlowTranscriber()
    r = post(make_client(backends=backends), extract_body("muxed/index.m3u8", deadline_ms=3000))
    assert r.status_code == 504
    assert r.json()["error"] == "deadline_exceeded"
    assert "transcribe" in r.json()["detail"]


def test_requests_are_validated(client):
    r = post(client, {**extract_body("muxed/index.m3u8"), "duration_ms": 0, "extra": 1})
    assert r.status_code == 422
