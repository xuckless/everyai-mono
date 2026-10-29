# config.py

import os
from dotenv import load_dotenv

load_dotenv()

SECRET_KEY = os.getenv("SECRET_KEY")
if not SECRET_KEY:
    raise ValueError("No SECRET_KEY set for the application")

ALGORITHM = os.getenv("ALGORITHM", "HS256")
if not ALGORITHM:
    raise ValueError("No ALGORITHM set for the application")

ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", 30))

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise ValueError("No DATABASE_URL set for the application")

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
if not OPENAI_API_KEY:
    raise ValueError("No OPENAI_API_KEY found in the environment")

GOOGLE_CLIENT_ID_ANDROID = os.getenv("GOOGLE_CLIENT_ID_ANDROID")
if not GOOGLE_CLIENT_ID_ANDROID:
    raise ValueError("No GOOGLE_CLIENT_ID_ANDROID set for the application")

GOOGLE_CLIENT_ID_IOS = os.getenv("GOOGLE_CLIENT_ID_IOS")
if not GOOGLE_CLIENT_ID_IOS:
    raise ValueError("No GOOGLE_CLIENT_ID_IOS set for the application")

GOOGLE_CLIENT_ID_WEB = os.getenv("GOOGLE_CLIENT_ID_WEB")
if not GOOGLE_CLIENT_ID_WEB:
    raise ValueError("No GOOGLE_CLIENT_ID_WEB set for the application")

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    raise ValueError("No GEMINI_API_KEY found in the environment")

GROK_API_KEY = os.getenv("GROK_API_KEY")
if not GROK_API_KEY:
    raise ValueError("No GROK_API_KEY found in the environment")

CLAUDE_API_KEY = os.getenv("CLAUDE_API_KEY")
if not CLAUDE_API_KEY:
    raise ValueError("No CLAUDE_API_KEY found in the environment")

STABILITY_API_KEY = os.getenv("STABILITY_API_KEY")
if not STABILITY_API_KEY:
    raise ValueError("No STABLEDIFFUSION_API_KEY found in the environment")
