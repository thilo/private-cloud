#!/usr/bin/env bash
# Storage Box mount watchdog. The kernel CIFS client can wedge its SMB session
# when the Hetzner Storage Box migrates/reboots (STATUS_LOGON_FAILURE loop): the
# mount dies while the app still answers, so requests 502 silently. A Docker CIFS
# volume can only be remounted by restarting the container, so on a wedge we
# restart it. The addr= mount option (see docker-compose.yml) lets the kernel
# reconnect to a moved box on its own, which is faster than a restart but only
# covers wedges that reach the reconnect path; this covers the rest. A migration
# can also change the box's address, in which case the mount fails outright
# (STATUS_ACCOUNT_DISABLED against the old host, surfaced by Docker as "key has
# been revoked") and the restart leaves the container stopped;
# we keep trying to start it, since the address moves once DNS catches up.
# Runs from pc-mount-watchdog.timer every 60s; a per-container cooldown avoids
# thrashing if the box is genuinely down. After RECOVERY_ATTEMPTS consecutive
# failed attempts the run exits non-zero once, so OnFailure= mails. Events go to
# the journal (journalctl -u pc-mount-watchdog.service).
set -uo pipefail

CHECKS=(  # container : path under the CIFS mount to stat
  "pc-seafile:/shared/seafile/seafile-data"
  "pc-immich-server:/data/library"
)
STATE_DIR=/run/pc-mount-watchdog; COOLDOWN=300; RECOVERY_ATTEMPTS=3
mkdir -p "$STATE_DIR"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }

# Count a recovery attempt; return 0 when this run should alert, i.e. the
# threshold is reached and no mail has gone out for this incident yet. Counted at
# the attempt, not on the docker exit status: a restart that returns 0 but comes
# back to a still-wedged mount has not recovered anything. A working attempt
# clears the count at the next check, well before the threshold.
record_attempt() {
  local cont="$1" n
  n=$(( $(cat "$STATE_DIR/$cont.fails" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$STATE_DIR/$cont.fails"
  (( n >= RECOVERY_ATTEMPTS )) && [[ ! -f "$STATE_DIR/$cont.notified" ]]
}

# The mount is healthy again: clear the incident so the next one alerts afresh.
clear_failures() {
  local cont="$1"
  [[ -f "$STATE_DIR/$cont.notified" ]] && log "pc-mount-watchdog: $cont recovered"
  rm -f "$STATE_DIR/$cont.fails" "$STATE_DIR/$cont.notified" "$STATE_DIR/$cont"
}

alert=0

for entry in "${CHECKS[@]}"; do
  cont="${entry%%:*}"; path="${entry#*:}"

  if [[ "$(docker inspect -f '{{.State.Running}}' "$cont" 2>/dev/null)" == "true" ]]; then
    if timeout 12 docker exec "$cont" stat "$path" >/dev/null 2>&1; then
      clear_failures "$cont"; continue
    fi
    action=restart; reason="mount ($path) wedged"
  else
    # Stopped. Only our business if Docker recorded a start error — that is the
    # failed-remount case. A container stopped by hand has no error and is left
    # alone, which is what the plain Running check used to give us.
    err="$(docker inspect -f '{{.State.Error}}' "$cont" 2>/dev/null)"
    [[ -n "$err" ]] || continue
    action=start; reason="stopped, did not start: $err"
  fi

  last="$STATE_DIR/$cont"; now=$(date +%s)
  if [[ -f "$last" ]] && (( now - $(cat "$last") < COOLDOWN )); then
    log "pc-mount-watchdog: $cont still failing ($reason); within cooldown, not retrying"
    continue
  fi
  echo "$now" > "$last"

  log "pc-mount-watchdog: $cont $reason -- ${action}ing to remount"
  if docker "$action" "$cont" >/dev/null 2>&1; then
    log "pc-mount-watchdog: docker $action $cont returned ok"
  else
    log "pc-mount-watchdog: docker $action $cont failed"
  fi

  if record_attempt "$cont"; then
    log "pc-mount-watchdog: $cont unrecovered after $RECOVERY_ATTEMPTS attempts -- alerting"
    touch "$STATE_DIR/$cont.notified"; alert=1
  fi
done

# Non-zero exactly once per incident, so OnFailure= mails without a mail per tick.
exit "$alert"
