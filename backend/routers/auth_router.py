# routers/auth_router.py
from datetime import datetime, timezone

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    status,
)

import jwt
from sqlalchemy.orm import Session
from utils.security import verify_google_token, generate_refresh_token, generate_refresh_token_expiry

from config import (
    GOOGLE_CLIENT_ID_IOS,
    GOOGLE_CLIENT_ID_ANDROID,
    GOOGLE_CLIENT_ID_WEB,
)

from db.db import get_db
from db.models import User

from models.auth import (
    LoginRequest,
    SignUpRequest,
    TokenResponse,
    GoogleLoginRequest, TokenRequest
)
from utils.security import (
    verify_password,
    get_password_hash,
    create_access_token,
)
from utils.validate_current_user import get_current_user

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

    #generate tokens
    access_token = create_access_token(subject=str(new_user.id))
    refresh_token = generate_refresh_token()
    refresh_token_expiry = generate_refresh_token_expiry()

    #save the refresh token to the database
    new_user.refresh_token = refresh_token
    new_user.refresh_token_expiry = refresh_token_expiry
    db.commit()

    return TokenResponse(
        access_token=access_token, refresh_token=refresh_token
    )

@auth_router.post("/login", response_model=TokenResponse)
def login(request: LoginRequest, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == request.email).first()
    if not user or not verify_password(request.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
        )

    #generates tokens
    access_token = create_access_token(subject=str(user.id)) #access token
    refresh_token = generate_refresh_token() #refresh token
    refresh_token_expiry = generate_refresh_token_expiry() #refresh token expiry

    #save the refresh token to the database
    user.refresh_token = refresh_token
    user.refresh_token_expiry = refresh_token_expiry
    db.commit()

    return TokenResponse(access_token=access_token,
                         refresh_token=refresh_token)

@auth_router.post("/google_login", response_model=TokenResponse)
def google_login(request: GoogleLoginRequest, db: Session = Depends(get_db)):
    token = request.token
    platform = request.platform

    if platform == "ios":
        client_id = GOOGLE_CLIENT_ID_IOS
    elif platform == "android":
        client_id = GOOGLE_CLIENT_ID_ANDROID
    elif platform == "web":
        client_id = GOOGLE_CLIENT_ID_WEB
    else:
        raise HTTPException(status_code=400, detail="Invalid platform")

    token_info = verify_google_token(token, client_id)
    if not token_info:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid Google token",
        )

    # check if user already exists
    email = token_info.get("email")
    google_id = token_info.get("sub")
    name = token_info.get("name")
    user = db.query(User).filter(User.google_id == google_id).first()

    # if user does not exist, create a new user
    if not user:
        user = User(name=name, email=email, google_id=google_id)
        db.add(user)
        db.commit()
        db.refresh(user)

    #generates tokens
    access_token = create_access_token(subject=str(user.id)) #access token
    refresh_token = generate_refresh_token() #refresh token
    refresh_token_expiry = generate_refresh_token_expiry()

    #save the refresh token to the database
    user.refresh_token = refresh_token
    user.refresh_token_expiry = refresh_token_expiry
    db.commit()

    return TokenResponse(access_token=access_token,
                         refresh_token=refresh_token)

@auth_router.post("/refresh_token", response_model=TokenResponse)
def refresh_token(request: TokenRequest, db: Session = Depends(get_db)):
    refresh_token = request.refresh_token
    print(f"Received refresh_token: {refresh_token}")

    # Check if the refresh token exists in the database
    user = db.query(User).filter(User.refresh_token == refresh_token).first()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid refresh token",
        )

    print(f"User found: {user}")

    # Generate a new access token (keep the same refresh token)
    new_access_token = create_access_token(subject=str(user.id))

    print(f"Returning new access token: {new_access_token}")
    return TokenResponse(
        access_token=new_access_token,
        refresh_token=refresh_token,  # Return the same refresh token
    )


@auth_router.delete("/delete-account", status_code=status.HTTP_200_OK)
def delete_account(db: Session = Depends(get_db),user_id: str = Depends(get_current_user),):
    # Retrieve the user
    user = db.query(User).filter(User.id == user_id).first()

    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    # Revoke the refresh token
    user.refresh_token = None

    # Delete the user from the database
    db.delete(user)
    db.commit()

    return {"message": "Account deleted successfully"}
