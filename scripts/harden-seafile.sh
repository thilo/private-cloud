#!/usr/bin/env bash
# Apply the Seafile config this stack needs but the seafile-mc image will not take
# from compose `environment:`. Two files, both generated into the seafile_data
# volume on first setup:
#
#   conf/seahub_settings.py  — Seahub security settings (managed block, below)
#   conf/gunicorn.conf.py    — seahub worker count 5 -> ${SEAHUB_WORKERS:-2}
#                              (5 Django workers x ~130 MB blow the 4 GB budget)
#
# The image only maps a fixed allow-list of env vars into its config (DB creds,
# admin, hostname, JWT, the ENABLE_* feature toggles). Arbitrary Seahub keys such
# as CSRF_COOKIE_SECURE / LOGIN_ATTEMPT_LIMIT / SHARE_LINK_* are ignored there and
# must live in conf/seahub_settings.py — a Python file, so some values are
# expressions. This idempotently writes a single MANAGED block (between the markers
# below) into that file, sets the worker count, and restarts Seafile once iff
# anything changed. Re-running replaces the block in place; edit THIS script, not
# the generated files. The changes persist in the volume across recreation.
#
# Run once after a *fresh* setup (new volume), and again whenever you change the
# block or SEAHUB_WORKERS. Requires the seafile-server container to be up (it
# edits the generated conf via `docker compose cp`).
#
# Two settings are intentionally left OFF (commented in the block) because they
# break the admin password->token API login that the clients and scripts/verify.sh
# use, and can self-lock the single admin account:
#   FREEZE_USER_ON_LOGIN_FAILED   — deactivates an account after failed logins
#   ENABLE_FORCE_2FA_TO_ALL_USERS — makes /api2/auth-token/ require an OTP header
set -euo pipefail
cd "$(dirname "$0")/.."

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
