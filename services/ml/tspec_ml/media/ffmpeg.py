"""ffmpeg and ffprobe on local files, under CPU, memory and time limits.

Every run goes through `prlimit` (util-linux), which sets the limits and
execs the tool. Not `preexec_fn`: Python warns that it can deadlock the
child in a threaded process, and this service has a thread pool (and
torch's threads, once real models load). The limits:

* `--cpu`: CPU seconds, from the request's remaining deadline;
* `--as`: address space, generous (ffmpeg reserves much more than it uses);
* a wall-clock timeout, after which the child is killed.

Inputs are files `hls.fetch_streams` wrote, read with the protocol allowlist
`file` and an explicit format, so ffmpeg can neither fetch nor treat a
"segment" as a playlist.
"""

import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from ..config import Settings
from ..limits import Deadline, DeadlineExceeded
from .hls import Stream


class MediaDecodeFailed(Exception):
    """ffmpeg couldn't read the media (corrupt or unsupported)."""


class NoVideoStream(Exception):
    """The media has no video stream."""


@dataclass(frozen=True)
class Tools:
    prlimit: str
    ffmpeg: str
    ffprobe: str

    @classmethod
    def find(cls) -> "Tools":
        """Absolute paths, so nothing is looked up relative to the working directory."""
        paths = {name: shutil.which(name) for name in ("prlimit", "ffmpeg", "ffprobe")}
        missing = [name for name, path in paths.items() if path is None]
        if missing:
            raise RuntimeError(f"not on PATH: {', '.join(missing)}")
        return cls(**paths)


@dataclass
class Probe:
    has_video: bool
    has_audio: bool
    duration_s: float | None


class Runner:
    def __init__(self, tools: Tools, settings: Settings):
        self.tools = tools
        self._address_space = settings.ffmpeg_address_space_bytes

    def command(self, tool: str, args: list[str], deadline: Deadline) -> list[str]:
        cpu_seconds = max(1, int(deadline.remaining()) + 1)
        return [
            self.tools.prlimit,
            f"--cpu={cpu_seconds}",
            f"--as={self._address_space}",
            "--",
            tool,
            *args,
        ]

    def run(self, tool: str, args: list[str], deadline: Deadline, stage: str) -> bytes:
        deadline.check(stage)
        cmd = self.command(tool, args, deadline)
        try:
            # The arguments are fixed flags and paths this service created.
            proc = subprocess.run(  # noqa: S603
                cmd, capture_output=True, timeout=deadline.remaining(), check=False
            )
        except subprocess.TimeoutExpired as e:
            raise DeadlineExceeded(stage) from e
        if proc.returncode != 0:
            tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-3:]
            raise MediaDecodeFailed(f"{Path(tool).name} failed: {' | '.join(tail)}")
        return proc.stdout


def _input(stream: Stream) -> list[str]:
    return ["-protocol_whitelist", "file", "-f", stream.format, "-i", str(stream.path)]


def probe(runner: Runner, stream: Stream, deadline: Deadline) -> Probe:
    out = runner.run(
        runner.tools.ffprobe,
        [
            "-v",
            "error",
            *_input(stream),
            "-show_entries",
            "stream=codec_type:format=duration",
            "-of",
            "json",
        ],
        deadline,
        "probe",
    )
    data = json.loads(out or b"{}")
    types = {s.get("codec_type") for s in data.get("streams", [])}
    duration = data.get("format", {}).get("duration")
    return Probe(
        has_video="video" in types,
        has_audio="audio" in types,
        duration_s=float(duration) if duration not in (None, "N/A") else None,
    )


def _ffmpeg_args(stream: Stream, *output: str) -> list[str]:
    return ["-nostdin", "-hide_banner", "-loglevel", "error", *_input(stream), *output]


def extract_frames(
    runner: Runner,
    stream: Stream,
    duration_s: float,
    settings: Settings,
    outdir: Path,
    deadline: Deadline,
) -> list[tuple[int, bytes]]:
    """Up to `settings.frames` evenly spaced frames as PNGs: [(timestamp_ms, png)]."""
    n, side = settings.frames, settings.frame_max_side
    interval = max(duration_s, 0.04) / n
    outdir.mkdir()
    runner.run(
        runner.tools.ffmpeg,
        _ffmpeg_args(
            stream,
            "-vf",
            f"fps=1/{interval:.6f},scale={side}:{side}:force_original_aspect_ratio=decrease",
            "-frames:v",
            str(n),
            "-f",
            "image2",
            str(outdir / "frame_%02d.png"),
        ),
        deadline,
        "frames",
    )
    paths = sorted(outdir.glob("frame_*.png"))
    if not paths:
        raise MediaDecodeFailed("no frames decoded")
    return [(round(i * interval * 1000), p.read_bytes()) for i, p in enumerate(paths)]


def extract_audio(
    runner: Runner, stream: Stream, settings: Settings, out: Path, deadline: Deadline
) -> Path:
    """The first audio stream as 16 kHz mono PCM WAV (what speech models expect)."""
    runner.run(
        runner.tools.ffmpeg,
        _ffmpeg_args(
            stream,
            "-vn",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-t",
            str(settings.max_duration_s),
            "-c:a",
            "pcm_s16le",
            "-f",
            "wav",
            str(out),
        ),
        deadline,
        "audio",
    )
    return out
