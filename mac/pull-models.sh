#!/usr/bin/env bash
# mac/pull-models.sh - pull the Ollama models this homelab expects.
#
# Talks to the Ollama API at OLLAMA_URL (default http://dorkmini:11434), so it
# can run on the Mac itself or from any tailnet device with the ollama CLI.
# Idempotent: models already present are skipped (use --force to re-pull,
# which also fetches updated tags).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"

# Small models that also fit a Raspberry Pi 4B (see docs/models.md).
PI_MODELS="llama3.2:3b smollm2:1.7b functiongemma:270m nomic-embed-text-v2-moe"
# Models served by dorkmini by default (Hermes default + the Pi-sized set).
MAC_MODELS="qwen3.5:4b $PI_MODELS"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--set mac|pi] [--force] [--list]

  --set mac   Hermes default + small models + MAC_EXTRA_MODELS from .env (default)
  --set pi    Only the Pi-compatible small models
  --force     Re-pull even if the model is already present
  --list      Print the model list and exit
  -h, --help  Show this help

Environment: OLLAMA_URL (default http://dorkmini:11434), MAC_EXTRA_MODELS.
EOF
}

SET="mac" FORCE=0 LIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --set) SET="${2:?--set needs mac or pi}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --list) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

load_env optional
case "$SET" in
  mac) MODELS="$MAC_MODELS ${MAC_EXTRA_MODELS:-}" ;;
  pi)  MODELS="$PI_MODELS" ;;
  *)   die "--set must be 'mac' or 'pi'" ;;
esac

if [[ "$LIST" -eq 1 ]]; then
  for m in $MODELS; do echo "$m"; done
  exit 0
fi

require_cmd ollama
OLLAMA_URL="${OLLAMA_URL:-http://dorkmini:11434}"
export OLLAMA_HOST="$OLLAMA_URL"

installed="$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')" \
  || die "cannot reach Ollama at $OLLAMA_URL"

failed=0
for model in $MODELS; do
  # `ollama list` shows untagged models as name:latest.
  want="$model"; [[ "$want" == *:* ]] || want="$want:latest"
  if [[ "$FORCE" -eq 0 ]] && printf '%s\n' "$installed" | grep -qxF "$want"; then
    log "present: $model"
    continue
  fi
  log "pulling: $model"
  if ! ollama pull "$model"; then
    warn "failed to pull $model"
    failed=$((failed + 1))
  fi
done

[[ "$failed" -eq 0 ]] || die "$failed model(s) failed to pull"
log "all models present on $OLLAMA_URL"
