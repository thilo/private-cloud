#!/usr/bin/env bash
# Generate .env from .env.example with strong random secrets.
# Re-run with --force to regenerate (overwrites existing secrets!).
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=".env"
EXAMPLE=".env.example"

if [[ -f "$ENV_FILE" && "${1:-}" != "--force" ]]; then
  echo ".env already exists. Re-run with: $0 --force   (this overwrites secrets)" >&2
  exit 1
fi

# Alphanumeric only — safe inside Postgres URLs and Immich's DB password rules.
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-40}"; }

# Portable in-place sed (GNU vs BSD/macOS).
sed_i() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

cp "$EXAMPLE" "$ENV_FILE"

set_kv() { sed_i "s|^$1=.*|$1=$2|" "$ENV_FILE"; }

set_kv IMMICH_DB_PASSWORD       "$(gen)"
set_kv IMMICH_REDIS_PASSWORD    "$(gen)"
set_kv IMMICH_ADMIN_PASSWORD    "$(gen 24)"
set_kv SEAFILE_DB_ROOT_PASSWORD "$(gen)"
set_kv SEAFILE_DB_PASSWORD      "$(gen)"
set_kv SEAFILE_REDIS_PASSWORD   "$(gen)"
set_kv SEAFILE_JWT_KEY          "$(gen 44)"
set_kv SEAFILE_ADMIN_PASSWORD   "$(gen 24)"

chmod 600 "$ENV_FILE"

echo "Wrote $ENV_FILE (chmod 600) with fresh secrets."
echo
echo "Admin credentials (also stored in .env):"
grep -E '^(IMMICH_ADMIN_EMAIL|IMMICH_ADMIN_PASSWORD|SEAFILE_ADMIN_EMAIL|SEAFILE_ADMIN_PASSWORD)=' "$ENV_FILE" \
  | sed 's/^/  /'
echo
echo "Next:  docker compose up -d  &&  ./scripts/bootstrap.sh"
