# routers/auth_router.py

from fastapi import APIRouter, Depends, HTTPException, status, Request
from sqlalchemy.orm import Session
import requests
from utils.security import verify_google_token

from config import GOOGLE_CLIENT_ID_IOS, GOOGLE_CLIENT_ID_ANDROID
from db.db import get_db
from db.models import User
from models.auth import LoginRequest, SignUpRequest, TokenResponse, GoogleLoginRequest
from utils.security import (
    verify_password,
    get_password_hash,
    create_access_token,
)

GOOGLE_CLIENT_ID_IOS;
GOOGLE_CLIENT_ID_ANDROID;
auth_router = APIRouter()


@auth_router.post("/signup", response_model=TokenResponse)
def sign_up(request: SignUpRequest, db: Session = Depends(get_db)):
    print(f"SignUp Payload: {request.dict()}")
    existing_user = db.query(User).filter(User.email == request.email).first()
    if existing_user:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Email already registered",
        )
    new_user = User(
        name=request.name,  # Save the name
        email=request.email,
        password_hash=get_password_hash(request.password),
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    token = create_access_token(subject=str(new_user.id))
    return TokenResponse(access_token=token)



@auth_router.post("/login", response_model=TokenResponse)
def login(request: LoginRequest, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == request.email).first()
    if not user or not verify_password(request.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
        )
    token = create_access_token(subject=str(user.id))
    return TokenResponse(access_token=token)


@auth_router.post("/google_login", response_model=TokenResponse)
def google_login(request: GoogleLoginRequest, db: Session = Depends(get_db)):
    token = request.token
    platform = request.platform

    if platform == "ios":
        client_id = GOOGLE_CLIENT_ID_IOS
    elif platform == "android":
        client_id = GOOGLE_CLIENT_ID_ANDROID
    else:
        raise HTTPException(status_code=400, detail="Invalid platform")

    token_info = verify_google_token(token, client_id)
    if not token_info:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid Google token",
        )

    #check if user already exists
    email = token_info.get("email")
    google_id = token_info.get("sub")
    name = token_info.get("name")
    user = db.query(User).filter(User.google_id == google_id).first()

    #if user does not exist, create a new user
    if not user:
        user = User(name=name, email=email, google_id=google_id)
        db.add(user)
        db.commit()
        db.refresh(user)

    token = create_access_token(subject=str(user.id))
    return TokenResponse(access_token=token)
