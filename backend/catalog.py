"""An authored fictional catalog, kept separate from Spotify metadata."""

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

CATALOG_PATH = Path(__file__).resolve().parent / "data" / "sample-catalog.json"


class SampleTrack(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True, str_strip_whitespace=True, extra="forbid")

    id: str = Field(pattern=r"^sample-[a-z0-9-]+$")
    title: str = Field(min_length=1, max_length=100)
    artist: str = Field(min_length=1, max_length=100)
    bpm: float | None = Field(ge=20, le=400)
    vocals: bool
    energy: Literal["low", "high"]
    description: str = Field(min_length=1, max_length=500)

    @property
    def search_text(self):
        return f"{self.title} by {self.artist}. {self.description}"


class SampleCatalog(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")
    schema_version: Literal[1]
    kind: Literal["fictional_sample"]
    provenance: str = Field(min_length=1)
    tracks: tuple[SampleTrack, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def unique_ids(self):
        if len({track.id for track in self.tracks}) != len(self.tracks):
            raise ValueError("Sample track IDs must be unique")
        return self


@lru_cache(maxsize=1)
def load_catalog():
    return SampleCatalog.model_validate_json(CATALOG_PATH.read_text()).tracks
