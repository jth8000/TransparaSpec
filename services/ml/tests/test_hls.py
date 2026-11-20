import httpx
import pytest
from conftest import make_settings

from tspec_ml.limits import Deadline
from tspec_ml.media import hls
from tspec_ml.media.fetch import Fetcher, MediaTooLarge, MediaURLNotAllowed

BASE = httpx.URL("https://media.test/v/master.m3u8")


def media_playlist(*lines: str, end: bool = True) -> str:
    body = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", *lines]
    return "\n".join([*body, "#EXT-X-ENDLIST"] if end else body)


def test_attributes_keep_quoted_commas():
    attrs = hls.parse_attributes('BANDWIDTH=300000,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"')
    assert attrs == {"BANDWIDTH": "300000", "CODECS": "avc1.64001f,mp4a.40.2", "AUDIO": "aud"}


def test_the_lowest_bandwidth_variant_with_video_is_chosen_with_its_audio_playlist():
    text = (
        "#EXTM3U\n"
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="French",URI="fr.m3u8"\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="en.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2",AUDIO="aud"\n'
        "audio-only.m3u8\n"
        '#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=1280x720,AUDIO="aud"\n'
        "720.m3u8\n"
        '#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=426x240,AUDIO="aud"\n'
        "240.m3u8\n"
    )
    video, audio = hls.choose(*hls.parse_master(text, BASE))
    assert str(video) == "https://media.test/v/240.m3u8"
    assert str(audio) == "https://media.test/v/en.m3u8"


def test_audio_without_its_own_playlist_is_muxed_with_the_video():
    text = (
        "#EXTM3U\n"
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Main",DEFAULT=YES\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=426x240,AUDIO="aud"\n'
        "240.m3u8\n"
    )
    _video, audio = hls.choose(*hls.parse_master(text, BASE))
    assert audio is None


def test_a_master_without_video_is_refused():
    text = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"\na.m3u8\n'
    with pytest.raises(hls.UnsupportedPlaylist, match="no variant with video"):
        hls.choose(*hls.parse_master(text, BASE))


@pytest.mark.parametrize(
    ("lines", "end", "error"),
    [
        (['#EXT-X-KEY:METHOD=AES-128,URI="k"', "#EXTINF:1,", "a.ts"], True, "encrypted"),
        (["#EXT-X-BYTERANGE:100@0", "#EXTINF:1,", "a.ts"], True, "byte-range"),
        (['#EXT-X-MAP:URI="i.mp4",BYTERANGE="10@0"', "#EXTINF:1,", "a.m4s"], True, "init"),
        (["#EXTINF:1,", "a.ts"], False, "VOD"),
        (["a.ts"], True, "without a duration"),
        ([], True, "no segments"),
    ],
)
def test_unsupported_media_playlists_are_refused(lines, end, error):
    with pytest.raises(hls.UnsupportedPlaylist, match=error):
        hls.parse_media(media_playlist(*lines, end=end), BASE, make_settings())


def test_unencrypted_key_tags_are_fine():
    text = media_playlist("#EXT-X-KEY:METHOD=NONE", "#EXTINF:1.5,", "a.ts")
    playlist = hls.parse_media(text, BASE, make_settings())
    assert [str(u) for u in playlist.segments] == ["https://media.test/v/a.ts"]
    assert playlist.duration_s == 1.5


def test_segment_count_and_duration_are_limited():
    many = [line for i in range(5) for line in ("#EXTINF:1,", f"s{i}.ts")]
    with pytest.raises(MediaTooLarge, match="segments"):
        hls.parse_media(media_playlist(*many), BASE, make_settings(max_segments=4))
    with pytest.raises(MediaTooLarge, match="longer"):
        hls.parse_media(media_playlist(*many), BASE, make_settings(max_duration_s=4))


def _fetch(host, path, tmp_path):
    settings = make_settings()
    return hls.fetch_streams(
        Fetcher(settings, host.transport()),
        f"https://media.test/{path}",
        tmp_path,
        settings,
        Deadline(10),
    )


def test_a_separate_audio_playlist_is_downloaded_too(host, tmp_path):
    streams = _fetch(host, "split/master.m3u8", tmp_path)
    assert streams.audio is not None
    assert streams.video.format == streams.audio.format == "mpegts"
    assert "https://media.test/split/video/does-not-exist.m3u8" not in host.requests


def test_packed_audio_is_read_as_aac(host, tmp_path):
    streams = _fetch(host, "split/packed.m3u8", tmp_path)
    assert (streams.video.format, streams.audio.format) == ("mpegts", "aac")


def test_packed_audio_is_refused_for_the_video(host, tmp_path):
    # Only an audio playlist may be packed audio; a video playlist of it has
    # no video to find, so it's refused before ffmpeg runs.
    host.routes["https://media.test/z/index.m3u8"] = lambda r: httpx.Response(
        200, text=media_playlist("#EXTINF:1,", "../split/packed/seg_00.aac")
    )
    with pytest.raises(hls.UnsupportedPlaylist, match="not mpegts"):
        _fetch(host, "z/index.m3u8", tmp_path)


def test_fmp4_segments_follow_their_init_segment(host, tmp_path):
    streams = _fetch(host, "fmp4/index.m3u8", tmp_path)
    assert streams.video.format == "mov"
    assert streams.video.path.read_bytes()[4:8] == b"ftyp"


def test_every_segment_must_be_on_the_allowlist(host, tmp_path):
    host.routes["https://media.test/x/index.m3u8"] = lambda r: httpx.Response(
        200, text=media_playlist("#EXTINF:1,", "https://evil.test/seg.ts")
    )
    with pytest.raises(MediaURLNotAllowed):
        _fetch(host, "x/index.m3u8", tmp_path)
    assert not any("evil.test" in url for url in host.requests)


def test_a_segment_that_isnt_media_is_refused_before_ffmpeg_sees_it(host, tmp_path):
    # A "segment" that is really a playlist pointing at local files: ffmpeg's
    # HLS demuxer would read them. It never gets there.
    sneaky = media_playlist("#EXTINF:1,", "file:///etc/passwd")
    host.routes["https://media.test/y/index.m3u8"] = lambda r: httpx.Response(
        200, text=media_playlist("#EXTINF:1,", "seg.ts")
    )
    host.routes["https://media.test/y/seg.ts"] = lambda r: httpx.Response(200, text=sneaky)
    with pytest.raises(hls.UnsupportedPlaylist, match="not mpegts"):
        _fetch(host, "y/index.m3u8", tmp_path)
