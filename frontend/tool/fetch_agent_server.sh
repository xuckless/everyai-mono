#!/usr/bin/env bash
# Downloads the pinned OpenHands agent-server for this machine into
# frontend/.agent-server/ and checks it against the release's SHA256SUMS.
set -euo pipefail
VERSION="${AGENT_SERVER_VERSION:-1.59.0}"
DIR="$(cd "$(dirname "$0")/.." && pwd)/.agent-server"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) ASSET="agent-server-$VERSION-macos-arm64" ;;
  Darwin-x86_64) ASSET="agent-server-$VERSION-macos-x86_64" ;;
  Linux-aarch64 | Linux-arm64) ASSET="agent-server-$VERSION-linux-arm64" ;;
  Linux-x86_64) ASSET="agent-server-$VERSION-linux-x86_64" ;;
  *) echo "No agent-server build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
BIN="$DIR/agent-server"
if [[ -x "$BIN" && -f "$DIR/VERSION" && "$(cat "$DIR/VERSION")" == "$VERSION" ]]; then
  echo "$BIN"; exit 0
fi
mkdir -p "$DIR"
BASE="https://github.com/OpenHands/software-agent-sdk/releases/download/v$VERSION"
curl -fsSL -o "$DIR/SHA256SUMS" "$BASE/SHA256SUMS"
curl -fL --progress-bar -o "$DIR/$ASSET" "$BASE/$ASSET"
WANT="$(grep " \*\?$ASSET\$" "$DIR/SHA256SUMS" | awk '{print $1}')"
GOT="$(shasum -a 256 "$DIR/$ASSET" | awk '{print $1}')"
if [[ -z "$WANT" || "$WANT" != "$GOT" ]]; then
  echo "Checksum mismatch for $ASSET (want $WANT, got $GOT)" >&2; rm -f "$DIR/$ASSET"; exit 1
fi
mv "$DIR/$ASSET" "$BIN"; chmod +x "$BIN"
[[ "$(uname -s)" == Darwin ]] && xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
echo "$VERSION" > "$DIR/VERSION"
echo "$BIN"
