"""The HTTP contract with Phoenix (ADR 0003, amended in Phase 1b).

Two calls, so that re-scoring never needs the video again:

* `POST /v1/extract/video`: fetches the media and returns what's expensive
  to compute: the transcript and per-frame image embeddings. Phoenix stores
  them.
* `POST /v1/score`: from text and stored frame embeddings, returns per-topic
  scores and, under the current label policy, labels. Cheap; it runs for text
  posts, caption edits and policy changes.

Scores are scores: nothing here approves or rejects content. `contract/`
holds example requests and responses that both test suites check against.
"""

from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

CONTRACT_VERSION = "1"


class _Model(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ExtractVideoRequest(_Model):
    content_id: UUID
    media_url: str = Field(max_length=2048)
    duration_ms: int = Field(gt=0, le=600_000)
    # The client's budget. The service stops at the sooner of this and its
    # own deadline, so it always gives up before the client's HTTP timeout.
    deadline_ms: int | None = Field(default=None, gt=0)


class Transcript(_Model):
    text: str
    language: str | None


class Frames(_Model):
    model: str
    timestamps_ms: list[int]
    # L2-normalized, one row per frame, in timestamp order.
    embeddings: list[list[float]]


class ExtractVideoResponse(_Model):
    contract: str = CONTRACT_VERSION
    content_id: UUID
    extractor_version: str
    # Whether the media had an audio stream. False with a null transcript is
    # a video without sound, not a failure to find its audio.
    has_audio: bool
    transcript: Transcript | None
    frames: Frames
    timings_ms: dict[str, int]


class FrameInput(_Model):
    # The image model that produced the embeddings. It must be the service's
    # current one; after an image model change, items are re-extracted.
    model: str
    embeddings: list[list[float]] = Field(min_length=1, max_length=64)


class ScoreRequest(_Model):
    content_id: UUID
    caption: str | None = Field(default=None, max_length=2200)
    body: str | None = Field(default=None, max_length=2000)
    transcript: str | None = Field(default=None, max_length=100_000)
    frames: FrameInput | None = None


class Label(_Model):
    slug: str
    confidence: float = Field(gt=0, le=1)


class ScoreResponse(_Model):
    contract: str = CONTRACT_VERSION
    content_id: UUID
    models: dict[str, str]
    # Changes whenever taxonomy.json or prompts.json does.
    prompts_version: str
    policy_version: str
    # modality → topic slug → raw similarity (not a probability). Modalities:
    # `caption`, `body`, `transcript` (text), `frames_mean`, `frames_max`
    # (over the frames). Only modalities the request had are present, and only
    # topics the model may label.
    raw_scores: dict[str, dict[str, float]]
    # Text modality → its L2-normalized embedding.
    text_embeddings: dict[str, list[float]]
    # Under the label policy. Empty while no topic is enabled (policy v0).
    labels: list[Label]


class Error(_Model):
    error: str
    detail: str | None = None
