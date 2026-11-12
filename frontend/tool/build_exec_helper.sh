#!/usr/bin/env bash
# Builds everyai-exec, the launcher that gives each child a session of its own (tool/exec_helper/main.c), into
# frontend/.tools/ for development and tests (the supervisor finds it there; macOS release builds compile it into
# the bundle: macos/scripts/bundle_exec_helper.sh). Prints the binary's path.
set -euo pipefail
cd "$(dirname "$0")/.."
out=.tools/everyai-exec
mkdir -p .tools
if [[ ! -x "$out" || tool/exec_helper/main.c -nt "$out" ]]; then
  cc -O2 -Wall -o "$out" tool/exec_helper/main.c
fi
echo "$PWD/$out"
