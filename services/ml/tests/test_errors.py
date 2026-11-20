"""The error contract: every error is `{"error": code, "detail"?: text}`, and
never repeats what the request carried (Phoenix may log error bodies)."""

import json

from conftest import AUTH, CONTENT_ID, make_settings
from fastapi.testclient import TestClient

from tspec_ml.backends import fake
from tspec_ml.main import ROOT, create_app

FAMILY = "\U0001f468‍\U0001f469‍\U0001f467‍\U0001f466"  # one grapheme, seven code points


def score(client, **body):
    return client.post("/v1/score", json={"content_id": CONTENT_ID, **body}, headers=AUTH)


def test_a_caption_phoenix_accepts_is_never_refused_for_its_length(client):
    # Phoenix counts graphemes: 420 of these are far under its 2,200, but
    # they're 2,940 code points. A code-point limit here refused them, and
    # a 422 is permanent.
    caption = f"Family dinner, cooking together {FAMILY * 420}"
    r = score(client, caption=caption)
    assert r.status_code == 200, r.text
    caption_scores = r.json()["raw_scores"]["caption"]
    assert max(caption_scores, key=caption_scores.get) == "cooking"


def test_long_texts_are_cut_before_embedding_not_refused(make_client):
    # The fake embedder is a bag of words, so what wins shows what was read.
    client = make_client(make_settings(max_text_chars=100))
    caption = "cooking " * 12 + "gardening " * 1000
    r = score(client, caption=caption)
    assert r.status_code == 200
    caption_scores = r.json()["raw_scores"]["caption"]
    assert max(caption_scores, key=caption_scores.get) == "cooking"


def test_an_invalid_request_names_the_fields_but_not_their_values(client):
    r = score(client, content_id="not-a-uuid", caption=["a private caption"], extra="x")
    assert r.status_code == 422
    assert r.json() == {
        "error": "invalid_request",
        "detail": "body.caption: string_type; body.content_id: uuid_parsing; "
        "body.extra: extra_forbidden",
    }
    assert "private" not in r.text and "not-a-uuid" not in r.text

    r = client.post("/v1/score", content=b'{"caption": "a private', headers=AUTH)
    assert r.status_code == 422
    assert r.json()["error"] == "invalid_request"
    assert "private" not in r.text


def test_a_body_over_the_cap_is_refused_before_it_is_parsed_or_authenticated(make_client):
    client = make_client(make_settings(max_request_bytes=1000))
    big = json.dumps({"content_id": CONTENT_ID, "caption": "x" * 2000})

    # No bearer token: the size check comes first, so nothing is parsed.
    r = client.post("/v1/score", content=big, headers={"content-type": "application/json"})
    assert (r.status_code, r.json()) == (413, {"error": "request_too_large"})

    # Without a Content-Length (chunked), it's counted as it arrives.
    def chunks():
        for i in range(0, len(big), 100):
            yield big[i : i + 100].encode()

    r = client.post("/v1/score", content=chunks(), headers=AUTH)
    assert (r.status_code, r.json()) == (413, {"error": "request_too_large"})

    # Under the cap, all is as usual.
    assert score(client, caption="Cooking").status_code == 200


def test_an_unexpected_error_says_internal_and_nothing_else(host):
    class Exploding(fake.FakeTextEmbedder):
        def embed_texts(self, texts):
            raise RuntimeError(f"failed on {texts[0]!r}")

    backends = fake.backends()
    backends.text = Exploding()
    app = create_app(make_settings(), backends, host.transport())
    client = TestClient(app, raise_server_exceptions=False)

    r = score(client, caption="a private caption")
    assert (r.status_code, r.json()) == (500, {"error": "internal"})


def test_the_error_fixtures_are_what_the_service_sends(make_client):
    client = make_client(make_settings(max_request_bytes=1000))
    fixture = json.loads((ROOT / "contract" / "error.request_too_large.json").read_text())
    r = client.post("/v1/score", content=b"x" * 2000, headers=AUTH)
    assert r.json() == fixture

    fixture = json.loads((ROOT / "contract" / "error.invalid_request.json").read_text())
    r = score(client, content_id="not-a-uuid")
    assert r.json() == fixture
