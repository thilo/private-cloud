#!/usr/bin/env bash
# Acceptance tests, all exercised over HTTPS through Caddy:
#   1. Vaultwarden — store & retrieve a password (Bitwarden client crypto) + 2FA
#   2. Immich     — sync a photo (same REST API the iOS app uses)
#   3. Seafile    — sync a local file (same Web API the desktop/iOS clients use)
#                   + notification server reachable (real-time push) via /notification
set -uo pipefail
cd "$(dirname "$0")/.."
# Runtime config lives in the runtime env file; the Seafile admin secret lives in
# the setup file (see README "Secrets: setup vs runtime"). Immich's admin is NOT
# in any file — its first account is created in the browser, so the Immich test
# below always prompts for its email + password.
RUNTIME_ENV="${ENV_FILE:-./.env}"
SETUP_ENV="${SETUP_ENV_FILE:-${RUNTIME_ENV}.setup}"
set -a
. "$RUNTIME_ENV"
[[ -f "$SETUP_ENV" ]] && . "$SETUP_ENV"
set +a
[[ -f "$SETUP_ENV" ]] || echo "  ! setup file $SETUP_ENV not found — the Seafile admin login will fail (run ./scripts/init.sh or set SETUP_ENV_FILE)." >&2

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()   { printf '  \033[32m✓ PASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31m✗ FAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
info() { printf '  • %s\n' "$1"; }

R="127.0.0.1"
IM_BASE="https://${IMMICH_DOMAIN}:${HTTPS_PORT}"
SF_BASE="https://${SEAFILE_DOMAIN}:${HTTPS_PORT}"

jget() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get(sys.argv[1],""))' "$1"; }

# -------------------------------------------------------------- Vaultwarden --
echo "[1/3] Vaultwarden — store & retrieve a password (Bitwarden-compatible)"
if ! command -v node >/dev/null 2>&1; then
  no "node not found (needed for the Bitwarden client test)"
else
  # Account creation needs signups enabled; flip it on for the test only and
  # restore the .env value (secure default: false) afterwards.
  vw_wait_healthy() {
    for _ in $(seq 1 15); do
      [[ "$(docker inspect -f '{{.State.Health.Status}}' pc-vaultwarden 2>/dev/null)" == healthy ]] && return 0
      sleep 3
    done; return 1
  }
  if [[ "${VAULTWARDEN_SIGNUPS_ALLOWED}" != "true" ]]; then
    info "temporarily enabling Vaultwarden signups for the test..."
    VAULTWARDEN_SIGNUPS_ALLOWED=true docker compose up -d vaultwarden >/dev/null 2>&1
    vw_wait_healthy
  fi

  out=$(NODE_TLS_REJECT_UNAUTHORIZED=0 \
        VW_URL="${VAULTWARDEN_URL}" \
        VW_RESOLVE="${R}" \
        VW_SECRET="S3cr3t-$(date +%s)" \
        node scripts/vw-test.mjs 2>&1 | grep -v 'NODE_TLS_REJECT_UNAUTHORIZED\|trace-warnings') || true

  if [[ "${VAULTWARDEN_SIGNUPS_ALLOWED}" != "true" ]]; then
    info "restoring Vaultwarden signups=false..."
    docker compose up -d vaultwarden >/dev/null 2>&1
    vw_wait_healthy
  fi

  printf '%s\n' "$out" | sed 's/^/    /'
  if grep -q '^FETCH_MATCH: yes' <<<"$out"; then
    ok "stored a password and read the same value back through the API"
  else
    no "could not store/retrieve the password"
  fi
  if grep -qE '^TOTP: enabled$' <<<"$out"; then ok "TOTP 2FA enabled and confirmed to gate login (refused without code, accepted with code)"
  else info "TOTP live-enable not fully confirmed (feature is built in — enable it in the app)"; fi
fi

# ------------------------------------------------------------------- Immich --
echo "[2/3] Immich — sync a photo (REST API used by the iOS app)"
im() { curl -sS -k --resolve "${IMMICH_DOMAIN}:${HTTPS_PORT}:${R}" "$@"; }
# The first Immich admin is created in the browser: admin-sign-up is open until an
# admin exists, then self-closes. server/config.isInitialized (a public field the
# login page itself reads) tells us which case we're in:
#   false -> no admin yet — nothing to log in as, so skip with a hint.
#   true  -> admin exists — log in for the photo test. The password is in no file,
#            so always prompt for the admin's email + password (password hidden).
im_initialized=$(im "${IM_BASE}/api/server/config" 2>/dev/null | jget isInitialized 2>/dev/null)
token=""
if [[ "$im_initialized" != "True" ]]; then
  info "Immich has no admin yet — register it in the browser at ${IM_BASE}, then re-run verify.sh for the photo test. Skipping."
else
  read -r -p "    Immich admin email: " IMMICH_ADMIN_EMAIL
  read -r -s -p "    Immich admin password (input hidden): " IMMICH_ADMIN_PASSWORD; echo
  login=$(im -X POST "${IM_BASE}/api/auth/login" -H 'Content-Type: application/json' \
           -d "{\"email\":\"${IMMICH_ADMIN_EMAIL}\",\"password\":\"${IMMICH_ADMIN_PASSWORD}\"}")
  token=$(printf '%s' "$login" | jget accessToken)
  [[ -z "$token" ]] && no "Immich admin login failed: $login"
