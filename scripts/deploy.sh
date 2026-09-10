#!/usr/bin/env bash
# Copy this working tree to the production host and reconcile the stack.
#
#   ./scripts/deploy.sh root@<server>
#
# The host has no git checkout, so whatever is in the working tree at copy time
# is what ships, committed or not. The branch check below is the only guard;
# uncommitted edits deploy the same as committed ones.
#
# Image versions are NOT set on the host. .env.production here is the source of
# truth; this script copies it to /root/.env.production (outside the deploy dir,
# so a re-copy never exposes it) and Compose reads it from there. Editing the
# host's copy by hand would make the next deploy silently revert it.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 root@<server>" >&2; exit 1; }
DEPLOY_DIR="${DEPLOY_DIR:-/opt/private-cloud}"
ENV_FILE="${ENV_FILE:-.env.production}"

[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found -- see the README" >&2; exit 1; }

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == "main" ]] || { echo "on '$branch', not main -- the working tree is what ships" >&2; exit 1; }

if grep -qn 'CHANGEME' "$ENV_FILE"; then
  echo "$ENV_FILE still contains CHANGEME placeholders" >&2
  exit 1
fi

echo "==> $ENV_FILE -> $TARGET:/root/.env.production"
# Keep one generation back: a bad value here takes the whole stack down, and the
# host's copy is the only one that was known to boot.
ssh "$TARGET" 'cp -a /root/.env.production /root/.env.production.bak 2>/dev/null || true'
scp -q "$ENV_FILE" "$TARGET:/root/.env.production"
ssh "$TARGET" 'chmod 600 /root/.env.production'

echo "==> working tree -> $TARGET:$DEPLOY_DIR"
# The deploy dir matches the tracked tree minus the env templates: excluded
# files never ship, and --delete-excluded removes them from the host too. The
# host's only env file is /root/.env.production, copied above.
rsync -a --delete --delete-excluded \
  --exclude-from=.gitignore \
  --exclude '*.example' \
  --exclude '.claude' \
  --exclude '.git' \
  ./ "$TARGET:$DEPLOY_DIR/"

echo "==> docker compose up -d"
ssh "$TARGET" "cd $DEPLOY_DIR && . scripts/prod.env && docker compose up -d"

echo "==> running images"
ssh "$TARGET" 'docker ps --format "{{.Names}}\t{{.Image}}" | sort'
