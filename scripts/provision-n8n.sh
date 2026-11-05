#!/usr/bin/env bash
# scripts/provision-n8n.sh - create the n8n credentials and import + activate
# the workflows in n8n-workflows/ from values in .env. No clicking in the UI.
#
# Credentials (fixed IDs, so re-running updates them in place):
#   Telegram bot        <- TELEGRAM_BOT_TOKEN       (workflows 1 and 3)
#   n8n webhook token   <- N8N_WEBHOOK_TOKEN        (workflow 2, header X-Webhook-Token)
#   LiteLLM master key  <- LITELLM_MASTER_KEY       (workflow 2)
# Each workflow's Config node gets TELEGRAM_CHAT_ID and the in-container URLs.
# Without TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID only workflow 2 is provisioned.
#
# Secrets are piped into the container over stdin and deleted afterwards; they
# never appear on a command line. Idempotent. Run on n8npi after `make up-pi`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--no-activate] [--no-verify] [--env-file FILE]

  --no-activate    Import but leave workflows inactive
  --no-verify      Skip the webhook round-trip check at the end
  --env-file FILE  Use another env file
  -h, --help       Show this help

Needs in .env: LITELLM_MASTER_KEY, N8N_WEBHOOK_TOKEN, and for the Telegram
workflows TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID (see docs/runbook.md for how
to get a chat ID).
EOF
}

ACTIVATE=1 VERIFY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-activate) ACTIVATE=0; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

load_env required
require_cmd docker python3 curl
CONTAINER="${N8N_CONTAINER:-n8n}"
WORKFLOW_DIR="$REPO_ROOT/n8n-workflows"
IN_CONTAINER_DIR="/tmp/homelab-provision"
# A second n8n CLI process must not grab the running server's task-broker port.
N8N_CLI=(docker exec -e N8N_RUNNERS_BROKER_PORT=5690 "$CONTAINER" n8n)

is_placeholder() { [[ -z "$1" || "$1" == replace-with* || "$1" == sk-replace-me ]]; }

