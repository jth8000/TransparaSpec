"""Deterministic stand-ins for the models, for tests, CI and dev.

They compute nothing meaningful about images or speech, but they're stable
and cheap, and the text embedder is a bag of hashed words, so a caption that
names a topic scores that topic highest: enough to exercise the pipeline
end to end (`mix tspec.seed_demo` captions name their topic).
"""

import hashlib
import re
import wave
from pathlib import Path

import numpy as np

from ..limits import Deadline
from .base import Backends, TranscriptResult

DIM = 64


def _vector(key: str) -> np.ndarray:
    seed = int.from_bytes(hashlib.sha256(key.encode()).digest()[:8], "little")
    v = np.random.default_rng(seed).standard_normal(DIM)
    return v / np.linalg.norm(v)


def _normalize(rows: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(rows, axis=1, keepdims=True)
    return np.divide(rows, norms, out=np.zeros_like(rows), where=norms > 0)


def _bag_of_words(texts: list[str], space: str) -> np.ndarray:
    rows = np.zeros((len(texts), DIM))
    for i, text in enumerate(texts):
        for word in re.findall(r"[a-z0-9]+", text.lower()):
            rows[i] += _vector(f"{space}:{word}")
    return _normalize(rows)


class FakeImageEmbedder:
    model_id = "fake-image-v1"
    dim = DIM

    def embed_images(self, pngs: list[bytes]) -> np.ndarray:
        return np.array([_vector("img:" + hashlib.sha256(p).hexdigest()) for p in pngs])

    def embed_prompts(self, texts: list[str]) -> np.ndarray:
        return _bag_of_words(texts, "img-text")


class FakeTextEmbedder:
    model_id = "fake-text-v1"
    dim = DIM

    def embed_prompts(self, texts: list[str]) -> np.ndarray:
        return _bag_of_words(texts, "text")

    def embed_texts(self, texts: list[str]) -> np.ndarray:
        return _bag_of_words(texts, "text")


class FakeTranscriber:
    model_id = "fake-transcriber-v1"

    def transcribe(self, wav: Path, deadline: Deadline) -> TranscriptResult:
        deadline.check("transcribe")
        with wave.open(str(wav)) as w:
            seconds = w.getnframes() / w.getframerate()
        return TranscriptResult(text=f"fake transcript of {seconds:.1f} s of audio", language="en")


def backends() -> Backends:
    return Backends(
        image=FakeImageEmbedder(), text=FakeTextEmbedder(), transcriber=FakeTranscriber()
    )
