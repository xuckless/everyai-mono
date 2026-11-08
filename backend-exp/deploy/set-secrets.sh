#!/usr/bin/env bash
# Writes /opt/everyai/secrets.env on the VM (root-only, 0600): a new random
# JWT_SECRET (only when none is there yet, so sessions survive redeploys) and
# RESEND_API_KEY from the repo-root .env. Values go over ssh stdin, never as
# command-line arguments or into the image.
# Usage: backend-exp/deploy/set-secrets.sh   (run once, and after a key change)
#   With TUNNEL_TOKEN=… in the root .env (or EVERYAI_TUNNEL_TOKEN set), also stores the Cloudflare Tunnel token
#   (kept on later runs that don't pass one).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="${EVERYAI_VM:-ttt-server}"
zone="${EVERYAI_ZONE:-us-east1-b}"
project="${EVERYAI_PROJECT:-ttt-ultimate-b7097a}"
root_env="$here/../../.env"

resend="$(grep -E '^RESEND_API_KEY=' "$root_env" | head -1 | cut -d= -f2- || true)"
[ -n "$resend" ] || { echo "RESEND_API_KEY missing in $root_env" >&2; exit 1; }

# The tunnel token: EVERYAI_TUNNEL_TOKEN, else TUNNEL_TOKEN in the root .env (so it never goes on a command line).
tunnel="${EVERYAI_TUNNEL_TOKEN:-$(grep -E '^TUNNEL_TOKEN=' "$root_env" | head -1 | cut -d= -f2- || true)}"
printf '%s\n%s\n' "$resend" "$tunnel" | gcloud compute ssh "$vm" --zone "$zone" --project "$project" --command '
set -e
read -r resend
read -r tunnel || true
sudo mkdir -p /opt/everyai
f=/opt/everyai/secrets.env
jwt=$(sudo sh -c "grep -E ^JWT_SECRET= $f 2>/dev/null | cut -d= -f2-" || true)
[ -n "$jwt" ] || jwt=$(head -c 48 /dev/urandom | base64 | tr -d "\n/+=" | head -c 64)
[ -n "$tunnel" ] || tunnel=$(sudo sh -c "grep -E ^TUNNEL_TOKEN= $f 2>/dev/null | cut -d= -f2-" || true)
umask 077
{ printf "JWT_SECRET=%s\nRESEND_API_KEY=%s\n" "$jwt" "$resend"; [ -z "$tunnel" ] || printf "TUNNEL_TOKEN=%s\n" "$tunnel"; } | sudo tee "$f" >/dev/null
sudo chmod 600 "$f"
echo "secrets written to $f"'
