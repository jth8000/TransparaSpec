"""The topics the service scores, and the text it scores them by.

`taxonomy.json` is exported from the server (`mix tspec.export_taxonomy`)
and must not be edited by hand; a server test keeps it in sync. Prompts are
hand-edited in `prompts.json`, keyed by slug:

* `synonyms`: more phrasings, averaged with the name (prompt ensembling);
* `prompt`: replaces the name as the main phrasing;
* `model: false`: the model never labels the topic, for containers whose
  name says little on its own (their subtopics were dropped with tier 3).

Every key must be a real slug, and only these fields are allowed, so a typo
fails at startup instead of silently not applying.
"""

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

PROMPT_FIELDS = {"synonyms", "prompt", "model", "why"}


@dataclass(frozen=True)
class Topic:
    slug: str
    name: str
    tier: int
    parent: str | None
    prompts: tuple[str, ...]
    model: bool


@dataclass(frozen=True)
class Taxonomy:
    topics: tuple[Topic, ...]
    version: str

    def by_slug(self) -> dict[str, Topic]:
        return {t.slug: t for t in self.topics}

    def labelable(self) -> tuple[Topic, ...]:
        return tuple(t for t in self.topics if t.model)


def load(root: Path) -> Taxonomy:
    taxonomy_bytes = (root / "taxonomy.json").read_bytes()
    prompts_bytes = (root / "prompts.json").read_bytes()
    exported = json.loads(taxonomy_bytes)["topics"]
    overrides = json.loads(prompts_bytes)["topics"]

    slugs = {t["slug"] for t in exported}
    unknown = sorted(set(overrides) - slugs)
    if unknown:
        raise ValueError(f"prompts.json names unknown topics: {', '.join(unknown)}")
    for slug, entry in overrides.items():
        extra = set(entry) - PROMPT_FIELDS
        if extra:
            raise ValueError(f"prompts.json {slug}: unknown fields {sorted(extra)}")

    topics = []
    for t in exported:
        entry = overrides.get(t["slug"], {})
        main = entry.get("prompt", t["name"])
        topics.append(
            Topic(
                slug=t["slug"],
                name=t["name"],
                tier=t["tier"],
                parent=t["parent"],
                prompts=(main, *entry.get("synonyms", [])),
                model=entry.get("model", True),
            )
        )

    version = hashlib.sha256(taxonomy_bytes + b"\0" + prompts_bytes).hexdigest()[:12]
    return Taxonomy(topics=tuple(topics), version=version)
