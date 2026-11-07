#!/bin/bash
# Xcode build phase (called from bundle_deno.sh, which Runner already runs):
# builds the bundled EveryAI server (tool/build_local_backend.sh; cached) and
# copies it into EveryAI.app/Contents/Resources, where findLocalBackend looks.
set -euo pipefail

FRONTEND="${PROJECT_DIR:?run from Xcode}/.."
DEST="${BUILT_PRODUCTS_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Resources"

if ! command -v zig >/dev/null 2>&1 && [[ ! -x "$FRONTEND/.local-backend/everyai-backend" ]]; then
  echo "warning: zig not found and no prebuilt server: local models and own-key chats will use the deployed server." >&2
  exit 0
fi
SRC="$("$FRONTEND/tool/build_local_backend.sh" | tail -1)"
mkdir -p "$DEST"
if ! cmp -s "$SRC" "$DEST/everyai-backend"; then
  cp -f "$SRC" "$DEST/everyai-backend"
  chmod 755 "$DEST/everyai-backend"
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "$IDENTITY" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DEST/everyai-backend"
  else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DEST/everyai-backend"
  fi
fi
