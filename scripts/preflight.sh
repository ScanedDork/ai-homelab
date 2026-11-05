#!/usr/bin/env bash
# scripts/preflight.sh - check a real device is ready BEFORE deploying, and
# say exactly what to fix. Read-only. Prints an OK/WARN/FAIL table.
#
# On Linux (n8npi): .env completeness, Tailscale IP really on this host,
# Docker/compose, architecture, compose config, backup dir, systemd pieces,
# free ports, dorkmini reachable, encryption key vs existing n8n volume.
# On macOS (dorkmini): Ollama bound only to the Tailscale IP, LaunchAgent,
# Ollama.app conflict, sleep settings, required models.
# Exit code: 1 if any FAIL, else 0. `make up-pi` runs this first.
# `cond && add OK || add FAIL` is intentional: add() always succeeds.
# shellcheck disable=SC2015
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env-file FILE] [--role pi|mac] [--quiet]

  --env-file FILE  Env file to check (default: repo .env)
  --role ROLE      Force pi or mac checks (default: by OS)
  --quiet          Only print WARN/FAIL rows and the result
  -h, --help       Show this help
EOF
}

ROLE="" QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    --role) ROLE="${2:?--role needs pi or mac}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$ROLE" ]] || { [[ "$(uname -s)" == Darwin ]] && ROLE=mac || ROLE=pi; }