is_placeholder "${LITELLM_MASTER_KEY:-}" && die "LITELLM_MASTER_KEY is not set (run scripts/install-pi.sh)"
if is_placeholder "${N8N_WEBHOOK_TOKEN:-}" || [[ ${#N8N_WEBHOOK_TOKEN} -lt 16 ]]; then
  die "N8N_WEBHOOK_TOKEN must be 16+ random characters (run scripts/install-pi.sh)"
fi
TELEGRAM=1
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  TELEGRAM=0
  warn "TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not set: provisioning only the webhook workflow"
fi

container_running "$CONTAINER" || die "container $CONTAINER is not running (make up-pi)"
wait_for_healthy "$CONTAINER" 120 || die "$CONTAINER is not healthy"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
cleanup() {
  rm -rf -- "$WORK"
  docker exec "$CONTAINER" rm -rf -- "$IN_CONTAINER_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Render credentials + workflows. Values are read from the environment inside
# python, never passed as arguments.
TELEGRAM="$TELEGRAM" WORKFLOW_DIR="$WORKFLOW_DIR" OUT="$WORK" python3 -I - <<'PY'
import json, os, pathlib

env = os.environ
out = pathlib.Path(env["OUT"])
telegram = env["TELEGRAM"] == "1"

creds = [
    {"id": "hlWebhookToken01", "name": "n8n webhook token", "type": "httpHeaderAuth",
     "data": {"name": "X-Webhook-Token", "value": env["N8N_WEBHOOK_TOKEN"]}},
    {"id": "hlLitellmKey0001", "name": "LiteLLM master key", "type": "httpHeaderAuth",
     "data": {"name": "Authorization", "value": "Bearer " + env["LITELLM_MASTER_KEY"]}},
]
if telegram:
    creds.append({"id": "hlTelegramBot001", "name": "Telegram bot", "type": "telegramApi",
                  "data": {"accessToken": env["TELEGRAM_BOT_TOKEN"]}})
cred_ids = {(c["type"], c["name"]): c["id"] for c in creds}
(out / "credentials.json").write_text(json.dumps(creds))

config_values = {
    "telegram_chat_id": env.get("TELEGRAM_CHAT_ID", ""),
    # URLs as seen from inside the n8n container (compose network + extra_hosts).
    "litellm_url": "http://litellm:4000",
    "ollama_url": env.get("OLLAMA_URL", "http://dorkmini:11434"),
    "required_models": env.get("HEALTHCHECK_REQUIRED_MODELS", "qwen3.5:4b"),
}
ids = []
for path in sorted(pathlib.Path(env["WORKFLOW_DIR"]).glob("*.json")):
    wf = json.loads(path.read_text())
    types = {(t, n) for node in wf["nodes"] for t, ref in (node.get("credentials") or {}).items()
             for n in [ref["name"]]}
    if not telegram and any(t == "telegramApi" for t, _ in types):
        continue
    for node in wf["nodes"]:
        for ctype, ref in (node.get("credentials") or {}).items():
            ref["id"] = cred_ids[(ctype, ref["name"])]
        if node["name"] == "Config":
            for a in node["parameters"]["assignments"]["assignments"]:
                if a["name"] in config_values:
                    a["value"] = config_values[a["name"]]
    wf["active"] = False
    (out / path.name).write_text(json.dumps(wf))
    ids.append(wf["id"])
(out / "workflow-ids.txt").write_text("\n".join(ids) + "\n")
PY

copy_in() { # file -> container, as the container user, mode 600
  local src="$1" dest
  dest="$IN_CONTAINER_DIR/$(basename "$src")"
  docker exec -i "$CONTAINER" sh -c "umask 077 && mkdir -p '$IN_CONTAINER_DIR' && cat > '$dest'" < "$src"
}

log "importing credentials"
copy_in "$WORK/credentials.json"
"${N8N_CLI[@]}" import:credentials --input="$IN_CONTAINER_DIR/credentials.json" >/dev/null

mapfile -t WF_IDS < "$WORK/workflow-ids.txt"
for f in "$WORK"/*.json; do
  [[ "$(basename "$f")" == credentials.json ]] && continue
  log "importing workflow $(basename "$f")"
  copy_in "$f"
  "${N8N_CLI[@]}" import:workflow --input="$IN_CONTAINER_DIR/$(basename "$f")" >/dev/null
done

if [[ "$ACTIVATE" -eq 1 ]]; then
  for id in "${WF_IDS[@]}"; do
    "${N8N_CLI[@]}" publish:workflow --id="$id" >/dev/null
    log "activated $id"
  done
  log "restarting $CONTAINER so activation takes effect"
  docker restart "$CONTAINER" >/dev/null
  wait_for_healthy "$CONTAINER" 180 || die "$CONTAINER did not become healthy after restart"
fi

if [[ "$ACTIVATE" -eq 1 && "$VERIFY" -eq 1 ]]; then
  base="${N8N_WEBHOOK_URL:-http://n8npi:5678/}"
  url="${base%/}/webhook/llm-prompt"
  code=""
  # Header from a private file, so the token never shows up in `ps`.
  printf 'X-Webhook-Token: %s\nContent-Type: application/json\n' "$N8N_WEBHOOK_TOKEN" > "$WORK/headers"
  for _ in 1 2 3 4 5 6; do
    code="$(curl -sS -o /dev/null -m 20 -w '%{http_code}' -X POST "$url" -H "@$WORK/headers" \
      -d '{"prompt":"Reply with the single word: pong"}' 2>/dev/null)" || code="000"
    [[ "$code" == 404 || "$code" == 000 ]] || break
    sleep 5   # webhooks register a few seconds after the restart
  done
  case "$code" in
    200) log "verified: $url answered 200 (n8n -> LiteLLM round trip works)" ;;
    502) warn "webhook is live but LiteLLM/Ollama did not answer (502); check make health" ;;
    *)   die "webhook check failed: HTTP $code from $url" ;;
  esac
fi

log "provisioned ${#WF_IDS[@]} workflow(s); open ${N8N_URL:-http://n8npi:5678} to review"
