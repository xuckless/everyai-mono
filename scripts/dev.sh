#!/usr/bin/env bash
# Runs backend-exp and the Flutter app together.
#
#   scripts/dev.sh                 macOS app (+ the OpenHands agent-server for Code)
#   scripts/dev.sh web             Chrome on http://localhost:5173
#   scripts/dev.sh ios-sim         iOS Simulator (boots one if none is running)
#   scripts/dev.sh ios             the first connected iPhone (backend on the LAN)
#   scripts/dev.sh <device-id>     any `flutter devices` id
#   scripts/dev.sh macos -- --release    extra args after -- go to `flutter run`
#
# A backend already answering on :8080 is reused; otherwise one is started and
# stopped when the app exits. Logs: .dev/backend.log. Backend data:
# backend-exp/data/everyai.db (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONTEND="$ROOT/frontend"
BACKEND="$ROOT/backend-exp"
DEV="$ROOT/.dev"
PORT="${PORT:-8080}"
mkdir -p "$DEV"

TARGET="${1:-macos}"
[[ $# -gt 0 ]] && shift
[[ "${1:-}" == "--" ]] && shift
EXTRA=("$@")

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# --- where the app should find the backend --------------------------------
HOST=127.0.0.1
DEV_AUTH_LAN=false
API="http://localhost:$PORT"
DEVICE=""
case "$TARGET" in
  macos) DEVICE=macos ;;
  web | chrome) DEVICE=chrome ;;
  ios-sim)
    DEVICE="$(xcrun simctl list devices booted -j | python3 -c '
import json,sys
for rt in json.load(sys.stdin)["devices"].values():
    for d in rt:
        if "iPhone" in d["name"] or "iPad" in d["name"]: print(d["udid"]); raise SystemExit' || true)"
    if [[ -z "$DEVICE" ]]; then
      DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
for rt in json.load(sys.stdin)["devices"].values():
    for d in rt:
        if d["name"].startswith("iPhone"): print(d["udid"]); raise SystemExit')"
      [[ -n "$DEVICE" ]] || die "No iPhone simulator installed (Xcode → Settings → Components)."
      say "Booting simulator $DEVICE"
      xcrun simctl boot "$DEVICE"
    fi
    open -a Simulator 2>/dev/null || say "No Simulator.app window on this Xcode; the device runs headless (screenshots: xcrun simctl io booted screenshot x.png)"
    ;;
  ios)
    DEVICE="$(cd "$FRONTEND" && flutter devices --machine 2>/dev/null | python3 -c '
import json,sys
for d in json.load(sys.stdin):
    if d.get("targetPlatform","").startswith("ios") and not d.get("emulator"): print(d["id"]); break')"
    [[ -n "$DEVICE" ]] || die "No iPhone connected (USB or same-Wi-Fi with Developer Mode on)."
    LAN="$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || true)"
    [[ -n "$LAN" ]] || die "No LAN address found for the phone to reach the backend."
    HOST=0.0.0.0
    DEV_AUTH_LAN=true
    API="http://$LAN:$PORT"
    say "Phone talks to the backend at $API (dev auth is open to your LAN while this runs)"
    ;;
  *) DEVICE="$TARGET" ;;
esac

# --- backend --------------------------------------------------------------
BACKEND_PID=""
cleanup() {
  if [[ -n "$BACKEND_PID" ]]; then
    say "Stopping backend"
    kill "$BACKEND_PID" 2>/dev/null || true
    pkill -f everyai-backend-exp 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if curl -sf "$API/healthz" >/dev/null 2>&1; then
  say "Backend already running at $API"
else
  if curl -sf "http://localhost:$PORT/healthz" >/dev/null 2>&1; then
    die "A backend on :$PORT only listens on localhost. Stop it, then rerun (this one binds $HOST)."
  fi
  command -v zig >/dev/null || die "zig 0.17 is not on PATH."
  say "Starting backend-exp on $HOST:$PORT (log: .dev/backend.log)"
  # DEV_AUTH_LAN acknowledges that dev auth is open to the LAN (physical iPhone only).
  (cd "$BACKEND" && HOST="$HOST" DEV_AUTH_LAN="$DEV_AUTH_LAN" PORT="$PORT" exec zig build run) >"$DEV/backend.log" 2>&1 &
  BACKEND_PID=$!
  for _ in $(seq 1 240); do
    curl -sf "$API/healthz" >/dev/null 2>&1 && break
    kill -0 "$BACKEND_PID" 2>/dev/null || { tail -20 "$DEV/backend.log"; die "Backend failed to start."; }
    sleep 0.5
  done
  curl -sf "$API/healthz" >/dev/null || die "Backend didn't come up; see .dev/backend.log."
  say "Backend ready"
fi

# --- app ------------------------------------------------------------------
DEFINES="$DEV/defines-$TARGET.json"
python3 - "$FRONTEND/config/dev.json" "$DEFINES" "$API" <<'PY'
import json, os, sys
src, dst, api = sys.argv[1:]
base = json.load(open(src)) if os.path.exists(src) else {"DEV_SKIP_AUTH": True, "SSE_ENABLED": True}
base["API_BASE_URL"] = api
json.dump(base, open(dst, "w"), indent=2)
PY

ARGS=(-d "$DEVICE" --dart-define-from-file="$DEFINES")
if [[ "$DEVICE" == macos ]]; then
  say "Checking the OpenHands agent-server"
  BIN="$("$FRONTEND/tool/fetch_agent_server.sh" | tail -1)"
  ARGS+=(--dart-define=AGENT_SERVER_BIN="$BIN")
fi
[[ "$DEVICE" == chrome ]] && ARGS+=(--web-port=5173)

say "flutter run ${ARGS[*]} ${EXTRA[*]:-}"
cd "$FRONTEND"
flutter run "${ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"
