from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal
from intent import interpret_request
from selection import SongSelection, get_selector
from contextlib import asynccontextmanager
from uuid import UUID
from recommendations import RecommendationService
from settings import Settings
from starlette.concurrency import run_in_threadpool
import sqlite3

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
    model_config = ConfigDict(str_strip_whitespace=True)

    prompt: str = Field(min_length=1, max_length=500)

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

@app.post("/listening-request", response_model=ListeningResponse)
async def receive_listening_request(request: ListeningRequest):
    parsed = await run_in_threadpool(interpret_request, request.prompt)
    try:
        if app.state.settings.mode == "sample":
            selection = get_selector().select(request.prompt, parsed)
        else:
            selection = await app.state.recommendations.recommend(request.prompt, parsed)
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
