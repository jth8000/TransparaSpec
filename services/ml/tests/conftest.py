"""Fixtures: settings, HLS media made with ffmpeg, and a fake media host.

Media is generated once per test session (a few seconds of `testsrc` and a
sine tone), in four layouts:

* `muxed/`: one media playlist, audio and video together (LocalProvider);
* `split/`: a master playlist whose video variants name a separate audio
  playlist (`#EXT-X-MEDIA:TYPE=AUDIO`), as providers with several audio
  tracks serve it;
* `split/packed.m3u8`: the same video, with "packed audio": raw AAC
  segments, each behind an ID3 tag;
* `fmp4/`: fragmented MP4 segments after an init segment (`#EXT-X-MAP`);
* `silent/`: video with no audio stream at all.

`MediaHost` serves them over an `httpx.MockTransport` as
`https://media.test/...`, and can add redirects and other routes.
"""

import shutil
import subprocess
from collections.abc import Callable
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from tspec_ml.config import Settings
from tspec_ml.main import create_app

SECRET = "test-secret-0123456789abcdef-0123456789"
AUTH = {"Authorization": f"Bearer {SECRET}"}
FFMPEG = shutil.which("ffmpeg")


def make_settings(**overrides) -> Settings:
    return Settings(**{"secret": SECRET, "allowed_media_hosts": "media.test", **overrides})


@pytest.fixture
def settings() -> Settings:
    return make_settings()


def _ffmpeg(*args: str) -> None:
    subprocess.run([FFMPEG, "-y", "-v", "error", *args], check=True)


def _hls(out: Path, *inputs_and_codecs: str, segment_type: str = "mpegts") -> None:
    out.mkdir(parents=True)
    ext = "m4s" if segment_type == "fmp4" else "ts"
    _ffmpeg(
        *inputs_and_codecs,
        "-f",
        "hls",
        "-hls_time",
        "1",
        "-hls_playlist_type",
        "vod",
        "-hls_segment_type",
        segment_type,
        "-hls_segment_filename",
        str(out / f"seg_%02d.{ext}"),
        str(out / "index.m3u8"),
    )


def _id3_tag() -> bytes:
    """An ID3v2.4 tag with the PRIV frame HLS packed audio carries (its timestamp)."""

    def syncsafe(n: int) -> bytes:
        return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])

    body = b"com.apple.streaming.transportStreamTimestamp\x00" + bytes(8)
    frame = b"PRIV" + syncsafe(len(body)) + b"\x00\x00" + body
    return b"ID3\x04\x00\x00" + syncsafe(len(frame)) + frame


def _packed_aac(out: Path) -> None:
    """Packed audio: ADTS segments, each behind an ID3 tag. ffmpeg's HLS muxer
    writes MPEG-TS even for audio, so the segment muxer makes these."""
    out.mkdir(parents=True)
    _ffmpeg(
        *AUDIO_IN,
        *AAC,
        "-f",
        "segment",
        "-segment_time",
        "1",
        "-segment_format",
        "adts",
        "-segment_list",
        str(out / "index.m3u8"),
        "-segment_list_type",
        "m3u8",
        str(out / "seg_%02d.aac"),
    )
    for seg in out.glob("seg_*.aac"):
        seg.write_bytes(_id3_tag() + seg.read_bytes())


VIDEO_IN = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=3"]
AUDIO_IN = ["-f", "lavfi", "-i", "sine=frequency=440:duration=3"]
H264 = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "10"]
AAC = ["-c:a", "aac"]


@pytest.fixture(scope="session")
def media(tmp_path_factory) -> Path:
    root = tmp_path_factory.mktemp("media")
    _hls(root / "muxed", *VIDEO_IN, *AUDIO_IN, *H264, *AAC, "-shortest")
    _hls(root / "fmp4", *VIDEO_IN, *AUDIO_IN, *H264, *AAC, "-shortest", segment_type="fmp4")
    _hls(root / "silent", *VIDEO_IN, *H264, "-an")
    _hls(root / "split" / "video", *VIDEO_IN, *H264, "-an")
    _hls(root / "split" / "audio", *AUDIO_IN, *AAC, "-vn")
    (root / "split" / "master.m3u8").write_text(
        "#EXTM3U\n"
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/index.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2",AUDIO="aud"\n'
        "audio/index.m3u8\n"
        '#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x480,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"\n'
        "video/does-not-exist.m3u8\n"
        '#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x240,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"\n'
        "video/index.m3u8\n"
    )
    _packed_aac(root / "split" / "packed")
    (root / "split" / "packed.m3u8").write_text(
        "#EXTM3U\n"
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="packed/index.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x240,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"\n'
        "video/index.m3u8\n"
    )
    return root


class MediaHost:
    """Serves the media directory as https://media.test/, plus extra routes."""

    def __init__(self, root: Path):
        self.root = root
        self.routes: dict[str, Callable[[httpx.Request], httpx.Response]] = {}
        self.requests: list[str] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        self.requests.append(url)
        if url in self.routes:
            return self.routes[url](request)
        if request.url.host != "media.test":
            return httpx.Response(404)
        path = (self.root / request.url.path.lstrip("/")).resolve()
        if not path.is_relative_to(self.root.resolve()) or not path.is_file():
            return httpx.Response(404)
        return httpx.Response(200, content=path.read_bytes())

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)


@pytest.fixture
def host(media) -> MediaHost:
    return MediaHost(media)


@pytest.fixture
def make_client(host):
    def make(settings: Settings | None = None, backends=None) -> TestClient:
        app = create_app(settings or make_settings(), backends, host.transport())
        return TestClient(app)

    return make


@pytest.fixture
def client(make_client) -> TestClient:
    return make_client()


CONTENT_ID = "0194f0a2-7c3e-7b8a-9a1d-3f5e6c7d8e9f"


def extract_body(path: str, **extra) -> dict:
    return {
        "content_id": CONTENT_ID,
        "media_url": f"https://media.test/{path}",
        "duration_ms": 3000,
        **extra,
    }
