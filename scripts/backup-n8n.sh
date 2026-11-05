#!/usr/bin/env bash
# scripts/backup-n8n.sh - back up the n8n data volume to a timestamped,
# checksummed .tar.gz and rotate old archives.
#
# By default n8n is stopped for the few seconds the archive takes, so the
# SQLite database is consistent, and restarted afterwards (also on failure).
# Writes BACKUP_DIR/status/status.json, which the weekly n8n report workflow
# reads. Prints the archive path on stdout; logs go to stderr.
# Safe to re-run: each run adds one archive, rotation bounds the total.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dir DIR] [--keep N] [--label LABEL] [--no-stop] [--env-file FILE]

  --dir DIR        Backup directory (default: BACKUP_DIR or /srv/n8n-backups)
  --keep N         Archives to keep after rotation (default: BACKUP_RETENTION or 14)
  --label LABEL    Add a label to the file name, e.g. pre-update
  --no-stop        Do not stop n8n (faster, but the DB copy may be inconsistent)
  --env-file FILE  Use another env file
  -h, --help       Show this help

Archive: n8n-data[-LABEL]-YYYYmmdd-HHMMSS.tar.gz (+ .sha256)
Remember: archives are useless without N8N_ENCRYPTION_KEY; keep .env backed up separately.
EOF
}

DIR="" KEEP="" LABEL="" STOP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="${2:?--dir needs a path}"; shift 2 ;;
    --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
    --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
    --no-stop) STOP=0; shift ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

load_env optional
require_cmd docker sha256sum
DIR="${DIR:-${BACKUP_DIR:-/srv/n8n-backups}}"
KEEP="${KEEP:-${BACKUP_RETENTION:-14}}"
VOLUME="${N8N_VOLUME_NAME:-n8n_data}"
CONTAINER="${N8N_CONTAINER:-n8n}"
HELPER="${BACKUP_HELPER_IMAGE:-docker.io/library/alpine:3.20}"
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive integer"
[[ -z "$LABEL" || "$LABEL" =~ ^[a-z0-9-]+$ ]] || die "--label may only contain a-z, 0-9 and -"

acquire_lock backup
docker volume inspect "$VOLUME" >/dev/null 2>&1 || die "docker volume '$VOLUME' does not exist"
mkdir -p "$DIR/status" || die "cannot create $DIR (sudo install -d -o $(id -un) $DIR)"
[[ -w "$DIR" && -w "$DIR/status" ]] \
  || die "$DIR not writable; fix with: sudo chown -R $(id -u):$(id -g) $DIR"

TS="$(date +%Y%m%d-%H%M%S)"
NAME="n8n-data${LABEL:+-$LABEL}-$TS.tar.gz"
STATUS_FILE="$DIR/status/status.json"
RESTART_NEEDED=0
DONE=0

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

write_status() { # result message [archive size sha count]
  local tmp
  tmp="$(mktemp "$DIR/status/.status.XXXXXX")"
  cat > "$tmp" <<EOF
{
  "last_run": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "result": "$1",
  "message": "$(json_escape "$2")",
  "archive": "${3:-}",
  "size_bytes": ${4:-0},
  "sha256": "${5:-}",
  "archive_count": ${6:-0},
  "retention": $KEEP,
  "backup_dir": "$(json_escape "$DIR")"
}
EOF
  chmod 644 "$tmp"
  mv -f "$tmp" "$STATUS_FILE"
}

cleanup() {
  local rc=$?
  rm -f "$DIR/$NAME.partial"
  if [[ "$RESTART_NEEDED" -eq 1 ]]; then
    log "restarting $CONTAINER"
    docker start "$CONTAINER" >/dev/null || warn "could not restart $CONTAINER"
  fi
  if [[ "$DONE" -eq 0 ]]; then
    write_status failed "backup failed with exit code $rc" || true
  fi
}
trap cleanup EXIT

if [[ "$STOP" -eq 1 ]] && container_running "$CONTAINER"; then
  log "stopping $CONTAINER for a consistent snapshot"
  docker stop -t 60 "$CONTAINER" >/dev/null
  RESTART_NEEDED=1
fi

log "archiving volume $VOLUME -> $DIR/$NAME"
docker run --rm \
  -v "$VOLUME:/data:ro" \
  -v "$DIR:/backup" \
  "$HELPER" \
  sh -c "tar -czf '/backup/$NAME.partial' -C /data . && chown $(id -u):$(id -g) '/backup/$NAME.partial'"

if [[ "$RESTART_NEEDED" -eq 1 ]]; then
  docker start "$CONTAINER" >/dev/null
  RESTART_NEEDED=0
fi

tar -tzf "$DIR/$NAME.partial" >/dev/null || die "archive failed integrity check"
mv -f "$DIR/$NAME.partial" "$DIR/$NAME"
(cd "$DIR" && sha256sum "$NAME" > "$NAME.sha256")

# Rotation: keep the newest $KEEP archives (names sort by timestamp per label,
# so sort by mtime instead to mix labels correctly).
count=0
while IFS= read -r old; do
  count=$((count + 1))
  if [[ "$count" -gt "$KEEP" ]]; then
    log "rotating out $(basename "$old")"
    rm -f "$old" "$old.sha256"
  fi
done < <(find "$DIR" -maxdepth 1 -type f -name 'n8n-data-*.tar.gz' -printf '%T@ %p\n' \
           | sort -rn | cut -d' ' -f2-)

SIZE="$(stat -c %s "$DIR/$NAME")"
SHA="$(cut -d' ' -f1 "$DIR/$NAME.sha256")"
REMAINING="$(find "$DIR" -maxdepth 1 -type f -name 'n8n-data-*.tar.gz' | wc -l | tr -d ' ')"
write_status ok "backup completed" "$NAME" "$SIZE" "$SHA" "$REMAINING"
DONE=1
log "backup ok: $NAME ($SIZE bytes, $REMAINING archive(s) kept)"
printf '%s\n' "$DIR/$NAME"
