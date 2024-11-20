from fastapi import HTTPException, status
from sqlalchemy.orm import Session
from utils.security import verify_google_token

from config import GOOGLE_CLIENT_ID_IOS, GOOGLE_CLIENT_ID_ANDROID
from db.models import User
from models.auth import TokenResponse
from utils.security import (
    create_access_token,
)

def handle_google_login(token: str, platform: str, db: Session) -> TokenResponse:
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

    email = token_info.get("email")
    google_id = token_info.get("sub")
    user = db.query(User).filter(User.google_id == google_id).first()

    if not user:
        user = User(email=email, google_id=google_id)
        db.add(user)
        db.commit()
        db.refresh(user)

    access_token = create_access_token(subject=str(user.id))
    return TokenResponse(access_token=access_token)