# routers/chat_router.py

from fastapi import APIRouter, HTTPException

from models.chat import ChatRequest, ChatResponse
from utils.generate_response import generate_response

chat_router = APIRouter()

@chat_router.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    message = request.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message must not be empty")

    response_message = generate_response(message)
    return ChatResponse(message=response_message)

@chat_router.get("/ping")
async def ping():
    return {"message": "Pong!"}