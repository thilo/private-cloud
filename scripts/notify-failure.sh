#!/usr/bin/env bash
# Mail an alert about a failed systemd unit. Driven by OnFailure= in
# pc-backup.service / pc-restore-check.service via pc-notify-failure@.service;
# the failed unit's name is the only argument.
#
#   ./scripts/notify-failure.sh pc-backup.service
#
# Mail is OPTIONAL: an empty SMTP_HOST or ALERT_EMAIL exits 0 without sending —
# the same switch Vaultwarden and harden-seafile.sh use. curl is the mail client,
# so the host needs no MTA.
set -euo pipefail

UNIT="${1:-unknown.unit}"

if [[ -z "${SMTP_HOST:-}" || -z "${ALERT_EMAIL:-}" ]]; then
  echo "notify-failure: SMTP_HOST or ALERT_EMAIL unset — mail disabled, not notifying about $UNIT"
  exit 0
fi

: "${SMTP_PORT:=587}"
: "${SMTP_SECURITY:=starttls}"
: "${SMTP_FROM:=$SMTP_USERNAME}"
: "${SMTP_FROM_NAME:=private-cloud}"

# --ssl-reqd makes STARTTLS mandatory rather than best-effort.
case "$SMTP_SECURITY" in
  force_tls) URL="smtps://${SMTP_HOST}:${SMTP_PORT}"; TLS=(--ssl-reqd) ;;
  starttls)  URL="smtp://${SMTP_HOST}:${SMTP_PORT}";  TLS=(--ssl-reqd) ;;
  off)       URL="smtp://${SMTP_HOST}:${SMTP_PORT}";  TLS=() ;;
  *) echo "notify-failure: invalid SMTP_SECURITY '$SMTP_SECURITY'" >&2; exit 1 ;;
esac

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
MSG="$(mktemp)"; trap 'rm -f "$MSG"' EXIT

{
  printf '%s\r\n' "From: ${SMTP_FROM_NAME} <${SMTP_FROM}>"
  printf '%s\r\n' "To: ${ALERT_EMAIL}"
  printf '%s\r\n' "Subject: [private-cloud] ${UNIT} FAILED on ${HOSTNAME_FQDN}"
  printf '%s\r\n' "Date: $(date -R)"
  printf '%s\r\n' "Message-ID: <$(date +%s).$$@${HOSTNAME_FQDN}>"
  printf '%s\r\n' "Content-Type: text/plain; charset=UTF-8"
  printf '\r\n'
  printf '%s\r\n' "${UNIT} failed on ${HOSTNAME_FQDN} at $(date '+%Y-%m-%d %H:%M:%S %Z')."
  printf '\r\n'
  systemctl show "$UNIT" -p Result -p ExecMainStatus -p ActiveEnterTimestamp 2>/dev/null \
    | sed 's/\r$//' | while IFS= read -r l; do printf '%s\r\n' "  $l"; done
  printf '\r\n'
  printf '%s\r\n' "Last 30 journal lines:"
  journalctl -u "$UNIT" -n 30 --no-pager -o short-iso 2>/dev/null \
    | sed 's/\r$//' | while IFS= read -r l; do printf '%s\r\n' "  $l"; done
  printf '\r\n'
  printf '%s\r\n' "Full log:  journalctl -u ${UNIT} -n 100"
} > "$MSG"

curl --silent --show-error --connect-timeout 20 --max-time 120 \
  "${TLS[@]}" --url "$URL" \
  --user "${SMTP_USERNAME}:${SMTP_PASSWORD}" \
  --mail-from "${SMTP_FROM}" \
  --mail-rcpt "${ALERT_EMAIL}" \
  --upload-file "$MSG"

echo "notify-failure: alert for $UNIT sent to $ALERT_EMAIL"
