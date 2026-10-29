# ./models/chat_router.py

from pydantic import BaseModel

class ChatRequest(BaseModel):
    message: str

class ChatResponse(BaseModel):
    message: str


class GPTRequestModel(BaseModel):
    message: str
    model: str
    max_tokens: int=1024 #default value for max_tokens of model output; not all models require this parameter