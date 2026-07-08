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
#      (a CIFS mount of a missing subpath fails, so they must exist first),
#   5. enables zswap (compresses swap pages in RAM before hitting the swapfile,
#      cutting disk I/O under memory pressure; persisted via GRUB cmdline),
#   6. writes /etc/docker/daemon.json for log rotation (requires a one-time
#      Docker daemon restart: systemctl restart docker),
#   7. installs + enables the systemd timers (daily backup + mount watchdog).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . "${ENV_FILE:-.env.production}"; set +a

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo -E $0)." >&2; exit 1; fi

echo "==> [1/7] cifs-utils + sqlite3 (sqlite3 = consistent Vaultwarden backups)"
need=()
command -v mount.cifs >/dev/null 2>&1 || need+=(cifs-utils)
command -v sqlite3   >/dev/null 2>&1 || need+=(sqlite3)
if [[ ${#need[@]} -eq 0 ]]; then
  echo "    already installed."
else
  apt-get update -qq && apt-get install -y -qq "${need[@]}"
  echo "    installed: ${need[*]}"
fi

echo "==> [2/7] swap"
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

echo "==> [3/7] data directories on the attached volume (${DATA_ROOT})"
for d in caddy_data caddy_config vaultwarden_data immich_db immich_modelcache \
         immich_thumbs immich_encoded seafile_db seafile_data; do
  mkdir -p "${DATA_ROOT}/${d}"
done
echo "    created: ${DATA_ROOT}/{caddy_data,caddy_config,vaultwarden_data,immich_db,immich_modelcache,immich_thumbs,immich_encoded,seafile_db,seafile_data}"

echo "==> [4/7] Storage Box subfolders (//${SB_HOST}/${SB_SHARE}/{immich,seafile})"
if [[ -z "${SB_PASSWORD:-}" || "$SB_PASSWORD" == "CHANGEME" ]]; then
  echo "    SB_PASSWORD is not set in ${ENV_FILE:-.env.production} — skipping." >&2
  exit 1
fi
tmpmnt="$(mktemp -d)"
trap 'umount "$tmpmnt" 2>/dev/null || true; rmdir "$tmpmnt" 2>/dev/null || true' EXIT
mount -t cifs "//${SB_HOST}/${SB_SHARE}" "$tmpmnt" \
  -o "username=${SB_USER},password=${SB_PASSWORD},vers=${SB_SMB_VERS},seal"
mkdir -p "$tmpmnt/immich" "$tmpmnt/seafile"
echo "    Storage Box reachable; immich/ and seafile/ present."

echo "==> [5/7] zswap (compress swap pages in RAM, reduce swapfile I/O)"
if [[ "$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)" == "Y" ]]; then
  echo "    zswap already enabled."
else
  echo Y > /sys/module/zswap/parameters/enabled
  echo "    zswap enabled for this boot."
fi
if grep -q 'zswap.enabled=1' /etc/default/grub 2>/dev/null; then
  echo "    GRUB already has zswap.enabled=1."
else
  sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 zswap.enabled=1"/' /etc/default/grub
  update-grub 2>&1 | grep -E 'Generating|done|error' || true
  echo "    GRUB updated — zswap will persist across reboots."
fi

echo "==> [6/7] Docker daemon.json (log rotation)"
daemon_json=/etc/docker/daemon.json
if [[ -f "$daemon_json" ]]; then
  echo "    $daemon_json already exists — not overwriting."
else
  printf '{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3"}}\n' > "$daemon_json"
  echo "    written $daemon_json."
  echo "    NOTE: run 'systemctl restart docker' to activate (brief container restart)."
fi

echo "==> [7/7] systemd timers (daily backup + Storage Box mount watchdog)"
# Refreshes the unit files from the repo, so re-running after an update picks up
# any change. enable --now is idempotent.
cp scripts/systemd/pc-backup.* scripts/systemd/pc-mount-watchdog.* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pc-backup.timer pc-mount-watchdog.timer
echo "    installed + enabled: pc-backup.timer, pc-mount-watchdog.timer"

echo
echo "Host prepared. Next:  source scripts/prod.env && docker compose up -d"
