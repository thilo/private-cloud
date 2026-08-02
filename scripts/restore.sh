#!/usr/bin/env bash
# Restore the latest backup written by scripts/backup.sh from the Storage Box.
#
#   source scripts/prod.env
#   sudo -E ./scripts/restore.sh --check                 # verify only, no changes
#   sudo -E ./scripts/restore.sh --yes                   # restore EVERYTHING
#   sudo -E ./scripts/restore.sh vaultwarden --yes       # restore one component
#   components: immich | seafile | vaultwarden | caddy | all   (default: all)
#
# The stack must already be up (docker compose up -d) so the database containers
# exist; this script stops only the services it touches, restores, and starts
# them again. RESTORING OVERWRITES LIVE DATA — it prompts for confirmation (or
# pass --yes). Use --check first: it verifies sha256 + gzip, loads the Immich
# dump into a throwaway scratch DB, and runs an integrity check on the
# Vaultwarden SQLite snapshot, all WITHOUT changing anything live. --check also
# runs weekly on its own timer (scripts/systemd/pc-restore-check.*), so a backup
# that exists but does not restore surfaces within a week:
#
#   systemctl start pc-restore-check.service
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.production}"
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found — run: source scripts/prod.env" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
# Make `docker compose` target the production stack even if prod.env wasn't sourced.
export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.production.yml}"
export COMPOSE_ENV_FILES="${COMPOSE_ENV_FILES:-$ENV_FILE}"

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo -E $0)." >&2; exit 1; }

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

# ---- parse args -------------------------------------------------------------
CHECK=0; ASSUME_YES=0; COMPONENTS=()
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    immich|seafile|vaultwarden|caddy|all) COMPONENTS+=("$a") ;;
    *) fail "unknown argument: $a" ;;
  esac
done
[[ ${#COMPONENTS[@]} -eq 0 ]] && COMPONENTS=(all)
printf '%s\n' "${COMPONENTS[@]}" | grep -qx all && COMPONENTS=(immich seafile vaultwarden caddy)
want() { printf '%s\n' "${COMPONENTS[@]}" | grep -qx "$1"; }

require_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]] \
    || fail "$1 is not running — bring the stack up first (docker compose up -d)"
}

# ---- mount the Storage Box --------------------------------------------------
for v in DATA_ROOT SB_HOST SB_SHARE SB_USER SB_PASSWORD SB_SMB_VERS \
         IMMICH_DB_USER IMMICH_DB_NAME SEAFILE_DB_ROOT_PASSWORD; do
  [[ -n "${!v:-}" && "${!v}" != "CHANGEME" ]] || fail "$v is not set in ${ENV_FILE:-.env.production}"
