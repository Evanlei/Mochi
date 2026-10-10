from fastapi import FastAPI
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal
from intent import interpret_request

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

class ListeningResponse(BaseModel):
    received_prompt: str
    intent: ListeningIntent
    clarification: str | None = None

@app.post("/listening-request", response_model=ListeningResponse)
def receive_listening_request(request: ListeningRequest):
    parsed = interpret_request(request.prompt)

    return ListeningResponse(
        received_prompt=request.prompt,
        intent=ListeningIntent(
            energy=parsed.energy,
            vocals=parsed.vocals
        ),
        clarification=parsed.clarification
    )