NAMES=() STATES=() DETAILS=()
add() { NAMES+=("$1"); STATES+=("$2"); DETAILS+=("$3"); }
is_placeholder() { [[ -z "$1" || "$1" == replace-with* || "$1" == sk-replace-me || "$1" == 127.0.0.1 ]]; }
is_ts_ip() { [[ "$1" =~ ^100\.([6-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+$ ]]; }

if [[ ! -f "$ENV_FILE" ]]; then
  # The Mac needs no .env (the installer asks tailscale for the IP).
  [[ "$ROLE" == mac ]] || add env FAIL "$ENV_FILE missing: run scripts/install-pi.sh (or cp .env.example .env)"
else
  load_env required
  perms="$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE")"
  if [[ "$perms" == 600 ]]; then add env-perms OK "$ENV_FILE is 600"
  else add env-perms WARN "$ENV_FILE is $perms; run: chmod 600 $ENV_FILE"; fi
fi

# ------------------------------------------------------------------ pi checks
pi_checks() {
  local k missing=() v
  for k in PI_TAILSCALE_IP MAC_TAILSCALE_IP N8N_ENCRYPTION_KEY DASHBOARD_TOKEN LITELLM_MASTER_KEY N8N_WEBHOOK_TOKEN; do
    v="${!k:-}"
    is_placeholder "$v" && missing+=("$k")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then add env-values OK "required values set"
  else add env-values FAIL "placeholder/empty: ${missing[*]} (scripts/install-pi.sh fills them)"; fi

  for k in PI_TAILSCALE_IP MAC_TAILSCALE_IP; do
    v="${!k:-}"
    is_placeholder "$v" && continue
    is_ts_ip "$v" || add "$k" WARN "$v is not in Tailscale's 100.64.0.0/10 range"  # secret-scan: allow
  done
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] \
    && add telegram OK "bot token + chat id set" \
    || add telegram WARN "TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID empty: no Telegram alerts"
  [[ -n "${GEMINI_API_KEY:-}${GROQ_API_KEY:-}${CEREBRAS_API_KEY:-}${OPENROUTER_API_KEY:-}" ]] \
    && add cloud-keys OK "at least one fallback provider key set" \
    || add cloud-keys WARN "no cloud keys: no LLM fallback while dorkmini is down"

  # Tailscale on this host
  if command -v tailscale >/dev/null 2>&1; then
    local state
    state="$(tailscale status --json 2>/dev/null | grep -o '"BackendState"[^,]*' | head -n1 | sed 's/.*: *"\(.*\)"/\1/' || true)"
    [[ "$state" == Running ]] && add tailscale OK "BackendState=Running" \
      || add tailscale FAIL "BackendState=${state:-unknown}: run sudo tailscale up"
    if ! is_placeholder "${PI_TAILSCALE_IP:-}"; then
      if tailscale ip -4 2>/dev/null | grep -qxF "$PI_TAILSCALE_IP"; then
        add pi-ip OK "$PI_TAILSCALE_IP is this host's Tailscale IP"
      else
        add pi-ip FAIL "$PI_TAILSCALE_IP is not this host's Tailscale IP ($(tailscale ip -4 2>/dev/null | head -n1))"
      fi
    fi
  else
    add tailscale FAIL "tailscale not installed (curl -fsSL https://tailscale.com/install.sh | sh)"
  fi
  if ! is_placeholder "${PI_TAILSCALE_IP:-}" && command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | grep -q " $PI_TAILSCALE_IP/" \
      || add pi-ip-bound FAIL "$PI_TAILSCALE_IP is not assigned to any interface yet; Docker cannot bind it"
  fi

  # Docker
  if ! command -v docker >/dev/null 2>&1; then
    add docker FAIL "docker not installed (curl -fsSL https://get.docker.com | sh)"
    return
  fi
  if docker info >/dev/null 2>&1; then add docker OK "daemon $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  else add docker FAIL "cannot reach Docker: sudo usermod -aG docker $(id -un), then log in again"; return; fi
  docker compose version >/dev/null 2>&1 && add compose OK "v$(docker compose version --short)" \
    || add compose FAIL "docker compose v2 missing (apt install docker-compose-plugin)"
  local arch; arch="$(uname -m)"
  case "$arch:${N8N_PLATFORM:-linux/arm64}" in
    aarch64:linux/arm64|arm64:linux/arm64|x86_64:linux/amd64) add arch OK "$arch matches N8N_PLATFORM" ;;
    *) add arch WARN "host $arch but N8N_PLATFORM=${N8N_PLATFORM:-linux/arm64} (images would run emulated)" ;;
  esac
  if compose_pi config --quiet 2>/dev/null; then add compose-config OK "pi/docker-compose.yml valid with $ENV_FILE"
  else add compose-config FAIL "compose config failed: docker compose --env-file $ENV_FILE -f pi/docker-compose.yml config"; fi

  # Encryption key vs existing volume
  local vol="${N8N_VOLUME_NAME:-n8n_data}" vkey
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    vkey="$(docker run --rm -v "$vol:/data:ro" "${BACKUP_HELPER_IMAGE:-docker.io/library/alpine:3.20}" cat /data/config 2>/dev/null \
      | sed -n 's/.*"encryptionKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
    if [[ -z "$vkey" ]]; then add n8n-key OK "volume $vol has no stored key (env key is authoritative)"
    elif [[ "$vkey" == "${N8N_ENCRYPTION_KEY:-}" ]]; then add n8n-key OK "matches existing volume $vol"
    else add n8n-key FAIL "differs from the key in volume $vol: credentials would be unreadable"; fi
  else
    add n8n-key OK "no existing volume $vol (fresh install)"
  fi

  # Backup dir
  local bd="${BACKUP_DIR:-/srv/n8n-backups}"
  if [[ -d "$bd/status" && -w "$bd" && -w "$bd/status" ]]; then add backup-dir OK "$bd writable"
  else add backup-dir FAIL "$bd/status missing or not writable: sudo install -d -o $(id -un) $bd $bd/status"; fi

  # systemd pieces
  if [[ -d /run/systemd/system ]]; then
    [[ -f /etc/systemd/system/docker.service.d/docker-wait-for-tailscale.conf ]] \
      && add docker-dropin OK "Docker waits for Tailscale at boot" \
      || add docker-dropin WARN "drop-in missing: n8n may fail to bind after reboot (scripts/install-pi.sh)"
    systemctl is-enabled --quiet "n8n-backup@$(id -un).timer" 2>/dev/null \
      && add backup-timer OK "n8n-backup@$(id -un).timer enabled" \
      || add backup-timer WARN "nightly backup timer not enabled (scripts/install-pi.sh)"
  fi

  # Ports free (or held by our own containers)
  if ! is_placeholder "${PI_TAILSCALE_IP:-}" && command -v ss >/dev/null 2>&1; then
    local port holders
    for port in "${N8N_PORT:-5678}" "${LITELLM_PORT:-4000}" "${DASHBOARD_PORT:-8080}"; do
      holders="$(ss -Hltnp "( sport = :$port )" 2>/dev/null || true)"
      if [[ -z "$holders" || "$holders" == *docker-proxy* ]]; then add "port-$port" OK "free or ours"
      else add "port-$port" FAIL "port $port in use by another process: $(echo "$holders" | head -n1 | awk '{print $NF}')"; fi
    done
  fi

  # dorkmini reachable from this host (by IP: containers use the same IP)
  if ! is_placeholder "${MAC_TAILSCALE_IP:-}" && command -v curl >/dev/null 2>&1; then
    if curl -fsS -m 5 "http://$MAC_TAILSCALE_IP:11434/api/version" >/dev/null 2>&1; then
      add dorkmini-ollama OK "Ollama answers at $MAC_TAILSCALE_IP:11434"
    else
      add dorkmini-ollama WARN "no Ollama at $MAC_TAILSCALE_IP:11434 (Mac asleep, or run mac/install-ollama-launchd.sh); cloud fallback still works"
    fi
  fi
}

