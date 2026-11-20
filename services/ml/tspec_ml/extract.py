"""`/v1/extract/video`: media URL → transcript and frame embeddings.

Stages, each checked against the request's deadline:

1. fetch: playlists and segments into a temporary directory (`hls`);
2. probe: which streams the files really have;
3. frames: one still from the middle of each equal slice of the video,
   embedded by the image model;
4. audio and transcript, if there is an audio stream.

The temporary directory is removed when the request ends, whatever happens:
the service keeps no media and no transcripts.
"""

import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from .backends.base import Backends
from .config import Settings
from .limits import Deadline
from .media import ffmpeg, hls
from .media.fetch import Fetcher
from .schemas import ExtractVideoRequest, ExtractVideoResponse, Frames, Transcript

EXTRACTOR_VERSION = "extract-v1"


@contextmanager
def _timer(timings: dict[str, int], stage: str):
    start = time.monotonic()
    try:
        yield
    finally:
        timings[stage] = round((time.monotonic() - start) * 1000)


def extract_video(
    req: ExtractVideoRequest,
    *,
    settings: Settings,
    fetcher: Fetcher,
    runner: ffmpeg.Runner,
    backends: Backends,
    deadline: Deadline,
) -> ExtractVideoResponse:
    timings: dict[str, int] = {}
    with tempfile.TemporaryDirectory(prefix="tspec-ml-") as tmp:
        workdir = Path(tmp)

        with _timer(timings, "fetch"):
            streams = hls.fetch_streams(fetcher, req.media_url, workdir, settings, deadline)

        with _timer(timings, "probe"):
            video = ffmpeg.probe(runner, streams.video, deadline)
            audio_stream = streams.audio or streams.video
            audio = ffmpeg.probe(runner, streams.audio, deadline) if streams.audio else video
        if not video.has_video:
            raise ffmpeg.NoVideoStream("no video stream")
        duration_s = video.duration_s or streams.duration_s

        with _timer(timings, "frames"):
            stills = ffmpeg.extract_frames(
                runner, streams.video, duration_s, settings, workdir / "frames", deadline
            )
            deadline.check("frames")
            embeddings = backends.image.embed_images([png for _, png in stills])

        transcript = None
        if audio.has_audio:
            with _timer(timings, "transcribe"):
                wav = ffmpeg.extract_audio(
                    runner, audio_stream, settings, workdir / "audio.wav", deadline
                )
                result = backends.transcriber.transcribe(wav, deadline)
                deadline.check("transcribe")
                transcript = Transcript(text=result.text, language=result.language)

    return ExtractVideoResponse(
        content_id=req.content_id,
        extractor_version=EXTRACTOR_VERSION,
        has_audio=audio.has_audio,
        transcript=transcript,
        frames=Frames(
            model=backends.image.model_id,
            timestamps_ms=[ts for ts, _ in stills],
            embeddings=[[round(float(x), 6) for x in row] for row in embeddings],
        ),
        timings_ms=timings,
    )
