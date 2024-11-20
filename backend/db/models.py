# db/models.py
from xmlrpc.client import Boolean

from sqlalchemy import Column, String, DateTime, func
from sqlalchemy.ext.declarative import declarative_base
import uuid

Base = declarative_base()

class User(Base):
    __tablename__ = "users"
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    email = Column(String, unique=True, nullable=False)
    password_hash = Column(String, unique=True, nullable=True)
    google_id = Column(String, nullable=True)
    created_at = Column(DateTime, default=func.now())
