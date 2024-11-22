from fastapi import APIRouter, Depends
from db.models import User
from utils.validate_current_user import get_current_user


protected_router = APIRouter(prefix="/p", tags=["Protected"])



@protected_router.get("")
def protected_route(current_user: User = Depends(get_current_user)):
    return {"message": f"Hello, {current_user.email}"}