"""Reading an HLS presentation into local files, without letting ffmpeg fetch.

The service parses the playlists itself:

* A **master playlist** lists variants (`#EXT-X-STREAM-INF`). The lowest
  bandwidth variant that has video is enough for frames and speech. Audio
  may live in its own playlist (`#EXT-X-MEDIA:TYPE=AUDIO`, named by the
  variant's `AUDIO` group), as with providers that offer several audio
  tracks; then it's downloaded separately. Concatenating video segments
  alone would yield a silent file and an empty transcript without any error.
* A **media playlist** lists segments, optionally after an init segment
  (`#EXT-X-MAP`, fragmented MP4). LocalProvider serves one media playlist
  with audio and video together.

Segments are MPEG-TS, or fragmented MP4 after an init segment. An audio
playlist may also use "packed audio": raw AAC (ADTS frames), each segment
behind an ID3 tag carrying its timestamp.

Rejected: encrypted (`#EXT-X-KEY`) and byte-range playlists, live playlists
(no `#EXT-X-ENDLIST`), and anything past the segment, duration and size
limits. Every URL goes through the allowlisted `Fetcher`.
"""

import re
from dataclasses import dataclass
from pathlib import Path

import httpx

from ..config import Settings
from ..limits import Deadline
from .fetch import ByteBudget, Fetcher, MediaTooLarge

VIDEO_CODECS = ("avc1", "avc3", "hvc1", "hev1", "vp08", "vp09", "av01", "mp4v")

# The container a segment must be: MPEG-TS starts with the sync byte, an
# fMP4 init segment with an `ftyp` box, packed AAC with an ID3 tag or an
# ADTS frame. Checked before ffmpeg sees the file, and ffmpeg is told the
# format, so a "segment" that's really a playlist (or anything else) can't
# make it read other files.
TS_SYNC = 0x47
HEAD_BYTES = 4096


class UnsupportedPlaylist(Exception):
    """The playlist is malformed or uses a feature the service refuses."""


@dataclass
class Variant:
    uri: httpx.URL
    bandwidth: int
    has_video: bool
    audio_group: str | None


@dataclass
class AudioRendition:
    group: str
    uri: httpx.URL | None
    default: bool


@dataclass
class MediaPlaylist:
    init: httpx.URL | None
    segments: list[httpx.URL]
    duration_s: float


@dataclass
class Stream:
    path: Path
    # What ffmpeg is told to read: "mpegts", "mov" (fragmented MP4) or "aac"
    # (packed audio, audio playlists only).
    format: str


@dataclass
class Streams:
    video: Stream
    # A separate audio stream, or None when the audio (if any) is muxed with
    # the video. ffprobe has the final word on whether there's audio at all.
    audio: Stream | None
    duration_s: float


_ATTR = re.compile(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)')


def parse_attributes(text: str) -> dict[str, str]:
    return {k: v.strip('"') for k, v in _ATTR.findall(text)}


def _lines(text: str) -> list[str]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines or lines[0] != "#EXTM3U":
        raise UnsupportedPlaylist("not an HLS playlist")
    return lines


def is_master(text: str) -> bool:
    return "#EXT-X-STREAM-INF" in text


def parse_master(text: str, base: httpx.URL) -> tuple[list[Variant], list[AudioRendition]]:
    lines = _lines(text)
    variants, renditions = [], []
    for i, line in enumerate(lines):
        if line.startswith("#EXT-X-STREAM-INF:"):
            attrs = parse_attributes(line.split(":", 1)[1])
            if i + 1 >= len(lines) or lines[i + 1].startswith("#"):
                raise UnsupportedPlaylist("variant without a URI")
            codecs = attrs.get("CODECS", "").lower()
            has_video = "RESOLUTION" in attrs or any(c in codecs for c in VIDEO_CODECS)
            if not codecs and "RESOLUTION" not in attrs:
                has_video = True  # unknown: ffprobe decides
            variants.append(
                Variant(
                    uri=base.join(lines[i + 1]),
                    bandwidth=int(attrs.get("BANDWIDTH", "0") or 0),
                    has_video=has_video,
                    audio_group=attrs.get("AUDIO"),
                )
            )
        elif line.startswith("#EXT-X-MEDIA:"):
            attrs = parse_attributes(line.split(":", 1)[1])
            if attrs.get("TYPE") == "AUDIO":
                renditions.append(
                    AudioRendition(
                        group=attrs.get("GROUP-ID", ""),
                        uri=base.join(attrs["URI"]) if attrs.get("URI") else None,
                        default=attrs.get("DEFAULT") == "YES",
                    )
                )
    return variants, renditions


