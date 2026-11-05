#!/usr/bin/env bash
# scripts/update.sh - safely update image-based services on the Pi
# (n8n and LiteLLM; the dashboard is rebuilt by `make up-pi`).
#
# Per service:
# 1. Pull the image (the service keeps running). If the image did not change
#    and the container is healthy, nothing to do (idempotent).
# 2. n8n only: take a "pre-update" backup. Recreate, wait for healthy.
# 3. On failure: re-tag the previous image and recreate (rollback). n8n only:
#    if that is still unhealthy (e.g. the new version migrated the DB),
#    restore the pre-update backup.
# Exit codes: 0 updated/up to date, 2 rolled back, 3 rolled back + restored,
# 1 anything else. With --service all the highest code wins.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--service n8n|litellm|all] [--timeout SECONDS] [--no-backup] [--env-file FILE]

  --service NAME   What to update (default: n8n)
  --timeout N      Seconds to wait for health (default 240)
  --no-backup      Skip the n8n pre-update backup (disables restore-on-rollback)
  --env-file FILE  Use another env file
  -h, --help       Show this help
EOF
}

SERVICE=n8n TIMEOUT=240 BACKUP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="${2:?--service needs a name}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --no-backup) BACKUP=0; shift ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
case "$SERVICE" in n8n|litellm|all) ;; *) die "--service must be n8n, litellm or all" ;; esac

load_env required
require_cmd docker
acquire_lock update

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

svc_version() { # service container
  case "$1" in
    n8n) docker exec "$2" n8n --version 2>/dev/null || echo unknown ;;
    litellm) docker exec "$2" python -c 'import importlib.metadata as m; print(m.version("litellm"))' 2>/dev/null || echo unknown ;;
  esac
}

update_service() { # service -> return code as documented above
  local svc="$1" image container rollback_tag old_id new_id old_version backup_path=""
  case "$svc" in
    n8n) image="${N8N_IMAGE:-docker.io/n8nio/n8n:latest}"; container="${N8N_CONTAINER:-n8n}" ;;
    litellm) image="${LITELLM_IMAGE:-docker.io/litellm/litellm:main-stable}"; container=litellm ;;
  esac
  rollback_tag="homelab/$svc:rollback"

  # Compare tag IDs, not the container's .Image: with Docker's containerd image
  # store those are different digests for the same image.
  old_id="$(image_id "$image")"
  old_version="$(container_running "$container" && svc_version "$svc" "$container" || echo none)"

  log "[$svc] pulling $image"
  # set -e is suspended inside this function (called under ||): check each step.
  compose_pi pull "$svc" || { warn "[$svc] pull failed (network/registry?)"; return 1; }
  new_id="$(image_id "$image")"

  if [[ -n "$old_id" && "$old_id" == "$new_id" ]] && wait_for_healthy "$container" 30; then
    log "[$svc] already up to date ($old_version); nothing to do"
    return 0
  fi

  if [[ "$svc" == n8n && "$BACKUP" -eq 1 ]] && docker volume inspect "${N8N_VOLUME_NAME:-n8n_data}" >/dev/null 2>&1; then
    backup_path="$("$SCRIPT_DIR/backup-n8n.sh" --label pre-update)" \
      || { warn "[$svc] pre-update backup failed; not updating"; return 1; }
    log "[$svc] pre-update backup: $backup_path"
  fi

  # Keep a reference to the old image so `docker image prune` cannot remove it.
  [[ -z "$old_id" ]] || docker tag "$old_id" "$rollback_tag"

  log "[$svc] recreating on the new image"
  compose_pi up -d --pull never "$svc" || warn "[$svc] compose up failed"
  if wait_for_healthy "$container" "$TIMEOUT"; then
    log "[$svc] update ok: $old_version -> $(svc_version "$svc" "$container")"
    return 0
  fi

  warn "[$svc] new image is unhealthy"
  [[ -n "$old_id" ]] || { warn "[$svc] no previous image to roll back to; check: docker logs $container"; return 1; }

  log "[$svc] rolling back to previous image"
  docker tag "$old_id" "$image" || { warn "[$svc] re-tag failed"; return 1; }
  compose_pi up -d --pull never --force-recreate "$svc" || warn "[$svc] compose up failed"
  if wait_for_healthy "$container" "$TIMEOUT"; then
    warn "[$svc] rolled back to $old_version; investigate before retrying"
    return 2
  fi

  if [[ "$svc" != n8n || -z "$backup_path" ]]; then
    warn "[$svc] rollback unhealthy; see docs/runbook.md"
    return 1
  fi
  warn "[$svc] rollback still unhealthy (DB likely migrated); restoring $backup_path"
  "$SCRIPT_DIR/restore-n8n.sh" --yes --no-safety-backup --timeout "$TIMEOUT" "$backup_path" \
    || { warn "[$svc] restore failed; see docs/runbook.md"; return 1; }
  warn "[$svc] rolled back and restored pre-update data"
  return 3
}

services=("$SERVICE")
[[ "$SERVICE" != all ]] || services=(n8n litellm)
worst=0
for svc in "${services[@]}"; do
  rc=0
  update_service "$svc" || rc=$?
  if [[ "$rc" -eq 1 && "$worst" -lt 1 ]] || [[ "$rc" -gt "$worst" ]]; then worst="$rc"; fi
done
exit "$worst"
