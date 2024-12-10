# utils/security.py

from datetime import datetime, timedelta, timezone
from http.client import responses
from secrets import token_urlsafe
from typing import Optional
import requests

import jwt
from passlib.context import CryptContext
from config import SECRET_KEY, ALGORITHM, ACCESS_TOKEN_EXPIRE_MINUTES

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)


def create_access_token(subject: str, expires_delta: Optional[timedelta] = None) -> str:
    if expires_delta:
        expire = datetime.now(timezone.utc) + expires_delta
    else:
        expire = datetime.now(timezone.utc) + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode = {"exp": expire, "sub": subject}
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

#generate the long-lived refresh token
def generate_refresh_token():
    return token_urlsafe(64)

def generate_refresh_token_expiry(days=30):
    print(datetime.now(timezone.utc) + timedelta(days=days))
    return datetime.now(timezone.utc) + timedelta(days=days)

def verify_google_token(token: str, client_id: str):
    try:
        response = requests.get(f"https://oauth2.googleapis.com/tokeninfo?id_token={token}")
        token_info = response.json()

        if response.status_code != 200 or token_info.get("aud") != client_id:
            return None

        return token_info
    except Exception as e:
        return None
