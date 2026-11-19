"""Which model labels to emit, and at what confidence (the label policy).

A versioned file in `policy/`. Raw scores are similarities, not
probabilities; a fitted calibration turns them into probabilities (M2). The
policy then:

* considers only `enabled_topics`, those whose labels passed the eval;
* drops labels below `floor`, so faint ones don't dilute an item's shares;
* prefers a tier-2 topic to its own parent, which gets credit through the
  child already;
* keeps at most `max_labels`, highest first.

Policy v0 enables nothing and has no calibration: shadow mode.
"""

import json
from dataclasses import dataclass
from pathlib import Path

from .schemas import Label
from .taxonomy import Taxonomy


@dataclass(frozen=True)
class Policy:
    version: str
    enabled_topics: frozenset[str]
    floor: float
    max_labels: int
    calibration: dict | None


def load(path: Path, taxonomy: Taxonomy) -> Policy:
    data = json.loads(path.read_text())
    enabled = frozenset(data["enabled_topics"])
    labelable = {t.slug for t in taxonomy.labelable()}
    if not enabled <= labelable:
        raise ValueError(
            f"policy enables unknown or unlabelable topics: {sorted(enabled - labelable)}"
        )
    if data["calibration"] is not None:
        raise ValueError("calibration isn't supported yet (Phase 1b M2)")
    if enabled:
        raise ValueError("enabling topics needs a calibration")
    return Policy(
        version=data["version"],
        enabled_topics=enabled,
        floor=float(data["floor"]),
        max_labels=int(data["max_labels"]),
        calibration=None,
    )


def labels(
    policy: Policy, probabilities: dict[str, float] | None, taxonomy: Taxonomy
) -> list[Label]:
    """Labels from calibrated probabilities; none without a calibration."""
    if policy.calibration is None or probabilities is None:
        return []
    return select(policy, probabilities, taxonomy)


def select(policy: Policy, probabilities: dict[str, float], taxonomy: Taxonomy) -> list[Label]:
    by_slug = taxonomy.by_slug()
    kept = {
        slug: p
        for slug, p in probabilities.items()
        if slug in policy.enabled_topics and p >= policy.floor
    }
    children_parents = {by_slug[s].parent for s in kept if by_slug[s].parent}
    kept = {s: p for s, p in kept.items() if s not in children_parents}
    ranked = sorted(kept.items(), key=lambda sp: (-sp[1], sp[0]))[: policy.max_labels]
    return [Label(slug=s, confidence=round(min(p, 1.0), 6)) for s, p in ranked]
