#!/bin/bash
# Xcode build phase (called from bundle_deno.sh): compiles everyai-ax, the desktop-window helper the app tool and
# the Preview run (tool/ax_helper/main.swift, see desktop_window_io.dart axHelperPath), into
# EveryAI.app/Contents/Resources and signs it like the app.
set -euo pipefail

FRONTEND="${PROJECT_DIR:?run from Xcode}/.."
DEST="${BUILT_PRODUCTS_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Resources"
mkdir -p "$DEST"
SRC="$FRONTEND/tool/ax_helper/main.swift"
if [[ ! -x "$DEST/everyai-ax" || "$SRC" -nt "$DEST/everyai-ax" ]]; then
  xcrun swiftc -O -target "$(uname -m)-apple-macos${MACOSX_DEPLOYMENT_TARGET:-14.0}" -o "$DEST/everyai-ax" "$SRC"
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "$IDENTITY" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DEST/everyai-ax"
  else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DEST/everyai-ax"
  fi
fi
