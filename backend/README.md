# EveryAI backend

FastAPI service that authenticates EveryAI users and proxies chat requests to model providers (OpenAI, Anthropic, Google Gemini, xAI, Stability).

## Layout

```
backend/
├── main.py            FastAPI app, CORS, router registration
├── config.py          Settings loaded from the repo-root .env
├── routers/           auth_router (/signup, /login, /google_login, /refresh_token, /delete-account)
│                      chat_router (/chat, /ping), gpt_router (/chat/{gpt,gemini,llama,xai,claude,stability})
│                      protected_router (/p)
├── models/            Pydantic request/response models
├── db/                SQLAlchemy engine and ORM models
├── utils/             security (JWT, bcrypt, Google token verification), helpers
└── alembic/           Database migrations
```

## Setup

Requires [uv](https://docs.astral.sh/uv/). uv installs the pinned Python (`.python-version`) and the locked dependencies (`uv.lock`).

```sh
cp ../.env.example ../.env   # once; fill in the values
uv sync
```

The environment file lives at the **repo root**. `config.py` finds it by searching upward from `backend/`.

## Run

```sh
uv run uvicorn main:app --reload            # http://127.0.0.1:8000 (Android emulator: http://10.0.2.2:8000)
uv run uvicorn main:app --reload --host 0.0.0.0   # reachable from devices on the LAN
```

API docs: http://127.0.0.1:8000/docs (Swagger) and http://127.0.0.1:8000/redoc.

## Database migrations

```sh
uv run alembic revision --autogenerate -m "Describe your change"
uv run alembic upgrade head
```

`alembic/env.py` takes the database URL from `DATABASE_URL`; the URL in `alembic.ini` is only a placeholder.

## Dependencies

```sh
uv add <package>          # runtime dependency
uv add --dev <package>    # dev-only (tests, tooling)
uv lock --upgrade         # refresh the lockfile
```

## Tests

`test.py` contains integration tests that call a running server on `127.0.0.1:8000`:

```sh
uv run uvicorn main:app &   # in another terminal
uv run pytest test.py
```
