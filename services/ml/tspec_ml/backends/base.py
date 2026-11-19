"""What the service needs from its models. M1 ships fakes; M2 adds real ones.

Embeddings are L2-normalized rows, so a dot product is a cosine similarity.
An image embedder also embeds text prompts *into the image space* (SigLIP
has a text tower for this); a text embedder embeds both prompts and content
into its own space.
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import numpy as np

from ..limits import Deadline


@dataclass
class TranscriptResult:
    text: str
    language: str | None


class ImageEmbedder(Protocol):
    model_id: str
    dim: int

    def embed_images(self, pngs: list[bytes]) -> np.ndarray: ...

    def embed_prompts(self, texts: list[str]) -> np.ndarray: ...


class TextEmbedder(Protocol):
    model_id: str
    dim: int

    def embed_prompts(self, texts: list[str]) -> np.ndarray: ...

    def embed_texts(self, texts: list[str]) -> np.ndarray: ...


class Transcriber(Protocol):
    model_id: str

    # Must return or raise DeadlineExceeded before the deadline passes.
    def transcribe(self, wav: Path, deadline: Deadline) -> TranscriptResult: ...


@dataclass
class Backends:
    image: ImageEmbedder
    text: TextEmbedder
    transcriber: Transcriber

    def versions(self) -> dict[str, str]:
        return {
            "image": self.image.model_id,
            "text": self.text.model_id,
            "transcriber": self.transcriber.model_id,
        }
