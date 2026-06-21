#!/usr/bin/env bash
# Post-"up" provisioning:
#   - create the first Immich admin account (used by the iOS app / verify.sh)
# Seafile creates its admin automatically on first start (INIT_SEAFILE_ADMIN_*),
# and its encrypted libraries are client-side, so it needs no bootstrap step.
set -euo pipefail
cd "$(dirname "$0")/.."
# Runtime config + the setup-only secrets (initial admin accounts) live in two
# files; this script needs IMMICH_ADMIN_* from the setup file (see README
# "Secrets: setup vs runtime").
RUNTIME_ENV="${ENV_FILE:-./.env}"
SETUP_ENV="${SETUP_ENV_FILE:-${RUNTIME_ENV}.setup}"
set -a
. "$RUNTIME_ENV"
[[ -f "$SETUP_ENV" ]] && . "$SETUP_ENV"
set +a
if [[ -z "${IMMICH_ADMIN_PASSWORD:-}" || "${IMMICH_ADMIN_PASSWORD}" == "CHANGEME" ]]; then
  echo "IMMICH_ADMIN_PASSWORD is not set — it lives in the setup file ($SETUP_ENV)." >&2
  echo "Run ./scripts/init.sh, or pass SETUP_ENV_FILE=/path/to/your.setup." >&2
  exit 1
fi

curlk() {
  curl -sS -k --resolve "${IMMICH_DOMAIN}:${HTTPS_PORT}:127.0.0.1" "$@"
}

IMMICH_BASE="https://${IMMICH_DOMAIN}:${HTTPS_PORT}"

echo "==> Waiting for the Immich API..."
for i in $(seq 1 90); do
  code=$(curlk -o /dev/null -w '%{http_code}' "${IMMICH_BASE}/api/server/ping" || true)
  if [[ "$code" == "200" ]]; then echo "    Immich API is up."; break; fi
  sleep 5
  if [[ $i -eq 90 ]]; then echo "Immich API not ready in time." >&2; exit 1; fi
done

echo "==> Creating Immich admin account (${IMMICH_ADMIN_EMAIL})..."
body=$(printf '{"email":"%s","password":"%s","name":"%s"}' \
  "$IMMICH_ADMIN_EMAIL" "$IMMICH_ADMIN_PASSWORD" "$IMMICH_ADMIN_NAME")
code=$(curlk -o /tmp/pc_immich_signup.json -w '%{http_code}' \
  -X POST "${IMMICH_BASE}/api/auth/admin-sign-up" \
  -H 'Content-Type: application/json' -d "$body" || true)
case "$code" in
  201)     echo "    Created." ;;
  400|409) echo "    Admin already exists — leaving as is." ;;
  *)       echo "    Unexpected response ($code):" >&2; cat /tmp/pc_immich_signup.json >&2; echo ;;
esac

echo
echo "Bootstrap complete. Run ./scripts/verify.sh to test file / password / photo sync."
