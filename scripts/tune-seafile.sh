#!/usr/bin/env bash
# Reduce Seafile's seahub gunicorn worker count to fit the 4 GB RAM budget.
#
# Seafile generates conf/gunicorn.conf.py with `workers = 5` on first setup, into
# the seafile_data volume (5 Django workers × ~130 MB ≈ 650 MB). This idempotently
# rewrites it to a leaner worker count and restarts seahub. The change persists in
# the volume across container recreation; re-run only after a *fresh* setup
# (new volume) or to change the count. Override with SEAHUB_WORKERS=N.
set -euo pipefail
cd "$(dirname "$0")/.."

WORKERS="${SEAHUB_WORKERS:-2}"
CONF=/opt/seafile/conf/gunicorn.conf.py
TMP="$(mktemp)"
trap 'rm -f "$TMP" "$TMP.new"' EXIT

docker compose cp seafile-server:"$CONF" "$TMP"

if grep -qE "^workers = ${WORKERS}\$" "$TMP"; then
  echo "Seahub already at ${WORKERS} workers — nothing to do."
  exit 0
fi

# Portable (BSD/GNU) edit via a second temp file.
sed -E "s/^workers = .*/workers = ${WORKERS}/" "$TMP" > "$TMP.new"
mv "$TMP.new" "$TMP"

docker compose cp "$TMP" seafile-server:"$CONF"
docker compose restart seafile-server >/dev/null

echo "Set seahub gunicorn workers to ${WORKERS} and restarted Seafile."
