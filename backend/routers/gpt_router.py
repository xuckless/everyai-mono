from fastapi import APIRouter, HTTPException
from starlette.responses import JSONResponse

from models.chat import GPTRequestModel, ChatResponse
from routers import PROTECTED_ROUTE
from utils.generate_response import specific_response

gpt_router = APIRouter(prefix="/chat")



@gpt_router.post(f"/gpt", response_model=ChatResponse)
async def gpt_mini(chat: GPTRequestModel):
    message = chat.message.strip()
    model = chat.model.lower().strip()
    if not message:
        raise HTTPException(status_code=400, detail="Message must not be empty")

    valid_models = ["gpt-3.5-turbo", "gpt-4o-mini"]
    print(model)

    response = specific_response(message, model)
    return JSONResponse(content={"message": response}, media_type="application/json; charset=utf-8")


