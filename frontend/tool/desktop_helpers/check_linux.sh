#!/usr/bin/env bash
# Dev check of the Linux desktop window helper (assets/helpers/everyai_x11.py) in an Ubuntu 22.04 container with
# Xvfb and a small Tk app: window list, picture, clicks, typing (non-ASCII too), Enter, the wheel, a guard refusal
# and a stream frame. Needs Docker. Prints what the app saw at the end ("pressed", "entry=…", "list=…").
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp app.py linux_check_in_container.sh "$work/"
docker build -q -t everyai-x11check . >/dev/null
docker run --rm -v "$work:/work" -v "$PWD/../../assets/helpers:/helpers:ro" everyai-x11check bash /work/linux_check_in_container.sh
