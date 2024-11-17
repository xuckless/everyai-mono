from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routers.protected import protected_router
from routers.signup import signup_router
from routers.auth import auth_router

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

# Include the signup and the login router
app.include_router(signup_router)
app.include_router(auth_router)
app.include_router(protected_router)

@app.get("/ping")
async def ping():
    return {"message": "pong"}
