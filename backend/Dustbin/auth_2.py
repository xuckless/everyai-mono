# from passlib.context import CryptContext
# import jwt
# from datetime import datetime, timedelta
#
# # Setup bcrypt
# pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
#
# # JWT secret and settings
# SECRET_KEY = "sV5Inc7kLnnVrP3X0e-lbJDMbzvDAhBrkZzO2XB9VJ8"
# ALGORITHM = "HS256"
# ACCESS_TOKEN_EXPIRE_MINUTES = 30
#
# # Hash password
# def hash_password(password: str) -> str:
#     return pwd_context.hash(password)
#
# # Verify password
# def verify_password(plain_password: str, hashed_password: str) -> bool:
#     return pwd_context.verify(plain_password, hashed_password)
#
# # Create access token
# def create_access_token(data: dict) -> str:
#     to_encode = data.copy()
#     expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
#     to_encode.update({"exp": expire})
#     return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
