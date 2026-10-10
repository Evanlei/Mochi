"""Filter explicit requirements, then rank a small catalog by text similarity."""

import logging
import math
import re
import threading
from collections import Counter
from functools import lru_cache
from typing import Literal

from pydantic import BaseModel

from catalog import load_catalog
from music import CatalogTrack, artist_key
from intent import IntentResult
from semantic import get_matcher

# Generic request words must not make every entry look relevant in fallback mode.
STOP_WORDS = set("a an and are at be by can for from give help i im in is it like me music my of on please play put request some something song songs that the to want with without no not bpm beats per minute".split())


def words(text):
    return set(re.findall(r"[^\W\d_]+", text.casefold())) - STOP_WORDS


class SelectedTrack(CatalogTrack):
    score: float


class SongSelection(BaseModel):
    catalog_kind: Literal["fictional_sample", "lastfm_live"] = "fictional_sample"
    method: Literal["semantic", "lexical", "none"]
    tracks: list[SelectedTrack]
    message: str | None = None
    request_id: str | None = None
    warnings: list[str] = []


class SongSelector:
    def __init__(self, tracks):
        self.tracks = tuple(tracks)
        self.catalog_kind = "fictional_sample" if all(track.id.startswith("sample-") for track in self.tracks) else "lastfm_live"
        self._documents = [words(track.search_text) for track in self.tracks]
        counts = Counter(word for document in self._documents for word in document)
        self._idf = {word: math.log((len(self.tracks) + 1) / (count + 1)) + 1
                     for word, count in counts.items()}
        self._vector_lock = threading.Lock()
        self._vectors = None
        self._encoder = None

    def _lexical_scores(self, prompt):
        query = words(prompt)
        query_norm = math.sqrt(sum(self._idf.get(word, 1) ** 2 for word in query))
        scores = []
        for document in self._documents:
            document_norm = math.sqrt(sum(self._idf[word] ** 2 for word in document))
            numerator = sum(self._idf[word] ** 2 for word in query & document)
            scores.append(numerator / (query_norm * document_norm) if query_norm and document_norm else 0)
        return scores

    def _semantic_scores(self, prompt, encoder):
        # Each process embeds the catalog once, not once per user request.
        with self._vector_lock:
            if self._vectors is None or self._encoder is not encoder:
                vectors = encoder.embed_tracks([track.search_text for track in self.tracks])
                if len(vectors) != len(self.tracks):
                    raise ValueError("Catalog embedding count mismatch")
                self._vectors = [self._normalize(vector) for vector in vectors]
                self._encoder = encoder
            vectors = self._vectors
        query = self._normalize(encoder.embed_query(prompt))
        if any(len(vector) != len(query) for vector in vectors):
            raise ValueError("Embedding dimension mismatch")
        return [sum(left * right for left, right in zip(query, vector)) for vector in vectors]

    @staticmethod
    def _normalize(vector):
        values = tuple(float(value) for value in vector)
        norm = math.sqrt(sum(value * value for value in values))
        if not values or not math.isfinite(norm) or norm == 0:
            raise ValueError("Invalid embedding")
        return tuple(value / norm for value in values)

    def select(self, prompt, intent: IntentResult, *, use_semantic=True, encoder=None, limit=5, taste=None):
        if intent.clarification:
            return SongSelection(catalog_kind=self.catalog_kind, method="none", tracks=[], message="Clarify your request before choosing tracks.")
        taste = taste or {"tracks": {}, "artists": {}, "recent": []}
        eligible = [index for index, track in enumerate(self.tracks)
                    if (intent.vocals is None or track.vocals == intent.vocals)
                    and (not intent.energy_locked or intent.energy is None or track.energy == intent.energy)
                    and (intent.bpm_min is None or track.bpm is not None and track.bpm >= intent.bpm_min)
                    and (intent.bpm_max is None or track.bpm is not None and track.bpm <= intent.bpm_max)
                    and taste["tracks"].get(track.id, 0) >= 0]
        if not eligible:
            message = "No sample tracks meet those requirements. Try a wider BPM range or different preferences." if self.catalog_kind == "fictional_sample" else "No candidates have verified data for those requirements. Missing BPM, vocals, or energy cannot qualify. Try fewer requirements or another genre."
            return SongSelection(catalog_kind=self.catalog_kind, method="none", tracks=[], message=message)

        scores, method = self._lexical_scores(prompt), "lexical"
        if use_semantic:
            encoder = encoder if encoder is not None else get_matcher()
            if encoder is not None:
                try:
                    scores = self._semantic_scores(prompt, encoder)
                    method = "semantic"
                except Exception:
                    logging.getLogger(__name__).warning("Local track matching failed; using word matching")

        # Similarity ranks relevance. Inferred energy is only a small preference.
        # These scores are not probabilities and differ across matching methods.
        threshold = 0.45 if method == "semantic" else 0.0
        constrained = intent.vocals is not None or intent.energy_locked or intent.bpm_min is not None or intent.bpm_max is not None
        candidates = []
        for index in eligible:
            similarity = scores[index]
            if (method == "semantic" and similarity < threshold) or (method == "lexical" and similarity <= threshold and not constrained):
                continue
            track = self.tracks[index]
            bonus = 0.08 if not intent.energy_locked and intent.energy == track.energy else 0.0
            personal = 0.12 * max(0, taste["tracks"].get(track.id, 0))
            personal += max(-0.08, min(0.08, 0.04 * taste["artists"].get(artist_key(track.artist), 0)))
            personal -= min(0.15, 0.03 * taste["recent"].count(track.id))
            values = track.model_dump()
            if self.catalog_kind == "fictional_sample": values["source"] = "fictional_sample"
            candidates.append(SelectedTrack(**values, score=round(similarity + bonus + personal, 6)))
        candidates.sort(key=lambda track: (-track.score, track.id))
        message = None if candidates else "No close matches. Try piano, acoustic guitar, jazz, or electronic music."
        return SongSelection(catalog_kind=self.catalog_kind, method=method, tracks=candidates[:max(0, min(limit, 5))], message=message)


@lru_cache(maxsize=1)
def get_selector():
    return SongSelector(load_catalog())
