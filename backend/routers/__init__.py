from fastapi.security import OAuth2PasswordBearer


OAUTH2_SCHEME = OAuth2PasswordBearer(tokenUrl="/auth/login")
PROTECTED_ROUTE='/p'