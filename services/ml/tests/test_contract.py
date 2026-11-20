import json

import pytest
from conftest import AUTH

from tspec_ml import schemas
from tspec_ml.main import ROOT

FIXTURES = {
    "extract_video.request.json": schemas.ExtractVideoRequest,
    "extract_video.response.json": schemas.ExtractVideoResponse,
    "score.request.json": schemas.ScoreRequest,
    "score.response.json": schemas.ScoreResponse,
    "error.busy.json": schemas.Error,
    "error.media_url_not_allowed.json": schemas.Error,
    "error.invalid_request.json": schemas.Error,
    "error.request_too_large.json": schemas.Error,
}


def test_every_fixture_is_listed():
    on_disk = {p.name for p in (ROOT / "contract").glob("*.json")}
    assert on_disk == set(FIXTURES)


@pytest.mark.parametrize(("name", "model"), FIXTURES.items())
def test_fixtures_match_the_schemas(name, model):
    data = json.loads((ROOT / "contract" / name).read_text())
    model.model_validate(data)


def test_the_score_fixture_request_is_accepted(client):
    body = json.loads((ROOT / "contract" / "score.request.json").read_text())
    body["frames"]["embeddings"] = [[0.5] * 64, [0.1] * 64]
    r = client.post("/v1/score", json=body, headers=AUTH)
    assert r.status_code == 200
    schemas.ScoreResponse.model_validate(r.json())
