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
#
# A container that has only just started fails the check the same way a wedged one
# does -- it has not mounted or booted yet -- so a `docker compose up -d` deploy landing
# between two ticks reads as a wedge and gets bounced mid-deploy. GRACE holds off on
# containers younger than that, and a tick that skipped one draws no conclusion at all:
# it must not clear the state file, or the attempt counter resets after every bounce and
# the alert never fires.
set -uo pipefail

CHECKS=(  # container : path under the CIFS mount to stat
  "pc-seafile:/shared/seafile/seafile-data"
  "pc-immich-server:/data/library"
  "pc-immich-preview-mover:/data/library"  # holds the same mount; previews/ may not exist yet
)
STATE=/run/pc-mount-watchdog.state  # "<epoch of last bounce> <consecutive attempts>"
COOLDOWN=300; RECOVERY_ATTEMPTS=3
GRACE=180  # seconds; a container younger than this is still coming up, not wedged

log() { printf '%s  pc-mount-watchdog: %s\n' "$(date '+%F %T')" "$*"; }

bounce=()
bad=0
starting=0
now=$(date +%s)

for entry in "${CHECKS[@]}"; do
  cont="${entry%%:*}"; path="${entry#*:}"
  running=""; started=""; err=""
  # State.Error read last so it gets the rest of the line, spaces included.
  read -r running started err < <(docker inspect -f '{{.State.Running}} {{.State.StartedAt}} {{.State.Error}}' "$cont" 2>/dev/null)

  if [[ "$running" == "true" ]]; then
    # Healthy containers join the bounce too: while one holds the mount, the shared
    # connection lives on and the others remount straight back onto it.
    bounce+=("$cont")
    timeout 12 docker exec "$cont" stat "$path" >/dev/null 2>&1 && continue
    age=$(( now - $(date -d "$started" +%s 2>/dev/null || echo 0) ))
    if (( age < GRACE )); then
      log "$cont: started ${age}s ago, still coming up -- not judging this tick"
      starting=1
      continue
    fi
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
  # Only a tick that judged every container may declare recovery and drop the counter.
  (( starting )) && exit 0
  [[ -f "$STATE" ]] && log "mounts recovered"
  rm -f "$STATE"
  exit 0
fi

last=0; n=0
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
