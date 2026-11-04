#!/usr/bin/env bash
# scripts/update.sh - safely update n8n on the Pi.
#
# 1. Pull the image (n8n keeps running). If the image did not change and n8n
#    is healthy, exit: nothing to do (idempotent).
# 2. Take a "pre-update" backup, recreate the container, wait for healthy.
# 3. On failure: re-tag the previous image and recreate (rollback). If that is
#    still unhealthy (e.g. the new version migrated the DB), restore the
#    pre-update backup.
# Exit codes: 0 updated/up to date, 2 rolled back, 3 rolled back + restored,
# 1 anything else.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--timeout SECONDS] [--no-backup] [--env-file FILE]

  --timeout N      Seconds to wait for n8n to become healthy (default 240)
  --no-backup      Skip the pre-update backup (disables restore-on-rollback)
  --env-file FILE  Use another env file
  -h, --help       Show this help
EOF
}

TIMEOUT=240 BACKUP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --no-backup) BACKUP=0; shift ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

load_env required
require_cmd docker
IMAGE="${N8N_IMAGE:-docker.io/n8nio/n8n:latest}"
CONTAINER="${N8N_CONTAINER:-n8n}"
ROLLBACK_TAG="homelab/n8n:rollback"

acquire_lock update

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }
n8n_version() { docker exec "$CONTAINER" n8n --version 2>/dev/null || echo unknown; }

# Compare tag IDs, not the container's .Image: with Docker's containerd image
# store those are different digests for the same image.
OLD_ID="$(image_id "$IMAGE")"
OLD_VERSION="$(container_running "$CONTAINER" && n8n_version || echo none)"

log "pulling $IMAGE"
compose_pi pull n8n
NEW_ID="$(image_id "$IMAGE")"

if [[ -n "$OLD_ID" && "$OLD_ID" == "$NEW_ID" ]] && wait_for_healthy "$CONTAINER" 30; then
  log "already up to date (n8n $OLD_VERSION); nothing to do"
  exit 0
fi

BACKUP_PATH=""
if [[ "$BACKUP" -eq 1 ]] && docker volume inspect "${N8N_VOLUME_NAME:-n8n_data}" >/dev/null 2>&1; then
  BACKUP_PATH="$("$SCRIPT_DIR/backup-n8n.sh" --label pre-update)"
  log "pre-update backup: $BACKUP_PATH"
fi

# Keep a reference to the old image so `docker image prune` cannot remove it.
[[ -z "$OLD_ID" ]] || docker tag "$OLD_ID" "$ROLLBACK_TAG"

log "recreating n8n on the new image"
compose_pi up -d --pull never n8n
if wait_for_healthy "$CONTAINER" "$TIMEOUT"; then
  log "update ok: n8n $OLD_VERSION -> $(n8n_version)"
  exit 0
fi

warn "new image is unhealthy"
[[ -n "$OLD_ID" ]] || die "no previous image to roll back to; check: docker logs $CONTAINER"

log "rolling back to previous image"
docker tag "$OLD_ID" "$IMAGE"
compose_pi up -d --pull never --force-recreate n8n
if wait_for_healthy "$CONTAINER" "$TIMEOUT"; then
  warn "rolled back to n8n $OLD_VERSION; investigate before retrying"
  exit 2
fi

[[ -n "$BACKUP_PATH" ]] || die "rollback unhealthy and no pre-update backup; see docs/runbook.md"
warn "rollback still unhealthy (DB likely migrated); restoring $BACKUP_PATH"
"$SCRIPT_DIR/restore-n8n.sh" --yes --no-safety-backup --timeout "$TIMEOUT" "$BACKUP_PATH"
warn "rolled back and restored pre-update data"
exit 3
