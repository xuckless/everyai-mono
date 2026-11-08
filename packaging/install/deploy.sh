#!/usr/bin/env bash
# Deploys get.everyai.dev (worker `everyai-get`) with wrangler. Needs `wrangler login` on the owner's Cloudflare account.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cp "$HERE/../linux/everyai-release-key.asc" "$HERE/public/key.asc"
ICONS="$HERE/../../frontend/linux/icons/hicolor"
cp "$ICONS/256x256/apps/everyai.png" "$HERE/public/icon-256.png"
cp "$ICONS/scalable/apps/everyai.svg" "$HERE/public/icon.svg"
sh -n "$HERE/public/install.sh"
cd "$HERE" && wrangler deploy "$@"
