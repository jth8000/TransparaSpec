import shutil
import subprocess
import time

import pytest
from conftest import FFMPEG, make_settings

from tspec_ml.limits import Deadline, DeadlineExceeded
from tspec_ml.media import ffmpeg
from tspec_ml.media.hls import Stream


def runner(cpus: int | None = None, **settings) -> ffmpeg.Runner:
    return ffmpeg.Runner(ffmpeg.Tools.find(), make_settings(**settings), cpus=cpus)


def concat(media, name, tmp_path) -> Stream:
    """The playlist's segments joined into one file, as fetch_streams writes them."""
    out = tmp_path / f"{name}.ts"
    with out.open("wb") as f:
        for seg in sorted((media / name).glob("seg_*.ts")):
            f.write(seg.read_bytes())
    return Stream(path=out, format="mpegts")


def test_every_run_goes_through_prlimit():
    # CPU seconds add up across threads: 9.5 s left on 4 CPUs allows 38 of
    # them (plus one for rounding), so the wall-clock timeout always fires
    # first and the CPU limit is only a backstop.
    deadline = Deadline(9.5, clock=lambda: 0.0)
    cmd = runner(cpus=4).command("/usr/bin/ffmpeg", ["-version"], deadline)
    assert cmd[0].endswith("prlimit")
    assert cmd[1:4] == ["--cpu=39", f"--as={4 * 1024**3}", "--"]
    assert cmd[4:] == ["/usr/bin/ffmpeg", "-version"]


def test_a_multithreaded_run_is_stopped_by_the_deadline_not_the_cpu_limit():
    # Eight encoder threads spend CPU seconds several times faster than wall
    # seconds. With a CPU limit of just the time left, the kernel killed
    # ffmpeg after a fraction of the deadline, and the kill was reported as
    # corrupt media: permanent, for a video that was fine.
    r = runner()
    args = [
        "-nostdin", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=60", "-t", "60",
        "-c:v", "libx264", "-preset", "medium", "-threads", "8", "-f", "null", "-",
    ]  # fmt: skip
    start = time.monotonic()
    with pytest.raises(DeadlineExceeded):
        r.run(r.tools.ffmpeg, args, Deadline(1.5), "frames")
    assert time.monotonic() - start >= 1.4


def test_a_tool_killed_by_a_signal_is_retryable_not_bad_media():
    # The OOM killer, an operator or the CPU backstop: nothing to do with the
    # media, so it mustn't become a permanent media_decode_failed.
    r = runner()
    with pytest.raises(ffmpeg.MediaToolKilled, match="killed by SIGKILL"):
        r.run(shutil.which("sh"), ["-c", "kill -KILL $$"], Deadline(10), "probe")


def test_the_address_space_limit_is_real():
    # 16 MB is far too little for ffmpeg to even start.
    tiny = runner(ffmpeg_address_space_bytes=16 * 1024**2)
    with pytest.raises(ffmpeg.MediaDecodeFailed):
        tiny.run(tiny.tools.ffmpeg, ["-version"], Deadline(10), "probe")


def test_a_run_past_the_deadline_is_killed(media, tmp_path):
    stream = concat(media, "muxed", tmp_path)
    r = runner()
    # -re reads at native speed: three seconds for this clip.
    args = ["-nostdin", "-re", "-f", "mpegts", "-i", str(stream.path), "-f", "null", "-"]
    with pytest.raises(DeadlineExceeded):
        r.run(r.tools.ffmpeg, args, Deadline(0.5), "frames")


def test_probe_frames_and_audio(media, tmp_path):
    r, settings = runner(), make_settings()
    stream = concat(media, "muxed", tmp_path)

    probe = ffmpeg.probe(r, stream, Deadline(10))
    assert probe.has_video and probe.has_audio
    assert probe.duration_s == pytest.approx(3.0, abs=0.3)

    frames = ffmpeg.extract_frames(r, stream, 3.0, settings, tmp_path / "f", Deadline(10))
    assert 6 <= len(frames) <= settings.frames
    assert all(png.startswith(b"\x89PNG") for _, png in frames)
    # frame_max_side is a maximum: a 320x240 video isn't scaled up.
    assert {_png_size(png) for _, png in frames} == {(320, 240)}
    assert [ts for ts, _ in frames] == sorted(ts for ts, _ in frames)

    wav = ffmpeg.extract_audio(r, stream, settings, tmp_path / "a.wav", Deadline(10))
    assert wav.read_bytes()[:4] == b"RIFF"


def test_a_silent_video_has_no_audio_stream(media, tmp_path):
    probe = ffmpeg.probe(runner(), concat(media, "silent", tmp_path), Deadline(10))
    assert probe.has_video and not probe.has_audio


def _brightness(*input_args: str) -> list[int]:
    """Each frame's mean brightness, 0-255, one value per frame.

    Measured in RGB, as the PNGs are stored: going on to gray stretches the
    range a second time, and the source and the PNGs would disagree.
    """
    out = subprocess.run(
        [FFMPEG, "-v", "error", *input_args, "-vf", "scale=1:1", "-f", "rawvideo",
         "-pix_fmt", "rgb24", "-"],
        capture_output=True, check=True,
    ).stdout  # fmt: skip
    return list(out[0::3])


def _png_size(png: bytes) -> tuple[int, int]:
    return int.from_bytes(png[16:20], "big"), int.from_bytes(png[20:24], "big")


def test_frames_come_from_the_middle_of_each_slice(tmp_path):
    # A 4 s clip whose brightness rises steadily, so a frame's brightness says
    # when it was taken. Eight frames slice it every 0.5 s: they should come
    # from 0.25 s, 0.75 s, ... 3.75 s, never the first frame (often black or a
    # title card) and not the slice ends either.
    clip = tmp_path / "ramp.ts"
    subprocess.run(
        [FFMPEG, "-v", "error", "-f", "lavfi", "-i",
         "nullsrc=s=32x32:r=25:d=4,geq=lum='16+50*T':cb=128:cr=128",
         "-c:v", "libx264", "-qp", "0", "-f", "mpegts", str(clip)],
        check=True,
    )  # fmt: skip
    source = _brightness("-f", "mpegts", "-i", str(clip))  # frame k is at k/25 s
    assert len(source) == 100

    r, settings = runner(), make_settings()
    stream = Stream(path=clip, format="mpegts")
    frames = ffmpeg.extract_frames(r, stream, 4.0, settings, tmp_path / "f", Deadline(30))

    assert [ts for ts, _ in frames] == [250, 750, 1250, 1750, 2250, 2750, 3250, 3750]
    for i, (_, png) in enumerate(frames):
        (tmp_path / "one.png").write_bytes(png)
        [value] = _brightness("-i", str(tmp_path / "one.png"))
        taken_at = min(range(len(source)), key=lambda k: abs(source[k] - value)) / 25
        assert taken_at == pytest.approx((i + 0.5) * 0.5, abs=0.1), (i, taken_at)
