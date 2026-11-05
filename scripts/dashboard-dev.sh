#!/usr/bin/env bash
# scripts/dashboard-dev.sh - run the dashboard server directly (no Docker) for
# local development or a quick look from any tailnet machine.
#
# Loads the repo .env, maps the in-container settings to host equivalents
# (n8n via N8N_URL, backup status from BACKUP_DIR), and serves on loopback
# by default. Needs python3 (3.9+), nothing else. Stop with Ctrl-C.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env-file FILE] [--host ADDR] [--port N]

  --env-file FILE  Env file to load (default: repo .env)
  --host ADDR      Listen address (default 127.0.0.1)
  --port N         Listen port (default 8080)
  -h, --help       Show this help

Open http://<host>:<port>/ and enter DASHBOARD_TOKEN from the env file.
EOF
}

HOST=127.0.0.1 PORT=8080
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    --host) HOST="${2:?--host needs a value}"; shift 2 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

load_env required
require_cmd python3
export DASHBOARD_N8N_URL="${DASHBOARD_N8N_URL:-${N8N_URL:-http://n8npi:5678}}"
export BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-${BACKUP_DIR:-/srv/n8n-backups}/status/status.json}"
log "dashboard on http://$HOST:$PORT (n8n: $DASHBOARD_N8N_URL)"
exec python3 "$REPO_ROOT/dashboard/server.py" --host "$HOST" --port "$PORT"