# ----------------------------------------------------------------- mac checks
mac_checks() {
  local ip="${MAC_TAILSCALE_IP:-}" ts listen
  ts="$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"
  if [[ -x "$ts" ]]; then
    local mine; mine="$("$ts" ip -4 2>/dev/null | head -n1 || true)"
    if is_placeholder "$ip"; then add mac-ip WARN "MAC_TAILSCALE_IP not set; this Mac is ${mine:-unknown}"
    elif [[ "$ip" == "$mine" ]]; then add mac-ip OK "$ip is this Mac"
    else add mac-ip FAIL "MAC_TAILSCALE_IP=$ip but this Mac is ${mine:-unknown}"; fi
    [[ -n "$mine" ]] && ip="$mine"
  else
    add tailscale FAIL "Tailscale app/CLI not found"
  fi
  listen="$( (lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null || true) | awk 'NR>1 {print $9}' | sort -u | tr '\n' ' ')"
  if [[ -z "$listen" ]]; then add ollama-listen FAIL "nothing listens on :11434 (mac/install-ollama-launchd.sh)"
  elif [[ "$listen" == *"*:11434"* || "$listen" == *"0.0.0.0:11434"* ]]; then add ollama-listen FAIL "Ollama on all interfaces ($listen): LAN can reach it"
  elif [[ -n "$ip" && "$listen" == *"$ip:11434"* ]]; then add ollama-listen OK "only $listen"
  else add ollama-listen FAIL "Ollama listens on $listen, not the Tailscale IP (quit Ollama.app?)"; fi
  launchctl print "gui/$(id -u)/com.homelab.ollama" >/dev/null 2>&1 \
    && add launchagent OK "com.homelab.ollama loaded" || add launchagent WARN "LaunchAgent not loaded (mac/install-ollama-launchd.sh)"
  pgrep -x Ollama >/dev/null && add ollama-app WARN "Ollama.app is running; it competes for port 11434" || add ollama-app OK "Ollama.app not running"
  local sleep; sleep="$( (pmset -g 2>/dev/null || true) | awk '$1=="sleep" {print $2}')"
  [[ "$sleep" == 0 ]] && add sleep OK "system sleep disabled" || add sleep WARN "sleep=${sleep:-?}: sudo pmset -a sleep 0"
  if [[ -n "$ip" ]] && command -v ollama >/dev/null 2>&1; then
    local have m missing_models=""
    have="$( (OLLAMA_HOST="http://$ip:11434" ollama list 2>/dev/null || true) | awk 'NR>1 {print $1}')"
    for m in $("$REPO_ROOT/mac/pull-models.sh" --list); do
      [[ "$m" == *:* ]] || m="$m:latest"
      printf '%s\n' "$have" | grep -qxF "$m" || missing_models="$missing_models $m"
    done
    [[ -z "$missing_models" ]] && add models OK "all expected models present" \
      || add models WARN "missing:$missing_models (mac/pull-models.sh)"
  fi
}

if [[ "$ROLE" == mac ]]; then mac_checks
elif [[ -f "$ENV_FILE" ]]; then pi_checks
fi

fails=0 warns=0
printf '%-16s %-6s %s\n' CHECK STATUS DETAIL
for i in "${!NAMES[@]}"; do
  case "${STATES[$i]}" in FAIL) fails=$((fails + 1)) ;; WARN) warns=$((warns + 1)) ;; esac
  [[ "$QUIET" -eq 1 && "${STATES[$i]}" == OK ]] && continue
  printf '%-16s %-6s %s\n' "${NAMES[$i]}" "${STATES[$i]}" "${DETAILS[$i]}"
done
if [[ "$fails" -gt 0 ]]; then
  echo "PREFLIGHT: $fails FAIL, $warns WARN ($ROLE). Fix the FAIL rows before deploying."
  exit 1
fi
echo "PREFLIGHT: ready ($ROLE, $warns warning(s))"
