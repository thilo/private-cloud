#!/usr/bin/env bash
# Apply the Seafile config this stack needs but the seafile-mc image will not take
# from compose `environment:`. Two files, both generated into the seafile_data
# volume on first setup:
#
#   conf/seahub_settings.py  — Seahub security settings + outgoing mail
#                              (managed block, below)
#   conf/gunicorn.conf.py    — seahub worker count 5 -> ${SEAHUB_WORKERS:-2}
#                              (5 Django workers x ~130 MB blow the 4 GB budget)
#
# The image only maps a fixed allow-list of env vars into its config (DB creds,
# admin, hostname, JWT, the ENABLE_* feature toggles). Arbitrary Seahub keys such
# as CSRF_COOKIE_SECURE / LOGIN_ATTEMPT_LIMIT / SHARE_LINK_* — and the EMAIL_*
# mail settings — are ignored there and must live in conf/seahub_settings.py — a
# Python file, so some values are expressions. This idempotently writes a single
# MANAGED block (between the markers below) into that file, sets the worker
# count, and restarts Seafile once iff anything changed. Re-running replaces the
# block in place; edit THIS script, not the generated files. The changes persist
# in the volume across recreation.
#
# Run once after a *fresh* setup (new volume), and again whenever you change the
# block, SEAHUB_WORKERS, or the SMTP_* values in the env file. Requires the
# seafile-server container to be up (it edits the generated conf via
# `docker compose cp`).
#
# Two settings are intentionally left OFF (commented in the block) because they
# break the admin password->token API login that the clients and scripts/verify.sh
# use, and can self-lock the single admin account:
#   FREEZE_USER_ON_LOGIN_FAILED   — deactivates an account after failed logins
#   ENABLE_FORCE_2FA_TO_ALL_USERS — makes /api2/auth-token/ require an OTP header
set -euo pipefail
cd "$(dirname "$0")/.."

# Mail settings come from the SAME SMTP_* keys Vaultwarden reads from the env
# file (see .env.example), so the credential is written down once. Read the keys
# out of the file rather than sourcing it — sourcing would export every secret in
# there into the `docker compose` child processes below.
ENV_FILE="${ENV_FILE:-.env}"
# Missing env file => every key reads empty, i.e. mail stays off (never fatal:
# the hardening block below does not depend on it).
read_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1
}

SEAHUB_CONF=/opt/seafile/conf/seahub_settings.py
GUNICORN_CONF=/opt/seafile/conf/gunicorn.conf.py
WORKERS="${SEAHUB_WORKERS:-2}"
BEGIN='# >>> pc-hardening (managed by scripts/harden-seafile.sh) >>>'
END='# <<< pc-hardening <<<'

TMP="$(mktemp)"
DESIRED="$(mktemp)"
BLOCK="$(mktemp)"
GTMP="$(mktemp)"
trap 'rm -f "$TMP" "$DESIRED" "$BLOCK" "$GTMP" "$GTMP.new"' EXIT

if ! docker compose cp seafile-server:"$SEAHUB_CONF" "$TMP" 2>/dev/null; then
  echo "Could not read $SEAHUB_CONF — is pc-seafile up and past first-run setup?" >&2
  exit 1
fi

# The desired managed block. Keep keys grouped; values may be Python expressions.
cat > "$BLOCK" <<'PYEOF'
# Cookies: ingress is HTTPS-only behind Caddy with HSTS, so never send these
# over a downgraded connection.
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SAMESITE = 'Strict'

# Account password strength (enforced when a password is set or changed).
USER_STRONG_PASSWORD_REQUIRED = True
USER_PASSWORD_MIN_LENGTH = 12
USER_PASSWORD_STRENGTH_LEVEL = 3        # need 3 of {lower, upper, digit, symbol}

# Brute-force: show a CAPTCHA after this many failed logins.
LOGIN_ATTEMPT_LIMIT = 3

# 2FA available to users (NOT forced — forcing breaks the password->token API).
ENABLE_TWO_FACTOR_AUTH = True

# No web self-registration.
ENABLE_SIGNUP = False

# Web session lifetime (image default is 2 weeks).
SESSION_COOKIE_AGE = 60 * 60 * 24 * 3   # 3 days

# Share links: require a strong password and a bounded expiry.
SHARE_LINK_FORCE_USE_PASSWORD = True
SHARE_LINK_PASSWORD_MIN_LENGTH = 10
SHARE_LINK_PASSWORD_STRENGTH_LEVEL = 3
SHARE_LINK_EXPIRE_DAYS_DEFAULT = 7
SHARE_LINK_EXPIRE_DAYS_MIN = 1
SHARE_LINK_EXPIRE_DAYS_MAX = 30

