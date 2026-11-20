import json
import shutil

import pytest

from tspec_ml.main import ROOT
from tspec_ml.taxonomy import load


def test_the_committed_taxonomy_and_prompts_load():
    taxonomy = load(ROOT)
    assert len(taxonomy.topics) == 360
    by_slug = taxonomy.by_slug()
    assert by_slug["industries"].model is False
    assert by_slug["cooking"].prompts == ("Cooking",)
    assert len(taxonomy.labelable()) == 360 - 14


@pytest.fixture
def copy(tmp_path):
    for name in ("taxonomy.json", "prompts.json"):
        shutil.copy(ROOT / name, tmp_path / name)
    return tmp_path


def edit_prompts(root, change):
    path = root / "prompts.json"
    data = json.loads(path.read_text())
    change(data["topics"])
    path.write_text(json.dumps(data))


def test_a_prompt_for_an_unknown_topic_fails_at_startup(copy):
    edit_prompts(copy, lambda t: t.update({"cookin": {"synonyms": ["recipes"]}}))
    with pytest.raises(ValueError, match="unknown topics: cookin"):
        load(copy)


def test_a_misspelled_field_fails_at_startup(copy):
    edit_prompts(copy, lambda t: t.update({"cooking": {"synonym": ["recipes"]}}))
    with pytest.raises(ValueError, match="unknown fields"):
        load(copy)


def test_prompts_and_version_follow_the_file(copy):
    before = load(copy).version
    edit_prompts(copy, lambda t: t.update({"cooking": {"synonyms": ["recipes"]}}))
    after = load(copy)
    assert after.by_slug()["cooking"].prompts == ("Cooking", "recipes")
    assert after.version != before
