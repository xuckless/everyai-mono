# # ./routers/protected.py
#
# from fastapi import APIRouter, Depends, HTTPException, status
# from fastapi.security import OAuth2PasswordBearer
# import jwt
#
# # JWT configuration (reuse from your auth setup)
# SECRET_KEY = "sV5Inc7kLnnVrP3X0e-lbJDMbzvDAhBrkZzO2XB9VJ8"
# ALGORITHM = "HS256"
# oauth2_scheme = OAuth2PasswordBearer(tokenUrl="login")
#
# # Helper function to get the current user
# def get_current_user(token: str = Depends(oauth2_scheme)):
#     try:
#         payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
#         user_id = payload.get("sub")
#         if not user_id:
#             raise HTTPException(
#                 status_code=status.HTTP_401_UNAUTHORIZED,
#                 detail="Invalid authentication credentials",
#             )
#         return user_id
#     except jwt.ExpiredSignatureError:
#         raise HTTPException(
#             status_code=status.HTTP_401_UNAUTHORIZED,
#             detail="Token has expired",
#         )
#     except jwt.InvalidTokenError:
#         raise HTTPException(
#             status_code=status.HTTP_401_UNAUTHORIZED,
#             detail="Invalid authentication credentials",
#         )
#
# # Create the router
# protected_router = APIRouter()
#
# @protected_router.get("/protected")
# def protected_route(current_user: str = Depends(get_current_user)):
#     return {"message": f"Hello, user {current_user}"}
