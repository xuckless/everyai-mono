from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from db.db import get_db
from db.models import User
from models.auth import LoginRequest, SignUpRequest, TokenResponse
from utils.security import (
    verify_password,
    get_password_hash,
    create_access_token,
)

auth_router = APIRouter()


@auth_router.post("/signup", response_model=TokenResponse)
def sign_up(request: SignUpRequest, db: Session = Depends(get_db)):
    existing_user = db.query(User).filter(User.email == request.email).first()
    if existing_user:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Email already registered",
        )
    new_user = User(
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