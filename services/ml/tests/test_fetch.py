import httpx
import pytest
from conftest import make_settings

from tspec_ml.limits import Deadline
from tspec_ml.media.fetch import (
    ByteBudget,
    Fetcher,
    MediaFetchFailed,
    MediaTooLarge,
    MediaURLNotAllowed,
)


def fetcher(host=None, **settings):
    return Fetcher(make_settings(**settings), host.transport() if host else None)


@pytest.mark.parametrize(
    "url",
    [
        "http://media.test/a.m3u8",  # http, outside dev
        "https://evil.test/a.m3u8",
        "https://media.test.evil.test/a.m3u8",
        "https://media.test:8443/a.m3u8",  # a port the allowlist doesn't name
        "https://user:pw@media.test/a.m3u8",
        "file:///etc/passwd",
        "ftp://media.test/a",
        "not a url",
    ],
)
def test_check_refuses_urls_off_the_allowlist(url):
    with pytest.raises(MediaURLNotAllowed):
        fetcher().check(url)


def test_check_accepts_allowlisted_hosts_and_ports():
    f = fetcher(allowed_media_hosts="media.test, localhost:4000", allow_http=True)
    assert f.check("https://media.test/a.m3u8").host == "media.test"
    assert f.check("https://media.test:443/a.m3u8")
    assert f.check("http://localhost:4000/dev_media/x/index.m3u8")
    with pytest.raises(MediaURLNotAllowed):
        f.check("http://localhost:5432/")


def test_redirects_are_followed_only_onto_the_allowlist(host):
    host.routes["https://media.test/hop"] = lambda r: httpx.Response(
        302, headers={"location": "/muxed/index.m3u8"}
    )
    final, body = fetcher(host).get("https://media.test/hop", ByteBudget(10**6), Deadline(5))
    assert str(final) == "https://media.test/muxed/index.m3u8"
    assert body.startswith(b"#EXTM3U")

    host.routes["https://media.test/away"] = lambda r: httpx.Response(
        302, headers={"location": "https://evil.test/x"}
    )
    with pytest.raises(MediaURLNotAllowed):
        fetcher(host).get("https://media.test/away", ByteBudget(10**6), Deadline(5))
    assert "https://evil.test/x" not in host.requests


def test_redirect_loops_stop(host):
    host.routes["https://media.test/loop"] = lambda r: httpx.Response(
        302, headers={"location": "/loop"}
    )
    with pytest.raises(MediaFetchFailed, match="too many redirects"):
        fetcher(host).get("https://media.test/loop", ByteBudget(10**6), Deadline(5))


def test_size_limits_apply_with_or_without_a_content_length(host):
    host.routes["https://media.test/big"] = lambda r: httpx.Response(200, content=b"x" * 2000)
    with pytest.raises(MediaTooLarge):
        fetcher(host).get("https://media.test/big", ByteBudget(1000), Deadline(5))

    def streamed(_request):
        return httpx.Response(200, content=iter([b"x" * 600, b"x" * 600]))

    host.routes["https://media.test/stream"] = streamed
    with pytest.raises(MediaTooLarge):
        fetcher(host).get("https://media.test/stream", ByteBudget(1000), Deadline(5))


def test_upstream_errors_are_fetch_failures(host):
    with pytest.raises(MediaFetchFailed, match="HTTP 404"):
        fetcher(host).get("https://media.test/missing", ByteBudget(10**6), Deadline(5))