done
MNT="$(mktemp -d)"; WORK="$(mktemp -d)"; SCRATCH_DB=""
cleanup() {
  [[ -n "$SCRATCH_DB" ]] && docker exec -i pc-immich-db psql -U "$IMMICH_DB_USER" -d postgres -q \
    -c "DROP DATABASE IF EXISTS \"$SCRATCH_DB\" WITH (FORCE);" >/dev/null 2>&1 || true
  umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
log "mounting //${SB_HOST}/${SB_SHARE} ..."
mount -t cifs "//${SB_HOST}/${SB_SHARE}" "$MNT" \
  -o "username=${SB_USER},password=${SB_PASSWORD},vers=${SB_SMB_VERS},uid=0,gid=0,file_mode=0600,dir_mode=0700,seal" \
  || fail "could not mount the Storage Box"
DEST="$MNT/backups"
[[ -d "$DEST" ]] || fail "no backups/ directory on the Storage Box"

# ---- integrity verification (used by --check and before any restore) --------
verify_integrity() {
  log "backup manifest:"; sed 's/^/    /' "$DEST/backup-manifest.txt" 2>/dev/null || log "  (no manifest found)"
  local f
  for f in immich-db.sql.gz seafile-db.sql.gz vaultwarden.tar.gz caddy_data.tar.gz; do
    [[ -s "$DEST/$f" ]] || fail "$f missing or empty in backups/"
    gzip -t "$DEST/$f" 2>/dev/null || fail "$f failed gzip integrity check"
  done
  if [[ -f "$DEST/backup-manifest.txt" ]]; then
    log "checking sha256 against manifest ..."
    ( cd "$DEST" && grep -E '^[0-9a-f]{64}  ' backup-manifest.txt | sha256sum -c - ) \
      || fail "sha256 mismatch — backup is corrupt"
  fi
  log "all artifacts present, gzip-valid, checksums OK."
}

# ---- --check: prove restorability without changing anything -----------------
if [[ "$CHECK" == 1 ]]; then
  # The scratch load needs room for a transient copy of the Immich DB, and
  # Postgres holds recycled WAL up to max_wal_size before checkpoints wind it
  # back down. Skipping (exit 0) rather than failing keeps a tight disk from
  # mailing an alert every week; the reason lands in the journal.
  avail=$(df -k --output=avail "$DATA_ROOT" | tail -1)
  if [[ "$avail" -lt 6291456 ]]; then
    log "SKIPPED — only $((avail / 1024)) MB free on $DATA_ROOT, need 6 GB for the scratch restore."
    exit 0
  fi
  verify_integrity
  if want immich; then
    require_running pc-immich-db
    SCRATCH_DB="${IMMICH_DB_NAME}_restorecheck"     # dropped by cleanup() on exit
    log "loading Immich dump into scratch DB '$SCRATCH_DB' (non-destructive) ..."
    docker exec -i pc-immich-db psql -U "$IMMICH_DB_USER" -d postgres -q -v ON_ERROR_STOP=1 \
      -c "DROP DATABASE IF EXISTS \"$SCRATCH_DB\" WITH (FORCE);" -c "CREATE DATABASE \"$SCRATCH_DB\";" >/dev/null
    if gunzip -c "$DEST/immich-db.sql.gz" | docker exec -i pc-immich-db psql -U "$IMMICH_DB_USER" -d "$SCRATCH_DB" -q -v ON_ERROR_STOP=1 >/dev/null 2>"$WORK/pg.err"; then
      tbls=$(docker exec pc-immich-db psql -U "$IMMICH_DB_USER" -d "$SCRATCH_DB" -tAc \
        "select count(*) from information_schema.tables where table_schema='public';")
      log "  Immich dump restores cleanly into scratch DB ($tbls tables)."
    else
      log "  Immich scratch restore FAILED:"; sed 's/^/    /' "$WORK/pg.err"; fail "Immich dump is not restorable"
    fi
  fi
  if want vaultwarden; then
    log "checking Vaultwarden SQLite snapshot ..."
    mkdir -p "$WORK/vw"; tar xzf "$DEST/vaultwarden.tar.gz" -C "$WORK/vw"
    if command -v sqlite3 >/dev/null 2>&1; then
      res=$(sqlite3 "$WORK/vw/db.sqlite3" "PRAGMA integrity_check;" 2>&1 || true)
      [[ "$res" == "ok" ]] && log "  db.sqlite3 integrity_check: ok" || fail "Vaultwarden db.sqlite3 integrity_check: $res"
    else
      [[ -s "$WORK/vw/db.sqlite3" ]] && log "  db.sqlite3 present (install sqlite3 for a full integrity check)" || fail "db.sqlite3 missing in tar"
    fi
  fi
  log "CHECK PASSED — the backup is restorable."
  exit 0
fi

# ---- destructive restore ----------------------------------------------------
verify_integrity
log "about to OVERWRITE live data for: ${COMPONENTS[*]}"
if [[ "$ASSUME_YES" != 1 ]]; then
  if [[ -t 0 ]]; then
    read -rp "Type RESTORE to proceed: " ans
    [[ "$ans" == "RESTORE" ]] || { log "aborted."; exit 1; }
  else
    fail "refusing to restore without confirmation — re-run with --yes"
  fi
fi

if want immich; then
  log "restore: Immich Postgres"
  require_running pc-immich-db
  docker compose stop immich-server immich-ml >/dev/null 2>&1 || true
  docker exec -i pc-immich-db psql -U "$IMMICH_DB_USER" -d postgres -q -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$IMMICH_DB_NAME\" WITH (FORCE);" -c "CREATE DATABASE \"$IMMICH_DB_NAME\";" >/dev/null
  gunzip -c "$DEST/immich-db.sql.gz" | docker exec -i pc-immich-db psql -U "$IMMICH_DB_USER" -d "$IMMICH_DB_NAME" -q -v ON_ERROR_STOP=1
  docker compose start immich-server immich-ml >/dev/null
  log "  done (run Generate Thumbnails / Transcode Videos on 'Missing' to rebuild derivatives)"
fi

if want seafile; then
  log "restore: Seafile MariaDB (ccnet_db, seafile_db, seahub_db)"
  require_running pc-seafile-db
  docker compose stop seafile-server >/dev/null 2>&1 || true
  gunzip -c "$DEST/seafile-db.sql.gz" | docker exec -i -e MYSQL_PWD="$SEAFILE_DB_ROOT_PASSWORD" pc-seafile-db mariadb -u root
  docker compose start seafile-server >/dev/null
  log "  done"
fi

if want vaultwarden; then
  log "restore: Vaultwarden data folder"
  d="$DATA_ROOT/vaultwarden_data"; [[ -d "$d" ]] || fail "$d does not exist"
  docker compose stop vaultwarden >/dev/null 2>&1 || true
  find "$d" -mindepth 1 -delete            # also clears any stale db.sqlite3-wal/-shm
  tar xzf "$DEST/vaultwarden.tar.gz" -C "$d"
  chown -R 1000:1000 "$d"                  # vaultwarden runs as uid 1000
  docker compose up -d vaultwarden >/dev/null
  log "  done"
fi

if want caddy; then
  log "restore: Caddy TLS material"
  d="$DATA_ROOT/caddy_data"; [[ -d "$d" ]] || fail "$d does not exist"
  docker compose stop caddy >/dev/null 2>&1 || true
  find "$d" -mindepth 1 -delete
  tar xzf "$DEST/caddy_data.tar.gz" -C "$d"
  docker compose up -d caddy >/dev/null
  log "  done"
fi

log "restore complete for: ${COMPONENTS[*]}"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
