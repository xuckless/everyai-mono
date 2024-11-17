from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from routers.signup import signup_router  # Import the router instance

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

# Include the signup router
app.include_router(signup_router)

# Ping endpoint for health check
@app.get("/ping")
async def ping():
    return {"message": "pong"}
