from models.chat import GPTRequestModel, ChatResponse
from routers import PROTECTED_ROUTE
import utils.generate_response as responses

from fastapi import HTTPException, APIRouter
from fastapi.responses import JSONResponse
from httpx import TimeoutException, HTTPStatusError, RequestError

gpt_router = APIRouter(prefix="/chat")


@gpt_router.post("/gpt", response_model=ChatResponse)
async def gpt_mini(chat: GPTRequestModel):
    try:
        message = chat.message.strip()
        model = chat.model.lower().strip()

        # Check for empty message
        if not message:
            raise HTTPException(status_code=400, detail="Message must not be empty")

        print(f"Using model: {model}")

        # Call the specific_response function to process the message
        response = responses.specific_response(message, model)

        # Return the response
        return JSONResponse(content={"message": response}, media_type="application/json; charset=utf-8")

    except TimeoutException:
        # Handle API timeout
        raise HTTPException(status_code=504, detail="The request to the external service timed out. Please try again.")

    except HTTPStatusError as e:
        # Handle HTTP errors from the external API
        raise HTTPException(status_code=e.response.status_code, detail=f"External API error: {e.response.text}")

    except RequestError as e:
        # Handle request-related errors
        raise HTTPException(status_code=502, detail=f"Request to the external service failed: {str(e)}")

    except Exception as e:
        # Catch-all for unexpected errors
        raise HTTPException(status_code=500, detail=f"An unexpected error occurred: {str(e)}")


@gpt_router.post('/gemini', response_model=ChatResponse)
async def gpt_gemini(chat: GPTRequestModel):
    try:
        propmt = chat.message.strip()
        model = chat.model.lower()

        print(f"Using model: {model}")

        response = responses.gemini_response(propmt, model)

        return JSONResponse(content={"message": response},
                            media_type="application/json; charset=utf-8")
    except Exception as e:
        # Catch-all for unexpected errors
        raise HTTPException(status_code=500, detail=f"An unexpected error occurred: {str(e)}")





@gpt_router.post('/llama', response_model=ChatResponse)
async def gpt_gemini(chat: GPTRequestModel):
    return JSONResponse(content={"message": "Llama models are yet to be set up."}, media_type="application/json; charset=utf-8")
