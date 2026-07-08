#!/usr/bin/env bash
# Generate the env files from their templates with strong random secrets. Writes
# TWO files (see README "Secrets: setup vs runtime"):
#   - the RUNTIME file (ENV_FILE)        — machine secrets Compose loads on every `up`
#   - the SETUP file   (ENV_FILE.setup)  — the initial Seafile admin secret, loaded
#                                          only during provisioning / by verify.sh
# Re-run with --force to regenerate (overwrites existing secrets in BOTH files!).
#
#   ./scripts/init.sh                       # local:      .env + .env.setup
#   ENV_FILE=.env.production \
#     EXAMPLE=.env.production.example \
#     GEN_SB_PASSWORD=0 ./scripts/init.sh   # production:  .env.production + .env.production.setup
#                                           #              (keep SB_PASSWORD — set it by hand)
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="${ENV_FILE:-.env}"
EXAMPLE="${EXAMPLE:-.env.example}"
# Setup-only secrets (initial admin accounts) live next to the runtime file; the
# template is shared between local and production.
SETUP_FILE="${SETUP_FILE:-${ENV_FILE}.setup}"
SETUP_EXAMPLE="${SETUP_EXAMPLE:-.env.setup.example}"
# The Storage Box password is generated for the local simulator but must be left
# alone in production (it's the real box's password — set GEN_SB_PASSWORD=0).
GEN_SB_PASSWORD="${GEN_SB_PASSWORD:-1}"

for f in "$ENV_FILE" "$SETUP_FILE"; do
  if [[ -f "$f" && "${1:-}" != "--force" ]]; then
    echo "$f already exists. Re-run with: $0 --force   (this overwrites secrets)" >&2
    exit 1
  fi
done

# Alphanumeric only — safe inside Postgres URLs and Immich's DB password rules.
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-40}"; }

# Portable in-place sed (GNU vs BSD/macOS).
sed_i() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

cp "$EXAMPLE" "$ENV_FILE"
cp "$SETUP_EXAMPLE" "$SETUP_FILE"

# set_kv FILE KEY VALUE
set_kv() { sed_i "s|^$2=.*|$2=$3|" "$1"; }

# Runtime secrets -> the runtime file.
set_kv "$ENV_FILE" IMMICH_DB_PASSWORD       "$(gen)"
set_kv "$ENV_FILE" IMMICH_REDIS_PASSWORD    "$(gen)"
set_kv "$ENV_FILE" SEAFILE_DB_ROOT_PASSWORD "$(gen)"
set_kv "$ENV_FILE" SEAFILE_DB_PASSWORD      "$(gen)"
set_kv "$ENV_FILE" SEAFILE_REDIS_PASSWORD   "$(gen)"
set_kv "$ENV_FILE" SEAFILE_JWT_KEY          "$(gen 44)"
[[ "$GEN_SB_PASSWORD" == "1" ]] && set_kv "$ENV_FILE" SB_PASSWORD "$(gen)"

# Setup-only secrets -> the setup file: the initial Seafile admin password.
set_kv "$SETUP_FILE" SEAFILE_ADMIN_PASSWORD "$(gen 24)"

chmod 600 "$ENV_FILE" "$SETUP_FILE"

echo "Wrote $ENV_FILE + $SETUP_FILE (chmod 600) with fresh secrets."
echo
echo "Seafile admin credentials (stored in $SETUP_FILE — save them in Vaultwarden):"
grep -E '^(SEAFILE_ADMIN_EMAIL|SEAFILE_ADMIN_PASSWORD)=' "$SETUP_FILE" \
  | sed 's/^/  /'
echo
echo "Next — the FIRST 'up' adds the setup overlay + setup env file (seeds the admins):"
if [[ "$ENV_FILE" == ".env" ]]; then
  echo "  docker compose -f docker-compose.yml -f docker-compose.storagebox-sim.yml \\"
  echo "    -f docker-compose.setup.yml --env-file .env --env-file .env.setup up -d"
  echo "Then register the Immich + Vaultwarden first accounts in the browser (while"
  echo "the setup overlay is up), and run:  ./scripts/verify.sh"
  echo "Day-to-day afterwards is just:  docker compose up -d"
else
  echo "  source scripts/prod.env"
  echo "  docker compose -f docker-compose.yml -f docker-compose.production.yml \\"
  echo "    -f docker-compose.setup.yml \\"
  echo "    --env-file $ENV_FILE --env-file $SETUP_FILE up -d"
  echo "Then register the Immich + Vaultwarden first accounts in the browser (while"
  echo "the setup overlay is up), and run:  ./scripts/verify.sh"
  echo "Day-to-day afterwards is just:  docker compose up -d"
fi
