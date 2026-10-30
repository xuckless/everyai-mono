#!/bin/bash
# Xcode build phase (Runner): copies the OpenHands agent-server that
# tool/fetch_agent_server.sh downloaded into EveryAI.app/Contents/Resources,
# where the sidecar looks first, with its license and our notices.
#
# Without a downloaded binary the build goes on (the app then falls back to
# AGENT_SERVER_BIN or app support bin/), unless EVERYAI_REQUIRE_AGENT_SERVER=1
# or the configuration is Release, where it is fetched first.
set -euo pipefail

FRONTEND="${PROJECT_DIR:?run from Xcode}/.."
SRC="$FRONTEND/.agent-server/agent-server"
DEST="${BUILT_PRODUCTS_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Resources"

if [[ ! -x "$SRC" && ( "${CONFIGURATION:-}" == Release || "${EVERYAI_REQUIRE_AGENT_SERVER:-}" == 1 ) ]]; then
  "$FRONTEND/tool/fetch_agent_server.sh" >/dev/null
fi
if [[ ! -x "$SRC" ]]; then
  echo "warning: agent-server not bundled (run frontend/tool/fetch_agent_server.sh); the Code workspace needs it."
  exit 0
fi

mkdir -p "$DEST"
# Only when it changed: the binary is ~100 MB.
if ! cmp -s "$SRC" "$DEST/agent-server"; then
  cp -f "$SRC" "$DEST/agent-server"
  chmod 755 "$DEST/agent-server"
fi
cp -f "$FRONTEND/tool/agent-server-LICENSE" "$DEST/agent-server-LICENSE"
cp -f "$FRONTEND/../THIRD_PARTY_NOTICES.md" "$DEST/THIRD_PARTY_NOTICES.md"

# Sign it like the app, so a signed build launches it. PyInstaller unpacks
# and loads its own libraries, which the hardened runtime needs allowed.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "$IDENTITY" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DEST/agent-server"
  else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
      --entitlements "$PROJECT_DIR/scripts/agent_server.entitlements" "$DEST/agent-server"
  fi
fi
