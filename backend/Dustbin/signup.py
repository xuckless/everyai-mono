# from fastapi import APIRouter, Depends, HTTPException
# from sqlalchemy.orm import Session
# from pydantic import BaseModel, EmailStr
#
# from db.db import get_db
# from db.models import User
# from passlib.context import CryptContext
#
# # Initialize bcrypt for password hashing
# pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
#
# # Create APIRouter instance
# signup_router = APIRouter()
#
# # Pydantic model for request body
# class SignUpRequest(BaseModel):
#     email: EmailStr
#     password: str
#
# # Utility function to hash passwords
# def hash_password(password: str) -> str:
#     return pwd_context.hash(password)
#
# # Signup route
# @signup_router.post("/signup")
# def signup(request: SignUpRequest, db: Session = Depends(get_db)):
#     # Check if email already exists
#     user = db.query(User).filter(User.email == request.email).first()
#     if user:
#         raise HTTPException(status_code=400, detail="Email already registered")
#
#     # Hash password and create user
#     hashed_password = hash_password(request.password)
#     new_user = User(email=request.email, password_hash=hashed_password)
#     db.add(new_user)
#     db.commit()
#     db.refresh(new_user)
#     return {"message": "User created successfully"}
