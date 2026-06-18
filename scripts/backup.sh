#!/usr/bin/env bash
# Consistent backup of the latency-sensitive (attached-volume) state to the
# Storage Box. The bulk blobs (Immich originals, Seafile object store) already
# live on the box, so they are NOT copied here — enable the box's automatic
# snapshots and they are protected in place. Likewise, this script overwrites a
# single "latest" set under backup/backups/ and relies on those free, automatic
# Storage Box snapshots for dated history rather than keeping its own rotation.
#
# What it captures (all online-consistent, safe to run live):
#   - Immich Postgres      -> pg_dump (immich db), gzip
#   - Seafile MariaDB       -> mariadb-dump --single-transaction of all 3 DBs, gzip
#   - Vaultwarden           -> SQLite .backup (consistent) + data folder, tar.gz
#   - Caddy TLS material    -> tar.gz (so a restore doesn't re-hit Let's Encrypt)
# Each artifact is written to a .partial file, verified, then atomically renamed,
# so a snapshot taken mid-run never captures a half-written file. A manifest with
# sizes + sha256 is written last as the completion marker.
#
# Run:        source scripts/prod.env && sudo -E ./scripts/backup.sh
# Scheduled:  installed as a daily systemd timer (scripts/systemd/pc-backup.*).
#
# RESTORE: use scripts/restore.sh (run `restore.sh --check` first to verify the
# latest backup is intact and restorable without changing anything).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . "${ENV_FILE:-.env.production}"; set +a

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo -E $0)." >&2; exit 1; fi

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

for v in DATA_ROOT SB_HOST SB_SHARE SB_USER SB_PASSWORD SB_SMB_VERS \
         IMMICH_DB_USER IMMICH_DB_NAME SEAFILE_DB_ROOT_PASSWORD; do
  [[ -n "${!v:-}" && "${!v}" != "CHANGEME" ]] || fail "$v is not set in ${ENV_FILE:-.env.production}"
done

# Containers must be running for the online dumps.
for c in pc-immich-db pc-seafile-db pc-vaultwarden; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]] || fail "$c is not running"
done

# Mount the Storage Box share on the host for the duration of the backup.
MNT="$(mktemp -d)"
WORK="$(mktemp -d)"
cleanup() {
  umount "$MNT" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
log "mounting //${SB_HOST}/${SB_SHARE} ..."
mount -t cifs "//${SB_HOST}/${SB_SHARE}" "$MNT" \
  -o "username=${SB_USER},password=${SB_PASSWORD},vers=${SB_SMB_VERS},uid=0,gid=0,file_mode=0600,dir_mode=0700,seal" \
  || fail "could not mount the Storage Box"
DEST="$MNT/backups"
mkdir -p "$DEST"

# Stream a producer command to a gzip'd .partial, verify it, then atomically
# rename over the live file. $1=final filename, rest=command to run.
put_gz() {
  local name="$1"; shift
  local tmp="$DEST/.$name.partial"
  log "dumping $name ..."
  if ! { "$@" | gzip -9 > "$tmp"; }; then rm -f "$tmp"; fail "$name: dump command failed"; fi
  gzip -t "$tmp" 2>/dev/null || { rm -f "$tmp"; fail "$name: gzip verification failed"; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "$name: produced an empty dump"; }
  mv -f "$tmp" "$DEST/$name"
}

# 1. Immich Postgres — plain SQL, no owner/privs (restores cleanly into a fresh immich db).
put_gz immich-db.sql.gz \
  docker exec pc-immich-db pg_dump -U "$IMMICH_DB_USER" -d "$IMMICH_DB_NAME" --no-owner --no-privileges

# 2. Seafile MariaDB — all three databases, transaction-consistent.
put_gz seafile-db.sql.gz \
  docker exec -e MYSQL_PWD="$SEAFILE_DB_ROOT_PASSWORD" pc-seafile-db \
  mariadb-dump -u root --single-transaction --routines --events \
  --databases ccnet_db seafile_db seahub_db

# 3. Vaultwarden — consistent SQLite snapshot + the rest of the data folder.
log "dumping vaultwarden.tar.gz ..."
VW="$DATA_ROOT/vaultwarden_data"
stage="$WORK/vaultwarden_data"; mkdir -p "$stage"
# Copy everything except the live sqlite files...
( cd "$VW" && tar cf - --exclude='db.sqlite3*' . ) | ( cd "$stage" && tar xf - )
# ...then add a consistent copy of the DB (online backup API if sqlite3 is present).
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$VW/db.sqlite3" ".backup '$stage/db.sqlite3'" || fail "vaultwarden: sqlite .backup failed"
else
  log "WARN: sqlite3 not installed — copying db.sqlite3* as-is (install sqlite3 for a consistent snapshot)"
  cp -a "$VW"/db.sqlite3* "$stage"/ 2>/dev/null || true
fi
vwtmp="$DEST/.vaultwarden.tar.gz.partial"
tar czf "$vwtmp" -C "$stage" . || { rm -f "$vwtmp"; fail "vaultwarden: tar failed"; }
gzip -t "$vwtmp" 2>/dev/null || { rm -f "$vwtmp"; fail "vaultwarden: gzip verification failed"; }
mv -f "$vwtmp" "$DEST/vaultwarden.tar.gz"

# 4. Caddy TLS material (certs/keys) — small; spares a Let's Encrypt re-issue on restore.
catmp="$DEST/.caddy_data.tar.gz.partial"
tar czf "$catmp" -C "$DATA_ROOT/caddy_data" . || { rm -f "$catmp"; fail "caddy: tar failed"; }
gzip -t "$catmp" 2>/dev/null || { rm -f "$catmp"; fail "caddy: gzip verification failed"; }
mv -f "$catmp" "$DEST/caddy_data.tar.gz"

# Manifest, written last = the completion marker.
{
  echo "private-cloud backup"
  echo "host:    $(hostname)"
  echo "date:    $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo
  ( cd "$DEST" && ls -l immich-db.sql.gz seafile-db.sql.gz vaultwarden.tar.gz caddy_data.tar.gz )
  echo
  ( cd "$DEST" && sha256sum immich-db.sql.gz seafile-db.sql.gz vaultwarden.tar.gz caddy_data.tar.gz )
} > "$DEST/backup-manifest.txt"

log "backup complete -> //${SB_HOST}/${SB_SHARE}/backups/"
( cd "$DEST" && du -h immich-db.sql.gz seafile-db.sql.gz vaultwarden.tar.gz caddy_data.tar.gz ) | sed 's/^/  /'
