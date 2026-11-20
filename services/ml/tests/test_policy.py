import pytest

from tspec_ml import policy
from tspec_ml.main import POLICY, ROOT
from tspec_ml.taxonomy import load


@pytest.fixture(scope="module")
def taxonomy():
    return load(ROOT)


def enabled(*slugs, floor=0.35, max_labels=3):
    return policy.Policy("test", frozenset(slugs), floor, max_labels, calibration={"fitted": True})


def test_v0_is_shadow_mode(taxonomy):
    v0 = policy.load(POLICY, taxonomy)
    assert v0.enabled_topics == frozenset()
    assert policy.labels(v0, {"cooking": 0.99}, taxonomy) == []


def test_only_enabled_topics_above_the_floor_are_labeled(taxonomy):
    p = enabled("cooking", "travel")
    labels = policy.select(p, {"cooking": 0.9, "travel": 0.3, "music": 0.95}, taxonomy)
    assert [(lbl.slug, lbl.confidence) for lbl in labels] == [("cooking", 0.9)]


def test_a_subtopic_is_preferred_to_its_parent(taxonomy):
    assert taxonomy.by_slug()["cooking"].parent == "food-and-drink"
    p = enabled("cooking", "food-and-drink")
    labels = policy.select(p, {"cooking": 0.6, "food-and-drink": 0.8}, taxonomy)
    assert [lbl.slug for lbl in labels] == ["cooking"]


def test_at_most_max_labels_highest_first(taxonomy):
    p = enabled("cooking", "travel", "music", "pets", max_labels=2)
    probs = {"cooking": 0.5, "travel": 0.9, "music": 0.7, "pets": 0.4}
    assert [lbl.slug for lbl in policy.select(p, probs, taxonomy)] == ["travel", "music"]


def test_policies_that_enable_without_calibration_are_refused(taxonomy, tmp_path):
    path = tmp_path / "p.json"
    path.write_text(
        '{"version": "x", "enabled_topics": ["cooking"], "floor": 0.35,'
        ' "max_labels": 3, "calibration": null}'
    )
    with pytest.raises(ValueError, match="calibration"):
        policy.load(path, taxonomy)

    path.write_text(
        '{"version": "x", "enabled_topics": ["industries"], "floor": 0.35,'
        ' "max_labels": 3, "calibration": null}'
    )
    with pytest.raises(ValueError, match="unlabelable"):
        policy.load(path, taxonomy)
