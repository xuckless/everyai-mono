# routers/auth_router.py

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from utils.handle_google_login import handle_google_login


from config import GOOGLE_CLIENT_ID_IOS, GOOGLE_CLIENT_ID_ANDROID
from db.db import get_db
from db.models import User
from models.auth import LoginRequest, SignUpRequest, TokenResponse, GoogleLoginRequest
from utils.security import (
    verify_password,
    create_access_token,
)

GOOGLE_CLIENT_ID_IOS;
GOOGLE_CLIENT_ID_ANDROID;
auth_router = APIRouter()


@auth_router.post("/signup", status_code=status.HTTP_200_OK)
def sign_up(request: SignUpRequest, db: Session = Depends(get_db)):
    try:
        # Create a new user
        new_user = User(id=request.uuid, email=request.email)  # Using UUID as the ID here
        db.add(new_user)
        db.commit()
        db.refresh(new_user)

        # Return success response
        return {"success": True, "message": "User created successfully", "uuid": new_user.id}

    except Exception as e:
        # Handle unexpected errors
        db.rollback()
        raise HTTPException(status_code=500, detail=f"An unexpected error occurred: {str(e)}")


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
    return handle_google_login(request.token, request.platform, db)