from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from pydantic import BaseModel
from datetime import datetime, timedelta
import jwt
from passlib.context import CryptContext
import uuid

from db.db import get_db
from db.models import User

# JWT Settings
SECRET_KEY = "sV5Inc7kLnnVrP3X0e-lbJDMbzvDAhBrkZzO2XB9VJ8"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

# Password hashing
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# Router instance
auth_router = APIRouter()

# Pydantic model for login request
class LoginRequest(BaseModel):
    email: str
    password: str

# Utility functions
def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def create_access_token(data: dict) -> str:
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})

    # Convert UUID to string if present
    if "sub" in to_encode and isinstance(to_encode["sub"], uuid.UUID):
        to_encode["sub"] = str(to_encode["sub"])

    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)


# Login route
@auth_router.post("/login")
def login(request: LoginRequest, db: Session = Depends(get_db)):
    # Check if the user exists
    user = db.query(User).filter(User.email == request.email).first()
    if not user or not verify_password(request.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password")

    # Create JWT token
    token = create_access_token(data={"sub": user.id})
    return {"access_token": token, "token_type": "bearer"}
