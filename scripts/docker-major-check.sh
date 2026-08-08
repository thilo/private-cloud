#!/usr/bin/env bash
# Exit non-zero when a docker-ce major above DOCKER_MAJOR is available, so the
# OnFailure= hook mails about it — the same alert path pc-backup uses.
#
#   ./scripts/docker-major-check.sh
#
# Without this, the pin prod-setup.sh writes would become a silent freeze the
# first time a new major ships. See the env file for the pinning policy.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.production}"
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

: "${DOCKER_MAJOR:?not set in ${ENV_FILE}}"

# Reads the package lists only; apt-daily.timer refreshes them daily. The epoch
# ("5:") is stripped before the major is taken.
latest="$(apt-cache madison docker-ce 2>/dev/null \
          | awk '{print $3}' | sed 's/^[0-9]*://' | cut -d. -f1 \
          | sort -n | tail -1 || true)"

if [[ -z "$latest" ]]; then
  echo "no docker-ce candidates found — is the Docker repo still configured?" >&2
  exit 1
fi

if (( latest > DOCKER_MAJOR )); then
  echo "docker-ce ${latest}.x is available; this host is pinned to ${DOCKER_MAJOR}.x."
  echo
  echo "Docker backports fixes to the current major only, so ${DOCKER_MAJOR}.x will"
  echo "stop receiving them. To move up: raise DOCKER_MAJOR/CONTAINERD_MAJOR in"
  echo "the env file, run prod-setup.sh, then in a watched window run"
  echo "  apt-get install -y docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io"
  echo "and re-run prod-setup.sh to re-enable unattended patching."
  exit 1
fi

echo "docker-ce pinned at ${DOCKER_MAJOR}.x; no newer major available."
