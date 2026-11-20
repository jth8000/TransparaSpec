"""ffmpeg and ffprobe on local files, under CPU, memory and time limits.

Every run goes through `prlimit` (util-linux), which sets the limits and
execs the tool. Not `preexec_fn`: Python warns that it can deadlock the
child in a threaded process, and this service has a thread pool (and
torch's threads, once real models load). The limits:

* a wall-clock timeout at the request's deadline, after which the child is
  killed: this is what enforces the deadline (`DeadlineExceeded`, retryable);
* `--cpu`: CPU seconds, a backstop that bounds an ffmpeg left running if the
  service itself dies. CPU time adds up across all of ffmpeg's threads, so
  the limit is the remaining deadline times the CPUs the process may use: no
  process can spend that before the wall-clock timeout fires. (A limit of
  just the remaining seconds killed multi-threaded decodes early, and the
  kill looked like corrupt media.)
* `--as`: address space, generous (ffmpeg reserves much more than it uses).

A tool killed by a signal (the CPU backstop, the OOM killer, an operator) is
`MediaToolKilled`, retryable; only a tool that exits with an error is
`MediaDecodeFailed`, permanent for that input.

Inputs are files `hls.fetch_streams` wrote, read with the protocol allowlist
`file` and an explicit format, so ffmpeg can neither fetch nor treat a
"segment" as a playlist.
"""

import json
import math
import os
import shutil
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path

from ..config import Settings
from ..limits import Deadline, DeadlineExceeded
from .hls import Stream


class MediaDecodeFailed(Exception):
    """ffmpeg couldn't read the media (corrupt or unsupported)."""


class MediaToolKilled(Exception):
    """ffmpeg or ffprobe was killed by a signal, which says nothing about the media."""


class NoVideoStream(Exception):
    """The media has no video stream."""


def usable_cpus() -> int:
    """The CPUs this process may run on (its affinity mask, not the machine's count)."""
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:  # not Linux
        return os.cpu_count() or 1


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
    def __init__(self, tools: Tools, settings: Settings, cpus: int | None = None):
        self.tools = tools
        self._address_space = settings.ffmpeg_address_space_bytes
        self._cpus = cpus or usable_cpus()

    def command(self, tool: str, args: list[str], deadline: Deadline) -> list[str]:
        cpu_seconds = math.ceil(deadline.remaining() * self._cpus) + 1
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
        name = Path(tool).name
        if proc.returncode < 0:
            raise MediaToolKilled(f"{name} killed by {_signal_name(-proc.returncode)}")
        if proc.returncode != 0:
            tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-3:]
            raise MediaDecodeFailed(f"{name} exited {proc.returncode}: {' | '.join(tail)}")
        return proc.stdout


def _signal_name(number: int) -> str:
    try:
        return signal.Signals(number).name
    except ValueError:
        return f"signal {number}"


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
    """Up to `settings.frames` frames as PNGs, one from the middle of each of
    `frames` equal slices of the video: [(timestamp_ms, png)].

    The `fps` filter does the sampling. With its default rounding, output
    frame i covers input times [(i - 1/2)·interval, (i + 1/2)·interval) and
    is the last input frame in that range: the frame at the middle of slice
    i, or the one just before it. (The filter's own output timestamps,
    i·interval, number the slots; they aren't when the frames were taken.)
    So neither the first frame, often black or a title card, nor the end of
    the video is favoured. `test_frames_come_from_the_middle_of_each_slice`
    pins this down against ffmpeg upgrades.
    """
    n, side = settings.frames, settings.frame_max_side
    interval = max(duration_s, 0.04) / n
    outdir.mkdir()
    runner.run(
        runner.tools.ffmpeg,
        _ffmpeg_args(
            stream,
            "-vf",
            # At most `side` on the longer edge; never scaled up.
            f"fps=1/{interval:.6f},"
            f"scale='min({side},iw)':'min({side},ih)':force_original_aspect_ratio=decrease",
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
    return [(round((i + 0.5) * interval * 1000), p.read_bytes()) for i, p in enumerate(paths)]


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
