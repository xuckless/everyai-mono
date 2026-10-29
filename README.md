# EveryAI

Every AI model in one app. EveryAI is a cross-platform chat client (iOS, Android, macOS, Windows, Linux, Web) for ChatGPT, Claude, Gemini, Grok, LLaMA and Stability, backed by a FastAPI service.

## Repository

| Path        | What                                   | Toolchain          |
|-------------|----------------------------------------|--------------------|
| `frontend/` | Flutter app                            | Flutter (stable)   |
| `backend/`  | FastAPI API, auth, provider proxying   | Python + [uv](https://docs.astral.sh/uv/) |
| `docs/`     | Roadmap and design notes               |                    |

## Quick start

```sh
# Backend
cp .env.example .env          # fill in keys
cd backend && uv sync && uv run uvicorn main:app --reload

# Frontend
cd frontend && flutter pub get && flutter run
```

See [`backend/README.md`](backend/README.md) and [`frontend/README.md`](frontend/README.md) for details.

## Configuration

- **Backend secrets**: one `.env` at the repo root (template: `.env.example`). Never commit it.
- **Firebase / Google Sign-In files** (`GoogleService-Info.plist`, `google-services.json`) are gitignored. Drop them into the platform folders locally.

## License

Proprietary. See [LICENCE.md](LICENCE.md).
