#!/usr/bin/env bash
# A 2 GB swapfile on the VM (e2-micro has 1 GB of RAM). Idempotent: a second
# run changes nothing. Run it on the VM, e.g.
#   gcloud compute ssh ttt-server --zone us-east1-b --command 'sudo bash -s' < backend-exp/deploy/swap.sh
set -euo pipefail
SWAP=/swapfile
SIZE_MB=${SWAP_MB:-2048}
if [ "$(id -u)" -ne 0 ]; then echo "run as root (sudo bash -s)" >&2; exit 1; fi
if swapon --show=NAME --noheadings | grep -qx "$SWAP"; then
  echo "swap already on: $(swapon --show --noheadings)"
  exit 0
fi
if [ ! -f "$SWAP" ]; then
  fallocate -l "${SIZE_MB}M" "$SWAP" || dd if=/dev/zero of="$SWAP" bs=1M count="$SIZE_MB"
  chmod 600 "$SWAP"
  mkswap "$SWAP"
fi
swapon "$SWAP"
grep -q "^$SWAP " /etc/fstab || echo "$SWAP none swap sw 0 0" >> /etc/fstab
# Swap only under pressure: the backend and ttt stay in RAM.
sysctl -q vm.swappiness=10
grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
echo "swap on: $(swapon --show --noheadings)"
