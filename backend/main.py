# main.py

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routers.auth_router import auth_router
from routers.protected_router import protected_router
from routers.chat_router import chat_router

# Initialize FastAPI app
app = FastAPI()

# Add CORS middleware if needed
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Replace "*" with specific origins if needed
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(auth_router)
app.include_router(protected_router)
app.include_router(chat_router)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,  # Pass the app instance directly
        host="0.0.0.0",
        port=8000,
        reload=True
    )

    #uvicorn main:app --reload