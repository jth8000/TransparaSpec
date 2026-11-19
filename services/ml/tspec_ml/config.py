"""Settings, read from `TSPEC_ML_*` environment variables."""

from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="TSPEC_ML_", frozen=True)

    # Shared with Phoenix: every /v1 request carries it as a bearer token.
    secret: SecretStr = Field(min_length=32)

    # Hosts media may be fetched from, comma-separated, as `host` (the
    # scheme's default port) or `host:port`. Empty means nothing can be
    # fetched. Production lists the video provider's delivery hosts only;
    # dev adds `localhost:4000` for LocalProvider.
    allowed_media_hosts: str = ""
    # Plain http is for dev (LocalProvider). Production is https only.
    allow_http: bool = False

    backend: Literal["fake"] = "fake"

    # Limits on what one request may fetch and decode. Videos are at most
    # 180 s (TSpec.Video.max_duration_seconds/0); the rest is slack.
    max_duration_s: float = 200.0
    max_playlist_bytes: int = 1_000_000
    max_media_bytes: int = 300_000_000
    max_segments: int = 600
    max_redirects: int = 3

    frames: int = 8
    frame_max_side: int = 512

    # Each request's deadline: base + per second of media, capped, or the
    # client's own `deadline_ms` if that's sooner. Phoenix's HTTP timeout is
    # longer than the deadline it sends, so the service gives up first.
    deadline_base_s: float = 30.0
    deadline_per_media_s: float = 1.0
    deadline_cap_s: float = 300.0

    # Address-space limit for ffmpeg and ffprobe (`prlimit --as`). Generous:
    # ffmpeg reserves far more virtual memory than it touches.
    ffmpeg_address_space_bytes: int = 4 * 1024**3

    # Seconds a refused (busy) request is told to wait.
    busy_retry_after_s: int = 5

    def media_hosts(self) -> frozenset[tuple[str, int | None]]:
        """The allowlist as (host, port) pairs; port None means the default."""
        hosts = set()
        for entry in self.allowed_media_hosts.split(","):
            entry = entry.strip().lower()
            if not entry:
                continue
            host, sep, port = entry.rpartition(":")
            hosts.add((host, int(port)) if sep and port.isdigit() else (entry, None))
        return frozenset(hosts)
