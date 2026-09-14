#!/usr/bin/env bash
# Copy Caddy's certificate for the mail host into Stalwart, then reload it.
#
# Caddy cannot front SMTP/IMAP, so Stalwart terminates TLS on those ports itself
# and needs the certificate Caddy already obtains and renews. Stalwart's
# certificate object holds a file path rather than the PEM text, so keeping the
# two files current is the whole job. They are copied, not shared: Caddy writes
# its own copy mode 0600 as uid 1001 and Stalwart runs as uid 2000.
#
# Idempotent — it compares the certificate first and exits without touching
# anything when it is unchanged, so the daily run is a no-op between renewals.
#
#   ENV_FILE=.env ./scripts/stalwart-cert-sync.sh    # local stack
#   sudo -E ./scripts/stalwart-cert-sync.sh          # production
#
# Scheduled as a daily timer (scripts/systemd/pc-stalwart-cert-sync.*). The
# certificate object is created once (README "Stalwart certificates"); this only
# refreshes what it points at.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.production}"
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found — run: source scripts/prod.env" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

[[ -n "${STALWART_DOMAIN:-}" ]] || fail "STALWART_DOMAIN is not set in $ENV_FILE"
[[ -n "${STALWART_API_KEY:-}" && "$STALWART_API_KEY" != "CHANGEME" ]] \
  || fail "STALWART_API_KEY is not set in $ENV_FILE (create one in Stalwart under Settings -> API keys)"

TLS_DIR=/var/lib/stalwart/tls

# The key reaches the container through the environment, never the command line.
sw_api() {
  docker exec -i -e "SW_KEY=$STALWART_API_KEY" pc-stalwart sh -c "$1"
}

# Caddy files its certificates under an issuer-named directory (`local` for its
# internal CA, `acme-v02...` for Let's Encrypt), so look it up instead of
# hardcoding a path that differs between the local and production stacks.
crt_path="$(docker exec pc-caddy sh -c \
  "ls /data/caddy/certificates/*/${STALWART_DOMAIN}/${STALWART_DOMAIN}.crt 2>/dev/null | head -1")" \
  || fail "cannot reach pc-caddy"
[[ -n "$crt_path" ]] || fail "Caddy has no certificate for ${STALWART_DOMAIN} yet"

new_crt="$(docker exec pc-caddy cat "$crt_path")"
old_crt="$(docker exec pc-stalwart cat "$TLS_DIR/mail.crt" 2>/dev/null || true)"
if [[ "$new_crt" == "$old_crt" ]]; then
  log "certificate for ${STALWART_DOMAIN} unchanged — nothing to do"
  exit 0
fi

log "installing renewed certificate for ${STALWART_DOMAIN} ..."
docker exec -u 2000 pc-stalwart mkdir -p "$TLS_DIR"
docker exec pc-caddy cat "$crt_path" \
  | docker exec -i -u 2000 pc-stalwart sh -c "cat > $TLS_DIR/mail.crt"
docker exec pc-caddy cat "${crt_path%.crt}.key" \
  | docker exec -i -u 2000 pc-stalwart sh -c "umask 077; cat > $TLS_DIR/mail.key"

# Settings objects live under the primary account of the JMAP session.
account="$(sw_api 'curl -sf -H "Authorization: Bearer $SW_KEY" http://127.0.0.1:8080/jmap/session' \
  | sed -n 's/.*"urn:stalwart:jmap":"\([^"]*\)".*/\1/p')"
[[ -n "$account" ]] || fail "could not read the JMAP session — is STALWART_API_KEY still valid?"

# Without this the running server keeps serving the certificate it read at boot.
resp="$(printf '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Action/set",{"accountId":"%s","create":{"a":{"@type":"ReloadTlsCertificates"}}},"0"]]}' "$account" \
  | sw_api 'curl -sf -X POST -H "Authorization: Bearer $SW_KEY" -H "Content-Type: application/json" --data-binary @- http://127.0.0.1:8080/jmap')" \
  || fail "the reload request failed"
case "$resp" in
  *'"created"'*) log "certificate installed and reloaded" ;;
  *)             fail "the reload was rejected: $resp" ;;
esac
