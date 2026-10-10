from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal
from intent import interpret_request
from selection import SongSelection, get_selector

app = FastAPI()

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
def receive_listening_request(request: ListeningRequest):
    parsed = interpret_request(request.prompt)
    try:
        selection = get_selector().select(request.prompt, parsed)
    except (OSError, ValueError):
        raise HTTPException(status_code=503, detail="Sample catalog unavailable. Restart the backend after checking the catalog.")

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