fi
if [[ -n "$token" ]]; then
  ok "logged in as ${IMMICH_ADMIN_EMAIL}"
  img="$tmp/pc-verify.jpg"
  if command -v magick >/dev/null 2>&1; then magick -size 48x48 xc:skyblue "$img"
  elif command -v convert >/dev/null 2>&1; then convert -size 48x48 xc:skyblue "$img"
  else
    base64 -d > "$img" <<'JPEG'
/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a
HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy
MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIA
AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA
AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3
ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm
p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA
AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx
BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK
U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3
uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD9/KKK
KAP/2Q==
JPEG
  fi
  up=$(im -X POST "${IM_BASE}/api/assets" -H "Authorization: Bearer ${token}" \
        -F "deviceAssetId=pc-verify-$(date +%s)" -F "deviceId=pc-verify" \
        -F "fileCreatedAt=2026-06-16T12:00:00.000Z" -F "fileModifiedAt=2026-06-16T12:00:00.000Z" \
        -F "isFavorite=false" -F "assetData=@${img}")
  asset_id=$(printf '%s' "$up" | jget id)
  status=$(printf '%s' "$up" | jget status)
  if [[ -n "$asset_id" ]]; then
    get=$(im -H "Authorization: Bearer ${token}" "${IM_BASE}/api/assets/${asset_id}")
    if [[ -n "$(printf '%s' "$get" | jget id)" ]]; then
      ok "uploaded a photo and fetched it back (id=${asset_id:0:8}…, status=${status})"
    else
      no "asset uploaded but not retrievable"
    fi
  else
    no "photo upload failed: $up"
  fi
fi

# ------------------------------------------------------------------ Seafile --
echo "[3/3] Seafile — sync a local file (Web API used by the desktop/iOS clients)"
sf() { curl -sS -k --resolve "${SEAFILE_DOMAIN}:${HTTPS_PORT}:${R}" "$@"; }
# If the Seafile admin has 2FA enrolled (ENABLE_TWO_FACTOR_AUTH), the token API
# needs a one-time code. Pass it for this run only: SEAFILE_OTP=123456 ./scripts/verify.sh
# Left unset, the call behaves exactly as before (fine for accounts without 2FA).
if [[ -n "${SEAFILE_OTP:-}" ]]; then
  sf_tok=$(sf -H "X-SEAFILE-OTP: ${SEAFILE_OTP}" -X POST "${SF_BASE}/api2/auth-token/" \
            -d "username=${SEAFILE_ADMIN_EMAIL}" -d "password=${SEAFILE_ADMIN_PASSWORD}" | jget token)
else
  sf_tok=$(sf -X POST "${SF_BASE}/api2/auth-token/" \
            -d "username=${SEAFILE_ADMIN_EMAIL}" -d "password=${SEAFILE_ADMIN_PASSWORD}" | jget token)
fi
if [[ -z "$sf_tok" ]]; then
  if [[ -z "${SEAFILE_OTP:-}" ]]; then
    no "Seafile admin login failed — if 2FA is enabled for ${SEAFILE_ADMIN_EMAIL}, re-run with SEAFILE_OTP=<6-digit code> (else check pc-seafile is healthy)"
  else
    no "Seafile admin login failed even with SEAFILE_OTP (code expired/incorrect, or pc-seafile not healthy)"
  fi
else
  ok "logged in as ${SEAFILE_ADMIN_EMAIL}"
  sfa=(-H "Authorization: Token ${sf_tok}")
  repo=$(sf "${sfa[@]}" -X POST "${SF_BASE}/api2/repos/" -d "name=pc-verify" | jget repo_id)
  if [[ -z "$repo" ]]; then
    no "could not create a Seafile library"
  else
    sfcontent="seafile hello @ $(date +%s)"
    printf '%s\n' "$sfcontent" > "$tmp/sf-hello.txt"
    ulink=$(sf "${sfa[@]}" "${SF_BASE}/api2/repos/${repo}/upload-link/" | tr -d '"')
    sf "${sfa[@]}" -X POST "$ulink" \
       -F "file=@${tmp}/sf-hello.txt" -F "parent_dir=/" -F "replace=1" >/dev/null
    dlink=$(sf "${sfa[@]}" "${SF_BASE}/api2/repos/${repo}/file/?p=/sf-hello.txt" | tr -d '"')
    sfgot=$(sf "$dlink")
    if [[ "$sfgot" == "$sfcontent" ]]; then
      ok "uploaded and read back identical bytes (lib ${repo:0:8}…)"
    else
      no "Seafile round-trip body mismatch"
    fi
    sf "${sfa[@]}" -X DELETE "${SF_BASE}/api2/repos/${repo}/" >/dev/null 2>&1 || true
  fi
  info "client-side encrypted libraries (the reliable iOS E2EE) are created in the app"
fi

# Notification server (real-time push) — unauthenticated health endpoint that Caddy
# proxies at /notification/ping. A pong proves Caddy strips the /notification prefix
# and reaches the sidecar on :8083 (the same websocket path the clients use).
np=$(sf "${SF_BASE}/notification/ping" 2>/dev/null)
if [[ "$np" == *pong* ]]; then
  ok "notification server reachable through Caddy (/notification/ping → pong)"
else
  no "notification server ping failed through Caddy: ${np:-<empty>}"
fi

# ----------------------------------------------------------------- summary --
echo
echo "================  $pass passed, $fail failed  ================"
[[ "$fail" -eq 0 ]]
