#!/bin/bash
# Builds the bundled EveryAI server (backend-exp in local mode, see
# lib/core/local_backend/) into frontend/.local-backend/ and prints its path
# last. Skips the build when backend-exp hasn't changed since the last one.
#   tool/build_local_backend.sh                 # this machine (macOS: arm64 + x86_64 in one file)
#   tool/build_local_backend.sh x86_64-windows  # a zig target triple (cross-compiles)
set -euo pipefail

FRONTEND="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$FRONTEND/../backend-exp"
OUT="$FRONTEND/.local-backend"
TARGET="${1:-}"
mkdir -p "$OUT"

case "$TARGET" in
  *windows*) NAME=everyai-backend.exe ;;
  *) NAME=everyai-backend ;;
esac
[[ -z "$TARGET" && "$(uname -s)" == MINGW* ]] && NAME=everyai-backend.exe

# What the build depends on: the sources and the zig version.
sum() { if command -v shasum >/dev/null; then shasum; else sha1sum; fi; }
STAMP="$( (cd "$BACKEND" && find src build.zig build.zig.zon -type f -print0 | sort -z | xargs -0 cat) | sum | cut -c1-16)-$(zig version)-${TARGET:-host}"
if [[ -x "$OUT/$NAME" && "$(cat "$OUT/.stamp-$NAME" 2>/dev/null)" == "$STAMP" ]]; then
  echo "$OUT/$NAME"
  exit 0
fi

build() { # target prefix
  (cd "$BACKEND" && zig build -Doptimize=ReleaseSafe ${1:+-Dtarget="$1"} --prefix "$2" >&2)
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [[ -z "$TARGET" && "$(uname -s)" == Darwin ]]; then
  build aarch64-macos.13.0 "$TMP/arm"
  build x86_64-macos.13.0 "$TMP/x86"
  lipo -create "$TMP/arm/bin/everyai-backend-exp" "$TMP/x86/bin/everyai-backend-exp" -output "$OUT/$NAME"
else
  build "$TARGET" "$TMP/out"
  cp -f "$TMP/out/bin/$( [[ $NAME == *.exe ]] && echo everyai-backend-exp.exe || echo everyai-backend-exp)" "$OUT/$NAME"
fi
chmod 755 "$OUT/$NAME"
echo "$STAMP" > "$OUT/.stamp-$NAME"
echo "$OUT/$NAME"
