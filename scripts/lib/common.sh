#!/usr/bin/env bash
# scripts/lib/common.sh - shared helpers sourced by the scripts in this repo.
# Usage: source "$(dirname "$0")/lib/common.sh"
# Kept bash 3.2 compatible (macOS /bin/bash) because mac/ scripts use it too.
# shellcheck shell=bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "common.sh is a library: source it from another script (see header)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
COMPOSE_FILE_PI="$REPO_ROOT/pi/docker-compose.yml"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# load_env [required|optional] - export every KEY=VALUE from $ENV_FILE.
load_env() {
  local mode="${1:-optional}"
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  elif [[ "$mode" == "required" ]]; then
    die "env file not found: $ENV_FILE (cp .env.example .env and fill it in)"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

compose_pi() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE_PI" "$@"
}

# acquire_lock NAME - single-instance guard (Linux, needs flock).
acquire_lock() {
  local lockfile="${LOCK_DIR:-/tmp}/homelab-$1.lock"
  require_cmd flock
  exec 9>"$lockfile"
  flock -n 9 || die "another '$1' run is already in progress ($lockfile)"
}

container_exists() { docker container inspect "$1" >/dev/null 2>&1; }

container_running() {
  [[ "$(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

# wait_for_healthy CONTAINER [TIMEOUT_SECONDS]
wait_for_healthy() {
  local c="$1" timeout="${2:-180}" waited=0 status
  while (( waited < timeout )); do
    status="$(docker container inspect \
      -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$c" 2>/dev/null || echo missing)"
    if [[ "$status" == "healthy" ]]; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "container $c not healthy after ${timeout}s (last status: ${status:-unknown})"
  return 1
}
