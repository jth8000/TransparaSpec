from conftest import AUTH, CONTENT_ID


def test_health_needs_no_secret(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_v1_requires_the_bearer_secret(client):
    body = {"content_id": CONTENT_ID, "caption": "hello"}
    assert client.post("/v1/score", json=body).status_code == 401
    wrong = client.post("/v1/score", json=body, headers={"Authorization": "Bearer nope"})
    assert wrong.status_code == 401
    assert wrong.json() == {"error": "unauthorized"}
    assert client.post("/v1/score", json=body, headers=AUTH).status_code == 200


def test_unauthenticated_requests_never_reach_the_media_host(client, host):
    body = {
        "content_id": CONTENT_ID,
        "media_url": "https://media.test/muxed/index.m3u8",
        "duration_ms": 3000,
    }
    assert client.post("/v1/extract/video", json=body).status_code == 401
    assert host.requests == []