def choose(
    variants: list[Variant], renditions: list[AudioRendition]
) -> tuple[httpx.URL, httpx.URL | None]:
    """The lowest-bandwidth video variant, and its audio playlist if separate."""
    video = [v for v in variants if v.has_video]
    if not video:
        raise UnsupportedPlaylist("no variant with video")
    variant = min(video, key=lambda v: v.bandwidth)

    group = [r for r in renditions if r.group == variant.audio_group and r.uri is not None]
    if not group:
        return variant.uri, None
    rendition = next((r for r in group if r.default), group[0])
    return variant.uri, rendition.uri


def parse_media(text: str, base: httpx.URL, settings: Settings) -> MediaPlaylist:
    lines = _lines(text)
    init, segments, duration, pending, ended = None, [], 0.0, None, False

    for line in lines:
        if line.startswith("#EXT-X-KEY:"):
            if parse_attributes(line.split(":", 1)[1]).get("METHOD", "NONE") != "NONE":
                raise UnsupportedPlaylist("encrypted segments")
        elif line.startswith("#EXT-X-BYTERANGE"):
            raise UnsupportedPlaylist("byte-range segments")
        elif line.startswith("#EXT-X-MAP:"):
            attrs = parse_attributes(line.split(":", 1)[1])
            if "BYTERANGE" in attrs or "URI" not in attrs:
                raise UnsupportedPlaylist("unsupported init segment")
            if init is not None:
                raise UnsupportedPlaylist("more than one init segment")
            init = base.join(attrs["URI"])
        elif line.startswith("#EXTINF:"):
            try:
                pending = float(line.split(":", 1)[1].split(",", 1)[0])
            except ValueError as e:
                raise UnsupportedPlaylist("bad segment duration") from e
        elif line == "#EXT-X-ENDLIST":
            ended = True
        elif not line.startswith("#"):
            if pending is None:
                raise UnsupportedPlaylist("segment without a duration")
            segments.append(base.join(line))
            duration += pending
            pending = None

    if not ended:
        raise UnsupportedPlaylist("not a complete (VOD) playlist")
    if not segments:
        raise UnsupportedPlaylist("no segments")
    if len(segments) > settings.max_segments:
        raise MediaTooLarge(f"more than {settings.max_segments} segments")
    if duration > settings.max_duration_s:
        raise MediaTooLarge(f"longer than {settings.max_duration_s:.0f} s")
    return MediaPlaylist(init=init, segments=segments, duration_s=duration)


def fetch_streams(
    fetcher: Fetcher, url: str, workdir: Path, settings: Settings, deadline: Deadline
) -> Streams:
    """Downloads the presentation at `url` into `workdir`."""
    playlist_budget = ByteBudget(settings.max_playlist_bytes)
    media_budget = ByteBudget(settings.max_media_bytes)

    def playlist(u) -> tuple[httpx.URL, str]:
        final, body = fetcher.get(u, playlist_budget, deadline)
        try:
            return final, body.decode("utf-8")
        except UnicodeDecodeError as e:
            raise UnsupportedPlaylist("playlist is not UTF-8") from e

    base, text = playlist(url)
    audio_url = None
    if is_master(text):
        video_url, audio_url = choose(*parse_master(text, base))
        base, text = playlist(video_url)
    video = parse_media(text, base, settings)

    audio = None
    if audio_url is not None:
        audio_base, audio_text = playlist(audio_url)
        audio = parse_media(audio_text, audio_base, settings)

    return Streams(
        video=_download(fetcher, video, workdir / "video", media_budget, deadline),
        audio=_download(fetcher, audio, workdir / "audio", media_budget, deadline, audio=True)
        if audio
        else None,
        duration_s=video.duration_s,
    )


def _download(
    fetcher: Fetcher,
    playlist: MediaPlaylist,
    path: Path,
    budget: ByteBudget,
    deadline: Deadline,
    audio: bool = False,
) -> Stream:
    urls = ([playlist.init] if playlist.init else []) + playlist.segments
    fetcher.download(urls, path, budget, deadline)
    return Stream(path=path, format=_container(path, bool(playlist.init), audio))


def _container(path: Path, has_init: bool, audio: bool) -> str:
    """The format to tell ffmpeg, from the first bytes; anything else is refused."""
    with path.open("rb") as f:
        head = f.read(HEAD_BYTES)
    if has_init:
        fmt, ok = "mov", len(head) >= 8 and head[4:8] == b"ftyp"
    elif audio and _is_packed_aac(head):
        fmt, ok = "aac", True
    else:
        fmt, ok = "mpegts", len(head) >= 1 and head[0] == TS_SYNC
    if not ok:
        raise UnsupportedPlaylist(f"segments are not {fmt}")
    return fmt


def _is_packed_aac(head: bytes) -> bool:
    """An ADTS frame, after the ID3 tag if there is one (not MP3: its layer bits aren't 00)."""
    if head[:3] == b"ID3" and len(head) >= 10:
        size = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9]
        footer = 10 if head[5] & 0x10 else 0
        head = head[10 + size + footer :]
    return len(head) >= 2 and head[0] == 0xFF and head[1] & 0xF6 == 0xF0
