#!/usr/bin/env bash
# Writes /opt/everyai/secrets.env on the VM (root-only, 0600): a new random
# JWT_SECRET (only when none is there yet, so sessions survive redeploys) and
# RESEND_API_KEY from the repo-root .env. Values go over ssh stdin, never as
# command-line arguments or into the image.
# Usage: backend-exp/deploy/set-secrets.sh   (run once, and after a key change)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="${EVERYAI_VM:-ttt-server}"
zone="${EVERYAI_ZONE:-us-east1-b}"
project="${EVERYAI_PROJECT:-ttt-ultimate-b7097a}"
root_env="$here/../../.env"

resend="$(grep -E '^RESEND_API_KEY=' "$root_env" | head -1 | cut -d= -f2- || true)"
[ -n "$resend" ] || { echo "RESEND_API_KEY missing in $root_env" >&2; exit 1; }

printf '%s\n' "$resend" | gcloud compute ssh "$vm" --zone "$zone" --project "$project" --command '
set -e
read -r resend
sudo mkdir -p /opt/everyai
f=/opt/everyai/secrets.env
jwt=$(sudo sh -c "grep -E ^JWT_SECRET= $f 2>/dev/null | cut -d= -f2-" || true)
[ -n "$jwt" ] || jwt=$(head -c 48 /dev/urandom | base64 | tr -d "\n/+=" | head -c 64)
umask 077
printf "JWT_SECRET=%s\nRESEND_API_KEY=%s\n" "$jwt" "$resend" | sudo tee "$f" >/dev/null
sudo chmod 600 "$f"
echo "secrets written to $f"'
