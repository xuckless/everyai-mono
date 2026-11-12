#!/bin/bash
# Xcode build phase (called from bundle_deno.sh): compiles everyai-exec, the launcher that starts every child in a
# session of its own (tool/exec_helper/main.c, see supervisor_io.dart), into EveryAI.app/Contents/Resources and
# signs it like the app.
set -euo pipefail

FRONTEND="${PROJECT_DIR:?run from Xcode}/.."
DEST="${BUILT_PRODUCTS_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Resources"
mkdir -p "$DEST"
SRC="$FRONTEND/tool/exec_helper/main.c"
if [[ ! -x "$DEST/everyai-exec" || "$SRC" -nt "$DEST/everyai-exec" ]]; then
  xcrun clang -O2 -arch arm64 -arch x86_64 -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -o "$DEST/everyai-exec" "$SRC"
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "$IDENTITY" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DEST/everyai-exec"
  else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DEST/everyai-exec"
  fi
fi
