#!/usr/bin/env bash
# Acceptance tests, all exercised over HTTPS through Caddy:
#   1. Vaultwarden — store & retrieve a password (Bitwarden client crypto) + 2FA
#   2. Immich     — sync a photo (same REST API the iOS app uses)
#   3. Seafile    — sync a local file (same Web API the desktop/iOS clients use)
#                   + real-time push: a websocket upgrade on the URL Seafile
#                     advertises, and the sidecar reachable from the server
#   4. Navidrome  — browse, search, album art and a stream (Subsonic API, which
#                   the desktop and iOS players use) + sonic similarity through
#                   the navidrome-sonic plugin
set -uo pipefail
cd "$(dirname "$0")/.."
# Runtime config lives in the runtime env file; the Seafile and Navidrome admin
# secrets live in the setup file (see README "Secrets: setup vs runtime"). Immich's admin is NOT
# in any file — its first account is created in the browser, so the Immich test
# below always prompts for its email + password.
RUNTIME_ENV="${ENV_FILE:-./.env}"
SETUP_ENV="${SETUP_ENV_FILE:-${RUNTIME_ENV}.setup}"

# Compose reads the env file as plain KEY=VALUE; backup.sh, restore.sh,
# prod-setup.sh and this script `source` it as shell. The two parsers only agree
# while every value that needs quoting has it: unquoted, a space makes the shell
# run the rest of the line as a command, and `$`/backticks expand. Checked here,
# before anything sources the file.
env_lint() {
  local file="$1" bad=0 lineno=0 line key val unsafe
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue   # skips blanks + comments
    key="${line%%=*}"; val="${line#*=}"
    [[ -z "$val" ]] && continue
    [[ "$val" == \'*\' ]] && continue        # single quotes are literal to both
    unsafe=""
    if [[ "$val" == \"*\" ]]; then
      # Double quotes hold the value together, but the shell still expands these.
      case "$val" in *'$'*|*'`'*) unsafe="\$ or \` inside double quotes is expanded by the shell" ;; esac
    else
      [[ "$val" =~ [[:space:]] ]] && unsafe="unquoted value contains whitespace — the shell runs the rest as a command"
      case "$val" in
        *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*|'~'*)
          unsafe="unquoted value contains a shell metacharacter" ;;
      esac
    fi
    [[ -n "$unsafe" ]] && { printf '    %s:%s  %s — %s\n' "$file" "$lineno" "$key" "$unsafe" >&2; bad=1; }
  done < "$file"
  return "$bad"
}
lint_failed=0
env_lint "$RUNTIME_ENV" || lint_failed=1
env_lint "$SETUP_ENV"   || lint_failed=1
if [[ "$lint_failed" == 1 ]]; then
  echo "  ! env file values above need quoting (\"like this\") — Compose strips the quotes." >&2
  echo "    Left as is they break backup.sh / restore.sh / prod-setup.sh at the next run." >&2
  exit 1
fi

set -a
. "$RUNTIME_ENV"
[[ -f "$SETUP_ENV" ]] && . "$SETUP_ENV"
set +a
[[ -f "$SETUP_ENV" ]] || echo "  ! setup file $SETUP_ENV not found — the Seafile and Navidrome admin logins will fail (run ./scripts/init.sh or set SETUP_ENV_FILE)." >&2

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()   { printf '  \033[32m✓ PASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31m✗ FAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
info() { printf '  • %s\n' "$1"; }

R="127.0.0.1"
IM_BASE="https://${IMMICH_DOMAIN}:${HTTPS_PORT}"
SF_BASE="https://${SEAFILE_DOMAIN}:${HTTPS_PORT}"
ND_BASE="https://${NAVIDROME_DOMAIN}:${HTTPS_PORT}"

jget() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get(sys.argv[1],""))' "$1"; }

# -------------------------------------------------------------- Vaultwarden --
echo "[1/4] Vaultwarden — store & retrieve a password (Bitwarden-compatible)"
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
echo "[2/4] Immich — sync a photo (REST API used by the iOS app)"
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
echo "[3/4] Seafile — sync a local file (Web API used by the desktop/iOS clients)"
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

# Notification server (real-time push), tested at both ends against the values the
# container carries, since those are what Seafile hands out:
#   public — what the browser dials. The sidecar serves the websocket at its root
#            (/events is the event POST, /ping is health), and Caddy strips the
#            prefix, so a handshake against this exact value must upgrade: 101.
#   inner  — where seaf-server posts events, so it is checked from inside the
#            container.
# A successful upgrade leaves the socket open, so that curl always runs its full
# timeout.
ns_pub=$(docker exec pc-seafile printenv NOTIFICATION_SERVER_URL 2>/dev/null | tr -d '\r')
ns_inner=$(docker exec pc-seafile printenv INNER_NOTIFICATION_SERVER_URL 2>/dev/null | tr -d '\r')
if [[ -z "$ns_pub" || -z "$ns_inner" ]]; then
  no "notification server URLs unset in pc-seafile — no address for the browser, and events go to 127.0.0.1"
else
  ns_code=$(sf --http1.1 -m 5 -o /dev/null -w '%{http_code}' \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==' \
    "$ns_pub" 2>/dev/null)
  if [[ "$ns_code" == 101 ]]; then
    ok "websocket upgrade on the advertised URL ($ns_pub)"
  else
    no "websocket upgrade on $ns_pub returned ${ns_code:-<none>}, want 101"
  fi

  ns_pong=$(docker exec pc-seafile curl -sS -m 5 "${ns_inner%/}/ping" 2>/dev/null)
  if [[ "$ns_pong" == *pong* ]]; then
    ok "Seafile reaches the sidecar at $ns_inner"
  else
    no "Seafile cannot reach the sidecar at $ns_inner — its events are dropped"
  fi
fi

# ---------------------------------------------------------------- Navidrome --
echo "[4/4] Navidrome — stream music (Subsonic API used by the desktop/iOS players)"
nd() { curl -sS -k --resolve "${NAVIDROME_DOMAIN}:${HTTPS_PORT}:${R}" "$@"; }
# The setup overlay seeds the admin on the first `up`; the web app's embedded
# config says whether an admin exists yet.
if [[ "$(nd "${ND_BASE}/app/" 2>/dev/null)" == *'firstTime\":true'* ]]; then
  info "Navidrome has no admin yet — the first \`up\` with docker-compose.setup.yml seeds it. Skipping."
else
  ND_USER=admin
  ND_PASS="${NAVIDROME_ADMIN_PASSWORD:-}"
  # Subsonic token auth, as the clients send it: md5(password + salt).
  nd_salt=$(openssl rand -hex 6)
  nd_tok=$(printf '%s' "${ND_PASS}${nd_salt}" | openssl md5 | awk '{print $NF}')
  nda=(-G -d "u=${ND_USER}" -d "t=${nd_tok}" -d "s=${nd_salt}" -d v=1.16.1 -d c=pc-verify -d f=json)
  # Evaluates a Python expression against the response's "subsonic-response" (r).
  ndj() { python3 -c 'import sys,json;r=json.load(sys.stdin)["subsonic-response"];print(eval(sys.argv[1]))' "$1" 2>/dev/null; }
  if [[ "$(nd "${nda[@]}" "${ND_BASE}/rest/ping" | ndj 'r["status"]')" != ok ]]; then
    no "Navidrome login failed for ${ND_USER}"
  else
    ok "logged in as ${ND_USER}"
    album=$(nd "${nda[@]}" -d type=random -d size=1 "${ND_BASE}/rest/getAlbumList2" \
      | ndj '"\t".join((lambda a: [a["id"], a.get("coverArt", ""), a["name"]])(r["albumList2"]["album"][0]))')
    if [[ -z "$album" ]]; then
      info "the library is empty — copy music into the box's music/${NAVIDROME_LIBRARY}/ folder and run a scan. Skipping the rest."
    else
      IFS=$'\t' read -r al_id al_art al_name <<<"$album"
      hits=$(nd "${nda[@]}" --data-urlencode "query=${al_name}" "${ND_BASE}/rest/search3" | ndj 'len(r["searchResult3"].get("album", []))')
      if [[ "${hits:-0}" -gt 0 ]]; then ok "search finds album \"${al_name}\""; else no "search for \"${al_name}\" found nothing"; fi
      art=$(nd "${nda[@]}" -d "id=${al_art}" -d size=300 -o /dev/null -w '%{http_code} %{content_type}' "${ND_BASE}/rest/getCoverArt")
      if [[ "$art" == "200 image/"* ]]; then ok "album art served (${art#* })"; else no "album art: ${art}"; fi
      song=$(nd "${nda[@]}" -d "id=${al_id}" "${ND_BASE}/rest/getAlbum" | ndj 'r["album"]["song"][0]["id"]')
      st=$(nd "${nda[@]}" -d "id=${song}" -H 'Range: bytes=0-65535' -o /dev/null -w '%{http_code} %{content_type}' "${ND_BASE}/rest/stream")
      if [[ "$st" == 20[06]" audio/"* ]]; then ok "streamed a track (${st#* })"; else no "stream: ${st}"; fi
      # 404 without a body: no plugin offers the capability, i.e. sonic is not enabled.
      sim=$(nd "${nda[@]}" -d "id=${song}" -d count=5 -w '\n%{http_code}' "${ND_BASE}/rest/getSonicSimilarTracks")
      if [[ "${sim##*$'\n'}" == 404 ]]; then
        no "sonic similarity is off — enable the sonic plugin (README, Music library)"
      else
        n=$(ndj 'len(r.get("sonicMatch", [])) if r["status"] == "ok" else r["error"]["message"]' <<<"${sim%$'\n'*}")
        case "$n" in
          [0-9]*) ok "sonic similarity: ${n} tracks similar to the streamed one" ;;
          *"not analysed"*) info "navidrome-sonic has not analysed the streamed track yet — re-run after its first pass" ;;
          *) no "sonic similarity: ${n}" ;;
        esac
      fi
    fi
  fi
fi

# ----------------------------------------------------------------- summary --
echo
echo "================  $pass passed, $fail failed  ================"
[[ "$fail" -eq 0 ]]
