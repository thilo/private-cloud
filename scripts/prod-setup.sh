#!/usr/bin/env bash
# One-time (idempotent) host preparation for the PRODUCTION server. Run as root
# on the server, from the deployed repo directory, AFTER .env.production exists:
#
#   source scripts/prod.env
#   sudo -E ./scripts/prod-setup.sh
#
# It:
#   1. installs cifs-utils (needed to mount the Storage Box over SMB/CIFS),
#   2. adds a 2 GB swap file if the host has none (safety net on a 4 GB box),
#   3. creates the per-volume directories on the attached volume (${DATA_ROOT}),
#   4. creates + validates the immich/ and seafile/ subfolders on the Storage Box
#      (a CIFS mount of a missing subpath fails, so they must exist first).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . "${ENV_FILE:-.env.production}"; set +a

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo -E $0)." >&2; exit 1; fi

echo "==> [1/4] cifs-utils + sqlite3 (sqlite3 = consistent Vaultwarden backups)"
need=()
command -v mount.cifs >/dev/null 2>&1 || need+=(cifs-utils)
command -v sqlite3   >/dev/null 2>&1 || need+=(sqlite3)
if [[ ${#need[@]} -eq 0 ]]; then
  echo "    already installed."
else
  apt-get update -qq && apt-get install -y -qq "${need[@]}"
  echo "    installed: ${need[*]}"
fi

echo "==> [2/4] swap"
if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  echo "    swap already active — leaving as is."
else
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "    created /swapfile (2G) and enabled it."
fi

echo "==> [3/4] data directories on the attached volume (${DATA_ROOT})"
for d in caddy_data caddy_config vaultwarden_data immich_db immich_modelcache \
         immich_thumbs immich_encoded seafile_db seafile_data; do
  mkdir -p "${DATA_ROOT}/${d}"
done
echo "    created: ${DATA_ROOT}/{caddy_data,caddy_config,vaultwarden_data,immich_db,immich_modelcache,immich_thumbs,immich_encoded,seafile_db,seafile_data}"

echo "==> [4/4] Storage Box subfolders (//${SB_HOST}/${SB_SHARE}/{immich,seafile})"
if [[ -z "${SB_PASSWORD:-}" || "$SB_PASSWORD" == "CHANGEME" ]]; then
  echo "    SB_PASSWORD is not set in ${ENV_FILE:-.env.production} — skipping." >&2
  exit 1
fi
tmpmnt="$(mktemp -d)"
trap 'umount "$tmpmnt" 2>/dev/null || true; rmdir "$tmpmnt" 2>/dev/null || true' EXIT
mount -t cifs "//${SB_HOST}/${SB_SHARE}" "$tmpmnt" \
  -o "username=${SB_USER},password=${SB_PASSWORD},vers=${SB_SMB_VERS}"
mkdir -p "$tmpmnt/immich" "$tmpmnt/seafile"
echo "    Storage Box reachable; immich/ and seafile/ present."

echo
echo "Host prepared. Next:  source scripts/prod.env && docker compose up -d"
