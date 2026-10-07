from fastapi import FastAPI
from pydantic import BaseModel, ConfigDict, Field

app = FastAPI()

@app.get("/health")
def health_check():
    return {"status": "ok"}

class ListeningRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    prompt: str = Field(min_length=1, max_length=500)

@app.post("/listening-request")
def receive_listening_request(request: ListeningRequest):
    return {"received_prompt": request.prompt}
