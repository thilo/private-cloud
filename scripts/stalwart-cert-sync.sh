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
# Scheduled as a daily timer (scripts/systemd/pc-stalwart-cert-sync.*). The first
# run also creates the certificate object that points at the two files. It
# authenticates as the `certsync` account that scripts/stalwart-apply.sh declares.
# Certificates configured for anything else are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.production}"
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found — run: source scripts/prod.env" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

[[ -n "${STALWART_DOMAIN:-}" ]] || fail "STALWART_DOMAIN is not set in $ENV_FILE"
[[ -n "${STALWART_CERTSYNC_PASSWORD:-}" && "$STALWART_CERTSYNC_PASSWORD" != "CHANGEME" ]] \
  || fail "STALWART_CERTSYNC_PASSWORD is not set in $ENV_FILE"

TLS_DIR=/var/lib/stalwart/tls

# The password reaches the container through the environment, never the command line.
sw_api() {
  SW_PW="$STALWART_CERTSYNC_PASSWORD" docker exec -i -e SW_PW pc-stalwart sh -c "$1"
}

# Caddy files its certificates under an issuer-named directory (`local` for its
# internal CA, `acme-v02...` for Let's Encrypt), so look it up instead of
# hardcoding a path that differs between the local and production stacks.
crt_path="$(docker exec pc-caddy sh -c \
  "ls /data/caddy/certificates/*/${STALWART_DOMAIN}/${STALWART_DOMAIN}.crt 2>/dev/null | head -1")" \
  || fail "cannot reach pc-caddy"
[[ -n "$crt_path" ]] || fail "Caddy has no certificate for ${STALWART_DOMAIN} yet"

jmap() { # request body on stdin, response on stdout
  sw_api 'curl -sf -X POST -u "certsync:$SW_PW" -H "Content-Type: application/json" --data-binary @- http://127.0.0.1:8080/jmap'
}

# Settings objects live under the primary account of the JMAP session.
account="$(sw_api 'curl -sf -u "certsync:$SW_PW" http://127.0.0.1:8080/jmap/session' \
  | sed -n 's/.*"urn:stalwart:jmap":"\([^"]*\)".*/\1/p')"
[[ -n "$account" ]] || fail "could not read the JMAP session — has scripts/stalwart-apply.sh run?"

new_crt="$(docker exec pc-caddy cat "$crt_path")"
old_crt="$(docker exec pc-stalwart cat "$TLS_DIR/mail.crt" 2>/dev/null || true)"
[[ "$new_crt" == "$old_crt" ]] && changed=0 || changed=1

# Does a certificate object already point at our files? Anything else configured
# here is left alone.
printf '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Certificate/get",{"accountId":"%s"},"0"]]}' "$account" \
  | jmap | grep -qF "$TLS_DIR/mail.crt" && exists=1 || exists=0

if [[ "$changed" == 0 && "$exists" == 1 ]]; then
  log "certificate for ${STALWART_DOMAIN} unchanged — nothing to do"
  exit 0
fi

if [[ "$changed" == 1 ]]; then
  log "installing certificate for ${STALWART_DOMAIN} ..."
  docker exec -u 2000 pc-stalwart mkdir -p "$TLS_DIR"
  docker exec pc-caddy cat "$crt_path" \
    | docker exec -i -u 2000 pc-stalwart sh -c "cat > $TLS_DIR/mail.crt"
  docker exec pc-caddy cat "${crt_path%.crt}.key" \
    | docker exec -i -u 2000 pc-stalwart sh -c "umask 077; cat > $TLS_DIR/mail.key"
fi

# First run (or after the object was removed): point Stalwart at the two files.
# It parses them on create, so they have to be in place first.
if [[ "$exists" == 0 ]]; then
  log "creating the certificate object ..."
  resp="$(printf '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Certificate/set",{"accountId":"%s","create":{"c":{"certificate":{"@type":"File","filePath":"%s/mail.crt"},"privateKey":{"@type":"File","filePath":"%s/mail.key"}}}},"0"]]}' \
    "$account" "$TLS_DIR" "$TLS_DIR" | jmap)" || fail "the create request failed"
  case "$resp" in
    *'"created"'*) ;;
    *) fail "the certificate object was rejected: $resp" ;;
  esac
fi

# Without this the running server keeps serving what it read at boot.
resp="$(printf '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Action/set",{"accountId":"%s","create":{"a":{"@type":"ReloadTlsCertificates"}}},"0"]]}' "$account" \
  | jmap)" || fail "the reload request failed"
case "$resp" in
  *'"created"'*) log "certificate installed and reloaded" ;;
  *)             fail "the reload was rejected: $resp" ;;
esac
