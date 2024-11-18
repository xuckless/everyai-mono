# ./models/chat_router.py

from pydantic import BaseModel

class ChatRequest(BaseModel):
    message: str

class ChatResponse(BaseModel):
    message: str


class GPTRequestModel(BaseModel):
    message: str
    model: str