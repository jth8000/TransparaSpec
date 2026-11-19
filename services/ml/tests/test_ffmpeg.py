import pytest
from conftest import make_settings

from tspec_ml.limits import Deadline, DeadlineExceeded
from tspec_ml.media import ffmpeg
from tspec_ml.media.hls import Stream


def runner(**settings) -> ffmpeg.Runner:
    return ffmpeg.Runner(ffmpeg.Tools.find(), make_settings(**settings))


def concat(media, name, tmp_path) -> Stream:
    """The playlist's segments joined into one file, as fetch_streams writes them."""
    out = tmp_path / f"{name}.ts"
    with out.open("wb") as f:
        for seg in sorted((media / name).glob("seg_*.ts")):
            f.write(seg.read_bytes())
    return Stream(path=out, format="mpegts")


def test_every_run_goes_through_prlimit():
    cmd = runner().command("/usr/bin/ffmpeg", ["-version"], Deadline(9.5))
    assert cmd[0].endswith("prlimit")
    assert cmd[1:4] == ["--cpu=10", f"--as={4 * 1024**3}", "--"]
    assert cmd[4:] == ["/usr/bin/ffmpeg", "-version"]


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
    assert [ts for ts, _ in frames] == sorted(ts for ts, _ in frames)

    wav = ffmpeg.extract_audio(r, stream, settings, tmp_path / "a.wav", Deadline(10))
    assert wav.read_bytes()[:4] == b"RIFF"


def test_a_silent_video_has_no_audio_stream(media, tmp_path):
    probe = ffmpeg.probe(runner(), concat(media, "silent", tmp_path), Deadline(10))
    assert probe.has_video and not probe.has_audio
