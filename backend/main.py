from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()

@app.get("/health")
def health_check():
    return {"status": "ok"}

class ListeningRequest(BaseModel):
    prompt: str

@app.post("/listening-request")
def receive_listening_request(request: ListeningRequest):
    return {"received_prompt": request.prompt}

