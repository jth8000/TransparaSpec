import re

from conftest import AUTH, CONTENT_ID, extract_body

from tspec_ml.backends import fake


def score(client, **body):
    return client.post("/v1/score", json={"content_id": CONTENT_ID, **body}, headers=AUTH)


def test_a_caption_that_names_a_topic_scores_it_highest(client):
    data = score(client, caption="One-pot pasta #Cooking").json()
    caption = data["raw_scores"]["caption"]
    assert max(caption, key=caption.get) == "cooking"
    assert len(data["text_embeddings"]["caption"]) == fake.DIM


def test_only_the_modalities_given_are_scored(client):
    data = score(client, body="A long post about gardening", caption="  ").json()
    assert set(data["raw_scores"]) == {"body"}


def test_containers_are_never_scored(client):
    scores = score(client, caption="Industries").json()["raw_scores"]["caption"]
    assert "industries" not in scores
    assert "genres" not in scores
    assert "cooking" in scores


def test_stored_frames_are_scored_without_the_video(client, host):
    frames = client.post(
        "/v1/extract/video", json=extract_body("muxed/index.m3u8"), headers=AUTH
    ).json()["frames"]
    host.requests.clear()

    data = score(
        client, frames={"model": frames["model"], "embeddings": frames["embeddings"]}
    ).json()
    assert data["raw_scores"].keys() == {"frames_mean", "frames_max"}
    mean, top = data["raw_scores"]["frames_mean"], data["raw_scores"]["frames_max"]
    assert all(top[slug] >= mean[slug] for slug in mean)
    assert host.requests == []


def test_frames_from_another_image_model_need_a_re_extract(client):
    r = score(client, frames={"model": "siglip-old", "embeddings": [[0.1] * fake.DIM]})
    assert r.status_code == 409
    assert r.json()["error"] == "frame_model_mismatch"

    r = score(client, frames={"model": "fake-image-v1", "embeddings": [[0.1, 0.2]]})
    assert r.status_code == 409


def test_shadow_mode_emits_no_labels_but_says_which_versions_scored(client):
    data = score(client, caption="Cooking").json()
    assert data["labels"] == []
    assert data["policy_version"] == "v0"
    assert re.fullmatch(r"[0-9a-f]{12}", data["prompts_version"])
    assert data["models"] == {"image": "fake-image-v1", "text": "fake-text-v1"}
