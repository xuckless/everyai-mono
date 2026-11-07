#!/usr/bin/env bash
# Builds everyai-ax, the macOS desktop-window helper (tool/ax_helper/main.swift), into frontend/.tools/ for
# development and tests (the app finds it there; release builds compile it into the bundle:
# macos/scripts/bundle_ax_helper.sh). Prints the binary's path.
set -euo pipefail
cd "$(dirname "$0")/.."
out=.tools/everyai-ax
mkdir -p .tools
if [[ ! -x "$out" || tool/ax_helper/main.swift -nt "$out" ]]; then
  swiftc -O -o "$out" tool/ax_helper/main.swift
fi
echo "$PWD/$out"
