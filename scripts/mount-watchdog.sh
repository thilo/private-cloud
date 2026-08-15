#!/usr/bin/env bash
# Storage Box mount watchdog. When the Hetzner Storage Box migrates or reboots, the
# kernel CIFS client can wedge its SMB session (STATUS_LOGON_FAILURE loop): the mount
# dies while the app still answers, so storage-touching requests 502 while `docker ps`
# looks healthy. A Docker CIFS volume can only be remounted by restarting its
# container. (addr= in docker-compose.yml lets the kernel recover on its own, but only
# for wedges that reach the reconnect path; this covers the rest.)
#
# Every container is stopped and started TOGETHER, even when only one mount is bad:
# they share one CIFS connection (same host, same credentials) and the kernel refcounts
# it, so restarting them one at a time never drops it to zero and the remount lands
# straight back on the broken connection.
#
# Runs from pc-mount-watchdog.timer every 60s; the cooldown keeps a genuinely-down box
# from causing a bounce per tick. Events go to the journal
# (journalctl -u pc-mount-watchdog.service).
set -uo pipefail

CHECKS=(  # container : path under the CIFS mount to stat
  "pc-seafile:/shared/seafile/seafile-data"
  "pc-immich-server:/data/library"
)
STATE=/run/pc-mount-watchdog.state  # "<epoch of last bounce> <consecutive attempts>"
COOLDOWN=300; RECOVERY_ATTEMPTS=3

log() { printf '%s  pc-mount-watchdog: %s\n' "$(date '+%F %T')" "$*"; }

bounce=()
bad=0

for entry in "${CHECKS[@]}"; do
  cont="${entry%%:*}"; path="${entry#*:}"
  running=""; err=""
  # State.Error read last so it gets the rest of the line, spaces included.
  read -r running err < <(docker inspect -f '{{.State.Running}} {{.State.Error}}' "$cont" 2>/dev/null)

  if [[ "$running" == "true" ]]; then
    # Healthy containers join the bounce too: while one holds the mount, the shared
    # connection lives on and the others remount straight back onto it.
    bounce+=("$cont")
    timeout 12 docker exec "$cont" stat "$path" >/dev/null 2>&1 && continue
    log "$cont: mount ($path) wedged"
  elif [[ -n "$err" ]]; then
    # Mount failed at start — the box moved and Docker reports "key has been revoked".
    # Keep starting it; the new address resolves once DNS catches up.
    bounce+=("$cont")
    log "$cont: stopped, did not start: $err"
  else
    continue  # stopped by hand: holds no mount, so leave it out and leave it alone
  fi
  bad=1
done

if (( bad == 0 )); then
  [[ -f "$STATE" ]] && log "mounts recovered"
  rm -f "$STATE"
  exit 0
fi

now=$(date +%s); last=0; n=0
[[ -f "$STATE" ]] && read -r last n < "$STATE"
if (( now - last < COOLDOWN )); then
  log "within cooldown, not retrying"
  exit 0
fi

log "bouncing together: ${bounce[*]}"
docker stop "${bounce[@]}" >/dev/null 2>&1
docker start "${bounce[@]}" >/dev/null 2>&1 || log "containers did not start"

# Count attempts, not docker's exit status: a bounce that returns 0 onto a still-wedged
# mount recovered nothing. n only grows, so == alerts exactly once per incident.
echo "$now $(( ++n ))" > "$STATE"
if (( n == RECOVERY_ATTEMPTS )); then
  log "unrecovered after $RECOVERY_ATTEMPTS attempts -- alerting"
  exit 1  # OnFailure= mails
fi
exit 0
