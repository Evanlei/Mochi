from fastapi import FastAPI
from pydantic import BaseModel, ConfigDict, Field
from intent import parse_intent

app = FastAPI()

@app.get("/health")
def health_check():
    return {"status": "ok"}

class ListeningRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    prompt: str = Field(min_length=1, max_length=500)

class ListeningIntent(BaseModel):
    vocals: bool | None
    energy: str | None

class ListeningResponse(BaseModel):
    received_prompt: str
    intent: ListeningIntent

@app.post("/listening-request", response_model=ListeningResponse)
def receive_listening_request(request: ListeningRequest):
    parsed = parse_intent(request.prompt)

    return ListeningResponse(
        received_prompt=request.prompt,
        intent=ListeningIntent(
            energy=parsed["energy"],
            vocals=parsed["vocals"]
        )
    )
