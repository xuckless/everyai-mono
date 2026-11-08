#!/usr/bin/env bash
# Builds and (re)starts the dev backend on the VM. Cross-compiles with Zig here,
# sends only the binary, the Dockerfile and the compose file, and builds the
# image on the VM (no local Docker needed; no .env or key leaves this machine).
# Usage: backend-exp/deploy/deploy.sh
#   EVERYAI_INGRESS=tunnel EVERYAI_HOSTNAME=api.everyai.dev backend-exp/deploy/deploy.sh
#     serves through the Cloudflare Tunnel (docker-compose.tunnel.yml; TUNNEL_TOKEN in tunnel.env)
#     instead of Anole's own TLS on :8443.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vm="${EVERYAI_VM:-ttt-server}"
zone="${EVERYAI_ZONE:-us-east1-b}"
project="${EVERYAI_PROJECT:-ttt-ultimate-b7097a}"
host="${EVERYAI_HOSTNAME:-everyai.136-108-68-64.sslip.io}"
tag="everyai-backend:0.1.0-dev-nonsigned"
ingress="${EVERYAI_INGRESS:-tls}"
case "$ingress" in tls|tunnel) ;; *) echo "EVERYAI_INGRESS is tls or tunnel" >&2; exit 64 ;; esac

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
(cd "$here/.." && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix "$out")
cp "$out/bin/everyai-backend-exp" "$here/Dockerfile" "$here/docker-compose.yml" "$here/docker-compose.tunnel.yml" \
  "$here/everyai-cert-reload.service" "$here/everyai-cert-reload.timer" "$out/"
printf 'HOSTNAME=%s\n' "$host" >"$out/.env"

ssh_vm() { gcloud compute ssh "$vm" --zone "$zone" --project "$project" --command "$1"; }
# Production config needs its secrets on the VM first (set-secrets.sh).
ssh_vm 'test -s /opt/everyai/secrets.env' || { echo "no /opt/everyai/secrets.env on the VM: run deploy/set-secrets.sh first" >&2; exit 1; }
if [ "$ingress" = tunnel ]; then
  ssh_vm 'sudo grep -q "^TUNNEL_TOKEN=." /opt/everyai/tunnel.env' ||
    { echo "no TUNNEL_TOKEN in /opt/everyai/tunnel.env: put TUNNEL_TOKEN=… in the root .env and run deploy/set-secrets.sh first" >&2; exit 1; }
  files="-f docker-compose.yml -f docker-compose.tunnel.yml"
else
  files="-f docker-compose.yml"
fi
ssh_vm 'rm -rf /tmp/everyai-build && mkdir -p /tmp/everyai-build'
gcloud compute scp --zone "$zone" --project "$project" \
  "$out/everyai-backend-exp" "$out/Dockerfile" "$out/docker-compose.yml" "$out/docker-compose.tunnel.yml" "$out/.env" \
  "$out/everyai-cert-reload.service" "$out/everyai-cert-reload.timer" "$vm:/tmp/everyai-build/"
ssh_vm "set -e
cd /tmp/everyai-build
sudo docker build -t $tag -f Dockerfile .
sudo mkdir -p /opt/everyai
sudo cp docker-compose.yml docker-compose.tunnel.yml .env /opt/everyai/
if [ $ingress = tls ]; then
  sudo cp everyai-cert-reload.service everyai-cert-reload.timer /etc/systemd/system/
  sudo systemctl daemon-reload && sudo systemctl enable --now everyai-cert-reload.timer
fi
cd /opt/everyai && sudo docker compose $files up -d --force-recreate --remove-orphans
rm -rf /tmp/everyai-build"
if [ "$ingress" = tunnel ]; then echo "deployed: https://$host (Cloudflare Tunnel)"; else echo "deployed: https://$host:8443"; fi
