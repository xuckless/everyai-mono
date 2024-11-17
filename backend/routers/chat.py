#./routers/chat.py

from fastapi import APIRouter, HTTPException
from models.chat import ChatRequest, ChatResponse
from utils.generate_response import generate_response

router = APIRouter()

@router.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    if not request.message.strip():
        raise HTTPException(status_code=400, detail="Message must not be empty")
    response_message = generate_response(request.message.strip())
    return ChatResponse(message=response_message)

# @router.api_route('/ping')
# async def ping():
#     return {"message": "Pong!"}