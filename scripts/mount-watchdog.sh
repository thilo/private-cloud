#!/usr/bin/env bash
# Storage Box mount watchdog. The kernel CIFS client can wedge its SMB session
# when the Hetzner Storage Box migrates/reboots (STATUS_LOGON_FAILURE loop): the
# mount dies while the app still answers, so requests 502 silently. A Docker CIFS
# volume can only be remounted by restarting the container, so on a wedge we
# restart it. Runs from pc-mount-watchdog.timer every 60s; a per-container
# cooldown avoids thrashing if the box is genuinely down. Events go to the journal
# (journalctl -u pc-mount-watchdog.service).
set -uo pipefail

CHECKS=(  # container : path under the CIFS mount to stat
  "pc-seafile:/shared/seafile/seafile-data"
  "pc-immich-server:/data/library"
)
STATE_DIR=/run/pc-mount-watchdog; COOLDOWN=300
mkdir -p "$STATE_DIR"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }

for entry in "${CHECKS[@]}"; do
  cont="${entry%%:*}"; path="${entry#*:}"
  [[ "$(docker inspect -f '{{.State.Running}}' "$cont" 2>/dev/null)" == "true" ]] || continue
  timeout 12 docker exec "$cont" stat "$path" >/dev/null 2>&1 && continue

  last="$STATE_DIR/$cont"; now=$(date +%s)
  if [[ -f "$last" ]] && (( now - $(cat "$last") < COOLDOWN )); then
    log "pc-mount-watchdog: $cont mount still wedged; within cooldown, not restarting"
    continue
  fi
  echo "$now" > "$last"
  log "pc-mount-watchdog: $cont mount ($path) wedged -- restarting to remount"
  docker restart "$cont" >/dev/null 2>&1 || log "pc-mount-watchdog: docker restart $cont failed"
done
