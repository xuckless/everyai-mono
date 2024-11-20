# routers/chat_router.py

from fastapi import APIRouter, HTTPException, Depends

from db.models import User
from models.chat import ChatRequest, ChatResponse
from routers import PROTECTED_ROUTE
from utils.generate_response import generate_response
from utils.validate_current_user import get_current_user

chat_router = APIRouter(prefix='/protected', tags=['protected'])

@chat_router.post(f"{PROTECTED_ROUTE}/chat", response_model=ChatResponse)
async def chat(request: ChatRequest, current_user: User = Depends(get_current_user)):
    message = request.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message must not be empty")

    # Generate a response using the utility function
    response_message = generate_response(message)

    # Return the response as a ChatResponse model
    return ChatResponse(message=response_message)

@chat_router.get("/ping")
async def ping():
    return {"message": "Pong!"}