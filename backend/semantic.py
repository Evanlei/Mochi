"""Local energy matching. Model installation is separate from serving requests."""

import hashlib
import json
import logging
import threading
from pathlib import Path

MODEL_NAME = "BAAI/bge-small-en-v1.5"
MODEL_REPOSITORY = "Qdrant/bge-small-en-v1.5-onnx-Q"
MODEL_REVISION = "aa8f8b060edb00e03bfdd08813a2949946c8ba55"
MODEL_DIRECTORY = Path(__file__).resolve().parent / ".models" / "intent-energy"
MODEL_FILES = ("model_optimized.onnx", "config.json", "special_tokens_map.json",
               "tokenizer.json", "tokenizer_config.json", "vocab.txt")

# Reference descriptions are development inputs, separate from evaluation requests.
REFERENCE_TEXTS = {
    "low": (
        "I want calm, gentle music that helps me relax.",
        "Soft mellow songs to wind down and unwind.",
        "Peaceful soothing music with low energy.",
        "Slow laid-back music for a quiet mood.",
        "Music that lets me take it easy and decompress.",
    ),
    "high": (
        "I want energetic upbeat music that gets me moving.",
        "High-energy songs to pump me up and keep me alert.",
        "Lively music to boost my motivation and excitement.",
        "Fast driving music with an intense mood.",
        "Music that wakes me up and makes me want to dance.",
    ),
    "unspecified": (
        "I want music but have not specified how energetic it should be.",
        "Find songs by an artist or in a genre.",
        "Some music for studying and working.",
        "A request with no energy preference.",
        "Music for cooking commuting or reading.",
        "There is not enough information to determine energy.",
    ),
}


class EnergyMatcher:
    def __init__(self, *, minimum_similarity=0.65, minimum_margin=0.02):
        import numpy as np
        import onnxruntime
        from fastembed import TextEmbedding

        onnxruntime.disable_telemetry_events()
        manifest = json.loads((MODEL_DIRECTORY / "manifest.json").read_text())
        if manifest["revision"] != MODEL_REVISION:
            raise ValueError("Unexpected intent model revision")
        for filename in MODEL_FILES:
            content = (MODEL_DIRECTORY / filename).read_bytes()
            if hashlib.sha256(content).hexdigest() != manifest["sha256"][filename]:
                raise ValueError("Intent model file failed integrity check")

        self._np = np
        self._model = TextEmbedding(model_name=MODEL_NAME,
            specific_model_path=str(MODEL_DIRECTORY), local_files_only=True,
            threads=2, providers=["CPUExecutionProvider"])
        self._lock = threading.Lock()
        self.minimum_similarity = minimum_similarity
        self.minimum_margin = minimum_margin
        self._centroids = {}
        for label, descriptions in REFERENCE_TEXTS.items():
            centroid = np.mean(list(self._model.embed(descriptions)), axis=0)
            self._centroids[label] = centroid / np.linalg.norm(centroid)

    def scores(self, prompt):
        with self._lock:
            vector = next(iter(self._model.embed([prompt])))
        return {label: float(self._np.dot(vector, centroid))
                for label, centroid in self._centroids.items()}

    def embed_tracks(self, descriptions):
        """Reuse the loaded model and serialize its tokenizer/inference calls."""
        with self._lock:
            return list(self._model.passage_embed(descriptions))

    def embed_query(self, prompt):
        with self._lock:
            return next(iter(self._model.query_embed(prompt)))

    def predict(self, prompt):
        scores = sorted(self.scores(prompt).items(), key=lambda item: item[1], reverse=True)
        label, similarity = scores[0]
        margin = similarity - scores[1][1]
        if label == "unspecified" or similarity < self.minimum_similarity or margin < self.minimum_margin:
            return None
        return label


_load_lock = threading.Lock()
_matcher = None
_attempted = False


def get_matcher():
    """Missing packages/model files leave the deterministic rules available."""
    global _matcher, _attempted
    with _load_lock:
        if not _attempted:
            _attempted = True
            if (MODEL_DIRECTORY / "manifest.json").is_file():
                try:
                    _matcher = EnergyMatcher()
                except Exception:
                    logging.getLogger(__name__).warning("Local intent model unavailable; using rules")
        return _matcher
