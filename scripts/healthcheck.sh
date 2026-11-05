#!/usr/bin/env bash
# scripts/healthcheck.sh - check the homelab and print an OK/FAIL table.
#
# Checks: Tailscale backend state (if the CLI is on this host), n8n /healthz,
# OpenClaw /healthz (when OPENCLAW_URL is set), dashboard /healthz,
# Ollama /api/version + required models, LiteLLM /health/liveliness.
# Read-only and safe to run anywhere on the tailnet (Pi or Mac; bash 3.2 ok).
# Exit code: 0 if nothing FAILed, 1 otherwise (SKIP does not fail).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env-file FILE] [--timeout SECONDS]

Endpoints come from the env file (default: repo .env):
  N8N_URL, OLLAMA_URL, LITELLM_URL, OPENCLAW_URL, DASHBOARD_URL,
  HEALTHCHECK_REQUIRED_MODELS
An empty URL marks that check SKIP.

  --env-file FILE   Use another env file
  --timeout N       Per-request timeout in seconds (default 8)
  -h, --help        Show this help
EOF
}

TIMEOUT=8
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

load_env optional
require_cmd curl
N8N_URL="${N8N_URL-http://n8npi:5678}"
OLLAMA_URL="${OLLAMA_URL-http://dorkmini:11434}"
LITELLM_URL="${LITELLM_URL-http://n8npi:4000}"
OPENCLAW_URL="${OPENCLAW_URL-}"
DASHBOARD_URL="${DASHBOARD_URL-http://n8npi:8080}"
REQUIRED_MODELS="${HEALTHCHECK_REQUIRED_MODELS-qwen3.5:4b}"

NAMES=() STATES=() DETAILS=()
record() { NAMES+=("$1"); STATES+=("$2"); DETAILS+=("$3"); }

BODY="" CODE=""
# http_get URL -> sets globals CODE ("000" on connection failure) and BODY.
# Not called via $(...) so the globals survive.
http_get() {
  local tmp
  tmp="$(mktemp)"
  CODE="$(curl -sS -m "$TIMEOUT" -o "$tmp" -w '%{http_code}' "$1" 2>/dev/null)" || CODE="000"
  BODY="$(cat "$tmp")"
  rm -f "$tmp"
}

check_tailscale() {
  local ts state
  ts="$(command -v tailscale || true)"
  if [[ -z "$ts" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
  if [[ -z "$ts" ]]; then
    record tailscale SKIP "tailscale CLI not on this host"
    return
  fi
  state="$("$ts" status --json 2>/dev/null \
    | grep -o '"BackendState"[^,]*' | head -n1 | sed 's/.*: *"\(.*\)"/\1/')" || state=""
  if [[ "$state" == "Running" ]]; then
    record tailscale OK "BackendState=Running"
  else
    record tailscale FAIL "BackendState=${state:-unknown} (try: tailscale up)"
  fi
}

check_http() { # name url expect_substring
  local name="$1" url="$2" expect="$3"
  if [[ -z "$url" ]]; then
    record "$name" SKIP "no URL configured"
    return
  fi
  http_get "$url"
  if [[ "$CODE" == 2* ]] && [[ -z "$expect" || "$BODY" == *"$expect"* ]]; then
    record "$name" OK "HTTP $CODE $url"
  else
    record "$name" FAIL "HTTP $CODE $url"
  fi
}

check_ollama() {
  local version missing="" m want
  if [[ -z "$OLLAMA_URL" ]]; then
    record ollama SKIP "no URL configured"
    return
  fi
  http_get "$OLLAMA_URL/api/version"
  if [[ "$CODE" != 2* ]]; then
    record ollama FAIL "HTTP $CODE $OLLAMA_URL (Mac asleep? bound to TS IP?)"
    record ollama-models SKIP "Ollama unreachable"
    return
  fi
  version="$(printf '%s' "$BODY" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')"
  record ollama OK "v${version:-?} $OLLAMA_URL"

  [[ -n "$REQUIRED_MODELS" ]] || { record ollama-models SKIP "none required"; return; }
  http_get "$OLLAMA_URL/api/tags"
  for m in $REQUIRED_MODELS; do
    want="$m"; [[ "$want" == *:* ]] || want="$want:latest"
    [[ "$BODY" == *"\"$want\""* ]] || missing="$missing $m"
  done
  if [[ "$CODE" == 2* && -z "$missing" ]]; then
    record ollama-models OK "$REQUIRED_MODELS"
  else
    record ollama-models FAIL "missing:${missing:- (HTTP $CODE)} (run mac/pull-models.sh)"
  fi
}

check_tailscale
check_http n8n "${N8N_URL:+$N8N_URL/healthz}" '"ok"'
check_ollama
check_http litellm "${LITELLM_URL:+$LITELLM_URL/health/liveliness}" ""
check_http openclaw "${OPENCLAW_URL:+$OPENCLAW_URL/healthz}" ""
check_http dashboard "${DASHBOARD_URL:+$DASHBOARD_URL/healthz}" '"ok"'

fails=0
printf '%-14s %-6s %s\n' CHECK STATUS DETAIL
printf '%-14s %-6s %s\n' -------------- ------ ------------------------------
for i in "${!NAMES[@]}"; do
  printf '%-14s %-6s %s\n' "${NAMES[$i]}" "${STATES[$i]}" "${DETAILS[$i]}"
  [[ "${STATES[$i]}" != FAIL ]] || fails=$((fails + 1))
done

if [[ "$fails" -gt 0 ]]; then
  echo "RESULT: $fails check(s) FAILED (see docs/runbook.md)"
  exit 1
fi
echo "RESULT: all checks OK"
