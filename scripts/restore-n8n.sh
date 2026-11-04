#!/usr/bin/env bash
# scripts/restore-n8n.sh - restore the n8n data volume from an archive made by
# backup-n8n.sh.
#
# Verifies checksum and tar integrity first, takes a "pre-restore" safety
# backup of the current volume, stops n8n, replaces the volume contents,
# starts n8n and waits for it to become healthy.
# Re-running with the same archive yields the same state (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] (ARCHIVE | --latest)

  ARCHIVE              Path to n8n-data-*.tar.gz
  --latest             Use the newest archive in BACKUP_DIR
  --yes                Do not ask for confirmation (required when not on a TTY)
  --no-safety-backup   Skip the pre-restore backup of the current volume
  --timeout N          Seconds to wait for n8n to be healthy (default 240)
  --env-file FILE      Use another env file
  -h, --help           Show this help

The archive must come from an n8n using the same N8N_ENCRYPTION_KEY as .env.
EOF
}

ARCHIVE="" LATEST=0 YES=0 SAFETY=1 TIMEOUT=240
while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest) LATEST=1; shift ;;
    --yes) YES=1; shift ;;
    --no-safety-backup) SAFETY=0; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) ARCHIVE="$1"; shift ;;
  esac
done

load_env optional
require_cmd docker sha256sum
DIR="${BACKUP_DIR:-/srv/n8n-backups}"
VOLUME="${N8N_VOLUME_NAME:-n8n_data}"
CONTAINER="${N8N_CONTAINER:-n8n}"
HELPER="${BACKUP_HELPER_IMAGE:-docker.io/library/alpine:3.20}"

if [[ "$LATEST" -eq 1 ]]; then
  [[ -z "$ARCHIVE" ]] || die "give either ARCHIVE or --latest, not both"
  ARCHIVE="$(find "$DIR" -maxdepth 1 -type f -name 'n8n-data-*.tar.gz' -printf '%T@ %p\n' \
             | sort -rn | head -n1 | cut -d' ' -f2-)"
  [[ -n "$ARCHIVE" ]] || die "no archives found in $DIR"
fi
[[ -n "$ARCHIVE" ]] || { usage >&2; die "no archive given"; }
[[ -f "$ARCHIVE" ]] || die "archive not found: $ARCHIVE"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
ADIR="$(dirname "$ARCHIVE")"
ANAME="$(basename "$ARCHIVE")"

acquire_lock restore

if [[ -f "$ARCHIVE.sha256" ]]; then
  (cd "$ADIR" && sha256sum -c --status "$ANAME.sha256") || die "checksum mismatch for $ANAME"
  log "checksum ok"
else
  warn "no $ANAME.sha256 found; skipping checksum verification"
fi
tar -tzf "$ARCHIVE" >/dev/null || die "archive is corrupt: $ANAME"

if [[ "$YES" -eq 0 ]]; then
  [[ -t 0 ]] || die "not a terminal; pass --yes to confirm"
  read -r -p "Replace contents of volume '$VOLUME' with $ANAME? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "aborted"
fi

if [[ "$SAFETY" -eq 1 ]] && docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  log "taking pre-restore safety backup"
  "$SCRIPT_DIR/backup-n8n.sh" --label pre-restore --no-stop >/dev/null
fi

if container_running "$CONTAINER"; then
  log "stopping $CONTAINER"
  docker stop -t 60 "$CONTAINER" >/dev/null
fi

docker volume create "$VOLUME" >/dev/null
log "restoring $ANAME into volume $VOLUME"
docker run --rm \
  -v "$VOLUME:/data" \
  -v "$ADIR:/backup:ro" \
  "$HELPER" \
  sh -c "find /data -mindepth 1 -delete && tar -xzf '/backup/$ANAME' -C /data"

if container_exists "$CONTAINER"; then
  docker start "$CONTAINER" >/dev/null
  if wait_for_healthy "$CONTAINER" "$TIMEOUT"; then
    log "restore complete; $CONTAINER is healthy"
  else
    die "restored, but $CONTAINER is not healthy; check: docker logs $CONTAINER"
  fi
else
  log "restore complete; container $CONTAINER does not exist yet, run: make up-pi"
fi
