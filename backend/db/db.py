from sqlalchemy import create_engine, MetaData
from sqlalchemy.orm import sessionmaker

DATABASE_URL = "postgresql://postgres.vlozlvclzjfwakuptfqr:fozfik-xothyn-9woNmy@aws-0-us-west-1.pooler.supabase.com:6543/postgres"

# Create the database engine
engine = create_engine(DATABASE_URL)

# Create MetaData instance
metadata = MetaData()

# Create a session factory
SessionLocal = sessionmaker(bind=engine)

# Dependency to get the database session
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
