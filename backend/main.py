from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator
from typing import Annotated, Literal
from intent import interpret_request
from selection import SongSelection, get_selector
from contextlib import asynccontextmanager
from uuid import UUID
from recommendations import RecommendationService
from settings import Settings
from starlette.concurrency import run_in_threadpool
import sqlite3
import asyncio
import unicodedata
from music import normalized
from providers import ProviderError

@asynccontextmanager
async def lifespan(app):
    app.state.settings = Settings.from_environment()
    app.state.recommendations = RecommendationService(app.state.settings)
    try:
        yield
    finally:
        await app.state.recommendations.close()

app = FastAPI(lifespan=lifespan)

@app.get("/health")
def health_check():
    return {"status": "ok"}

class ListeningRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    prompt: str = Field(min_length=1, max_length=500)
    favorite_artists: list[Annotated[str, StringConstraints(strict=True, strip_whitespace=True, min_length=1, max_length=200)]] = Field(default_factory=list, max_length=3)

    @field_validator("favorite_artists")
    @classmethod
    def usable_artists(cls, names):
        if any(not normalized(name) or any(unicodedata.category(ch) in {"Cc", "Cs"} for ch in name) for name in names):
            raise ValueError("Use artist names without control characters")
        if len({normalized(name) for name in names}) != len(names):
            raise ValueError("Choose each artist once")
        return names

class ArtistSearch(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    query: str = Field(min_length=1, max_length=100)

@app.post("/artist-search")
async def search_artists(request: ArtistSearch):
    if not normalized(request.query) or any(unicodedata.category(ch) in {"Cc", "Cs"} for ch in request.query):
        raise HTTPException(status_code=422, detail="Enter an artist name.")
    try:
        async with asyncio.timeout(8):
            names = await app.state.recommendations.lastfm.search_artists(request.query)
        return {"query": request.query, "artists": names}
    except ProviderError as error:
        raise HTTPException(status_code=503, detail=str(error)) from None
    except TimeoutError:
        raise HTTPException(status_code=504, detail="Artist search took too long. Try again.") from None
    except (OSError, sqlite3.Error):
        raise HTTPException(status_code=503, detail="Artist search storage is unavailable.") from None

class ListeningIntent(BaseModel):
    vocals: bool | None
    energy: Literal["low", "high"] | None
    bpm_min: float | None = None
    bpm_max: float | None = None

class ListeningResponse(BaseModel):
    received_prompt: str
    intent: ListeningIntent
    clarification: str | None = None
    selection: SongSelection

class SimilarRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    request_id: UUID
    track_id: str = Field(pattern=r"^lastfm-[0-9a-f]{64}$")
    title: str = Field(min_length=1, max_length=200)
    artist: str = Field(min_length=1, max_length=200)

@app.post("/more-like-this", response_model=ListeningResponse)
async def more_like_this(request: SimilarRequest):
    if app.state.settings.mode != "live":
        raise HTTPException(status_code=409, detail="More like this requires live discovery.")
    service = app.state.recommendations
    try:
        prompt, seed, previous = await run_in_threadpool(service.similar_context,
            str(request.request_id), request.track_id, request.title, request.artist)
    except LookupError:
        raise HTTPException(status_code=409, detail="This recommendation has expired. Send a new listening request.") from None
    except ValueError:
        raise HTTPException(status_code=422, detail="Choose a song from that recommendation.") from None
    except (OSError, sqlite3.Error):
        raise HTTPException(status_code=503, detail="Music discovery storage is unavailable.") from None
    parsed = await run_in_threadpool(interpret_request, prompt)
    try:
        selection = await service.recommend(prompt, parsed, seed=seed, exclude=previous)
    except (OSError, ValueError, sqlite3.Error):
        raise HTTPException(status_code=503, detail="Music discovery storage is unavailable.") from None
    return ListeningResponse(received_prompt=prompt,
        intent=ListeningIntent(vocals=parsed.vocals, energy=parsed.energy, bpm_min=parsed.bpm_min, bpm_max=parsed.bpm_max),
        clarification=parsed.clarification, selection=selection)

@app.post("/listening-request", response_model=ListeningResponse)
async def receive_listening_request(request: ListeningRequest):
    parsed = await run_in_threadpool(interpret_request, request.prompt)
    try:
        if app.state.settings.mode == "sample":
            selection = get_selector().select(request.prompt, parsed)
        else:
            selection = await app.state.recommendations.recommend(request.prompt, parsed, artists=request.favorite_artists)
    except (OSError, ValueError, sqlite3.Error):
        detail = "Sample catalog unavailable. Restart the backend after checking the catalog." if app.state.settings.mode == "sample" else "Music discovery storage is unavailable. Check backend/.data and restart the backend."
        raise HTTPException(status_code=503, detail=detail) from None

    return ListeningResponse(
        received_prompt=request.prompt,
        intent=ListeningIntent(
            energy=parsed.energy,
            vocals=parsed.vocals,
            bpm_min=parsed.bpm_min,
            bpm_max=parsed.bpm_max
        ),
        clarification=parsed.clarification,
        selection=selection
    )

class FeedbackRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    event_id: UUID
    request_id: UUID
    track_id: str = Field(min_length=1, max_length=100)
    event: Literal["like", "dislike", "select", "replay"]

@app.post("/feedback")
def receive_feedback(request: FeedbackRequest):
    try:
        app.state.recommendations.taste.feedback(str(request.event_id), str(request.request_id), request.track_id, request.event)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error))
    return {"status": "ok"}

@app.delete("/taste")
def clear_taste():
    app.state.recommendations.taste.clear()
    return {"status": "ok"}
