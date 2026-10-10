"""Independent recording metadata, kept separate from Spotify display metadata."""

import hashlib
import re
import unicodedata
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


def normalized(value):
    return " ".join(re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", value).casefold()))


def identity_key(title, artist):
    # Conservative identity: live/acoustic/remix version words remain significant.
    return hashlib.sha256(f"{normalized(artist)}\n{normalized(title)}".encode()).hexdigest()


def artist_key(artist):
    return hashlib.sha256(normalized(artist).encode()).hexdigest()


class CatalogTrack(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True, str_strip_whitespace=True, extra="forbid")
    id: str = Field(min_length=1, max_length=100)
    title: str = Field(min_length=1, max_length=200)
    artist: str = Field(min_length=1, max_length=200)
    bpm: float | None = Field(default=None, ge=20, le=400, allow_inf_nan=False)
    vocals: bool | None = None
    energy: Literal["low", "high"] | None = None
    description: str = Field(min_length=1, max_length=1000)
    tags: tuple[str, ...] = ()
    source: Literal["lastfm", "fictional_sample"] = "lastfm"
    source_url: str | None = None
    mbid: str | None = None
    isrc: str | None = None
    duration_ms: int | None = Field(default=None, gt=0)
    feature_source: Literal["reccobeats"] | None = None
    feature_recording_id: str | None = None
    feature_spotify_id: str | None = Field(default=None, pattern=r"^[A-Za-z0-9]{22}$")

    @property
    def search_text(self):
        return f"{self.title} by {self.artist}. {self.description}"