# Upload links: same treatment.
UPLOAD_LINK_FORCE_USE_PASSWORD = True
UPLOAD_LINK_EXPIRE_DAYS_DEFAULT = 7
UPLOAD_LINK_EXPIRE_DAYS_MIN = 1
UPLOAD_LINK_EXPIRE_DAYS_MAX = 30

# Minimum password for client-side-encrypted libraries.
REPO_PASSWORD_MIN_LENGTH = 12

# Opt-in, left off (see the script header for why):
#   FREEZE_USER_ON_LOGIN_FAILED = True
#   ENABLE_FORCE_2FA_TO_ALL_USERS = True
PYEOF

# Outgoing mail. An empty SMTP_HOST means "no mail" — the same switch Vaultwarden
# uses — so the block simply omits the EMAIL_* keys and Seahub keeps its default
# (console backend, i.e. mail is dropped).
SMTP_HOST="$(read_env SMTP_HOST)"
if [[ -n "$SMTP_HOST" ]]; then
  SMTP_PORT="$(read_env SMTP_PORT)"
  SMTP_USERNAME="$(read_env SMTP_USERNAME)"
  SMTP_PASSWORD="$(read_env SMTP_PASSWORD)"
  SMTP_FROM="$(read_env SMTP_FROM)"
  : "${SMTP_PORT:=587}"
  : "${SMTP_FROM:=$SMTP_USERNAME}"

  # Render as a Python single-quoted literal: a stray quote or backslash in a
  # password would otherwise be a syntax error in seahub_settings.py, which takes
  # Seahub down on the restart below rather than just failing to send. Backslashes
  # are escaped first, or the ones added for quotes would be escaped in turn.
  py_str() {
    printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"
  }

  # Port 465 is implicit TLS (SSL on connect); 587/25 use STARTTLS. Seahub is
  # Django, so these are the standard EMAIL_* settings and the two are exclusive.
  if [[ "$SMTP_PORT" == "465" ]]; then
    TLS_KEY=EMAIL_USE_SSL
  else
    TLS_KEY=EMAIL_USE_TLS
  fi

  {
    printf '\n# Outgoing mail — from the SMTP_* keys in %s.\n' "$ENV_FILE"
    printf 'EMAIL_HOST = %s\n' "$(py_str "$SMTP_HOST")"
    printf 'EMAIL_PORT = %s\n' "$SMTP_PORT"
    printf 'EMAIL_HOST_USER = %s\n' "$(py_str "$SMTP_USERNAME")"
    printf 'EMAIL_HOST_PASSWORD = %s\n' "$(py_str "$SMTP_PASSWORD")"
    printf '%s = True\n' "$TLS_KEY"
    printf 'DEFAULT_FROM_EMAIL = %s\n' "$(py_str "$SMTP_FROM")"
    printf 'SERVER_EMAIL = %s\n' "$(py_str "$SMTP_FROM")"
  } >> "$BLOCK"
fi

# Strip any previous managed block, then drop trailing blank lines so re-running
# can't accumulate them (idempotent spacing). The second awk prints up to the last
# non-blank line. awk keeps it portable across the macOS (BSD) and Ubuntu (GNU)
# hosts this repo targets.
awk -v b="$BEGIN" -v e="$END" '
  $0 == b { skip = 1 }
  skip != 1 { print }
  $0 == e { skip = 0 }
' "$TMP" \
  | awk 'NF { last = NR } { line[NR] = $0 } END { for (i = 1; i <= last; i++) print line[i] }' \
  > "$DESIRED"

# Append exactly one blank line, then the spaced, marked block.
{
  printf '\n%s\n' "$BEGIN"
  cat "$BLOCK"
  printf '%s\n' "$END"
} >> "$DESIRED"

changed=0

if diff -q "$TMP" "$DESIRED" >/dev/null 2>&1; then
  echo "seahub_settings.py already current."
else
  docker compose cp "$DESIRED" seafile-server:"$SEAHUB_CONF"
  echo "Wrote the pc-hardening block to seahub_settings.py."
  changed=1
fi

# Seahub gunicorn worker count (image default: workers = 5).
docker compose cp seafile-server:"$GUNICORN_CONF" "$GTMP"
if grep -qE "^workers = ${WORKERS}\$" "$GTMP"; then
  echo "Seahub already at ${WORKERS} workers."
else
  # Portable (BSD/GNU) edit via a second temp file.
  sed -E "s/^workers = .*/workers = ${WORKERS}/" "$GTMP" > "$GTMP.new"
  docker compose cp "$GTMP.new" seafile-server:"$GUNICORN_CONF"
  echo "Set seahub gunicorn workers to ${WORKERS}."
  changed=1
fi

if [[ "$changed" == 1 ]]; then
  docker compose restart seafile-server >/dev/null
  echo "Restarted Seafile."
else
  echo "Nothing to do."
fi
