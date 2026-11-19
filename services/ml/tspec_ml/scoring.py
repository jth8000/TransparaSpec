"""Raw per-topic scores: cosine similarity between an item and each topic.

Each labelable topic's prompts are embedded once at startup and averaged
(prompt ensembling), in both spaces: the image model's, for frames, and the
text model's, for caption, body and transcript. An item's score for a topic
is then a dot product of normalized vectors.

Frames are scored one by one and summarized two ways: `frames_mean` (the
topic is there throughout) and `frames_max` (it's in some frame). The frame
embeddings are stored, so other summaries, new prompts or a new policy can
be computed later without fetching the video again.
"""

import numpy as np

from .backends.base import Backends
from .taxonomy import Taxonomy

TEXT_MODALITIES = ("caption", "body", "transcript")


class FrameModelMismatch(Exception):
    """The frame embeddings came from another image model: re-extract."""


def _topic_matrix(embed, topics) -> np.ndarray:
    rows = []
    for topic in topics:
        v = embed(list(topic.prompts)).mean(axis=0)
        rows.append(v / np.linalg.norm(v))
    return np.array(rows)


def _round(scores: np.ndarray, slugs: list[str]) -> dict[str, float]:
    return {s: round(float(x), 6) for s, x in zip(slugs, scores, strict=True)}


class Scorer:
    def __init__(self, backends: Backends, taxonomy: Taxonomy):
        self.backends = backends
        topics = taxonomy.labelable()
        self.slugs = [t.slug for t in topics]
        self.image_topics = _topic_matrix(backends.image.embed_prompts, topics)
        self.text_topics = _topic_matrix(backends.text.embed_prompts, topics)

    def score(
        self,
        texts: dict[str, str | None],
        frames: list[list[float]] | None,
        frames_model: str | None,
    ) -> tuple[dict[str, dict[str, float]], dict[str, list[float]]]:
        raw, embeddings = {}, {}

        present = [(m, t) for m, t in texts.items() if t and t.strip()]
        if present:
            vectors = self.backends.text.embed_texts([t for _, t in present])
            for (modality, _), v in zip(present, vectors, strict=True):
                raw[modality] = _round(self.text_topics @ v, self.slugs)
                embeddings[modality] = [round(float(x), 6) for x in v]

        if frames:
            if frames_model != self.backends.image.model_id:
                raise FrameModelMismatch(
                    f"frames from {frames_model}, service uses {self.backends.image.model_id}"
                )
            f = np.asarray(frames, dtype=float)
            if f.ndim != 2 or f.shape[1] != self.image_topics.shape[1]:
                raise FrameModelMismatch("frame embeddings have the wrong shape")
            norms = np.linalg.norm(f, axis=1, keepdims=True)
            f = np.divide(f, norms, out=np.zeros_like(f), where=norms > 0)
            per_frame = f @ self.image_topics.T
            raw["frames_mean"] = _round(per_frame.mean(axis=0), self.slugs)
            raw["frames_max"] = _round(per_frame.max(axis=0), self.slugs)

        return raw, embeddings
