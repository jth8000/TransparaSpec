"""Fetching media from allowlisted hosts only.

Every URL the service fetches goes through `Fetcher.get`, which checks it
against the allowlist first: the playlist Phoenix sent, the variant and
audio playlists it names, every segment, and every redirect hop. Redirects
are followed by hand, so a redirect can't lead off the allowlist. ffmpeg
never fetches anything: it reads only the local files written here.
"""

from dataclasses import dataclass
from pathlib import Path

import httpx

from ..config import Settings
from ..limits import Deadline, DeadlineExceeded

DEFAULT_PORTS = {"http": 80, "https": 443}


class MediaURLNotAllowed(Exception):
    """The URL's scheme or host isn't on the allowlist (a permanent error)."""


class MediaFetchFailed(Exception):
    """The media host answered badly or not at all (may be transient)."""


class MediaTooLarge(Exception):
    """The media is past a size or count limit."""


@dataclass
class ByteBudget:
    """Bytes one request may still download, across all its fetches."""

    remaining: int

    def spend(self, n: int) -> None:
        self.remaining -= n
        if self.remaining < 0:
            raise MediaTooLarge("media exceeds the download limit")


class Fetcher:
    def __init__(self, settings: Settings, transport: httpx.BaseTransport | None = None):
        self._hosts = settings.media_hosts()
        self._schemes = {"https", "http"} if settings.allow_http else {"https"}
        self._max_redirects = settings.max_redirects
        self._transport = transport

    def check(self, url: str | httpx.URL) -> httpx.URL:
        """The parsed URL, if it may be fetched; raises MediaURLNotAllowed if not."""
        try:
            url = httpx.URL(url)
        except (httpx.InvalidURL, TypeError) as e:
            raise MediaURLNotAllowed("invalid URL") from e

        if url.scheme not in self._schemes:
            raise MediaURLNotAllowed(f"scheme {url.scheme!r} not allowed")
        if url.userinfo:
            raise MediaURLNotAllowed("URLs with credentials not allowed")

        host = url.host.lower()
        port = url.port if url.port is not None else DEFAULT_PORTS[url.scheme]
        default = port == DEFAULT_PORTS[url.scheme]
        if (host, port) in self._hosts or (default and (host, None) in self._hosts):
            return url
        raise MediaURLNotAllowed(f"host {host}:{port} not allowed")

    def get(
        self, url: str | httpx.URL, budget: ByteBudget, deadline: Deadline, sink=None
    ) -> tuple[httpx.URL, bytes]:
        """GETs `url` within the budget and deadline.

        Returns the final URL (after redirects, for resolving relative
        references) and the body, or writes the body to `sink` (a binary file)
        and returns b"".
        """
        url = self.check(url)
        with httpx.Client(transport=self._transport, follow_redirects=False) as client:
            for _ in range(self._max_redirects + 1):
                deadline.check("fetch")
                timeout = httpx.Timeout(min(deadline.remaining(), 30.0))
                try:
                    with client.stream("GET", url, timeout=timeout) as response:
                        if response.is_redirect:
                            location = response.headers.get("location")
                            if not location:
                                raise MediaFetchFailed("redirect without a location")
                            url = self.check(url.join(location))
                            continue
                        if response.status_code != 200:
                            raise MediaFetchFailed(f"HTTP {response.status_code}")
                        return url, self._read(response, budget, deadline, sink)
                except httpx.TimeoutException as e:
                    if deadline.remaining() <= 0:
                        raise DeadlineExceeded("fetch") from e
                    raise MediaFetchFailed("timed out") from e
                except httpx.TransportError as e:
                    raise MediaFetchFailed(type(e).__name__) from e
            raise MediaFetchFailed("too many redirects")

    @staticmethod
    def _read(response: httpx.Response, budget: ByteBudget, deadline: Deadline, sink) -> bytes:
        length = response.headers.get("content-length")
        if length and length.isdigit() and int(length) > budget.remaining:
            raise MediaTooLarge("media exceeds the download limit")

        chunks = []
        for chunk in response.iter_bytes():
            budget.spend(len(chunk))
            deadline.check("fetch")
            if sink is None:
                chunks.append(chunk)
            else:
                sink.write(chunk)
        return b"".join(chunks)

    def download(self, urls: list[httpx.URL], dest: Path, budget: ByteBudget, deadline: Deadline):
        """Fetches `urls` in order and concatenates them into `dest`."""
        with dest.open("wb") as sink:
            for url in urls:
                self.get(url, budget, deadline, sink=sink)
