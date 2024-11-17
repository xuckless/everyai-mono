from fastapi import FastAPI
from routers.chat import router as chat_router

from fastapi.middleware.cors import CORSMiddleware



app = FastAPI()
app.include_router(chat_router)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # For development, allow all origins. Specify in production.
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

if __name__ == '__main__':
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True
    )