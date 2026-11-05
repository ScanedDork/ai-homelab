#!/usr/bin/env bash
# scripts/install-pi.sh - bootstrap n8npi for this repo. Safe to re-run.
#
#  1. checks prerequisites (Linux, docker + compose v2, tailscale)
#  2. creates .env from .env.example (chmod 600) and fills ONLY placeholder
#     values: Tailscale IPs from `tailscale ip -4`, random tokens/keys
#  3. N8N_ENCRYPTION_KEY: adopts the key from an existing n8n volume (so saved
#     credentials keep working) or generates a new one for a fresh install
#  4. creates BACKUP_DIR/status owned by you
#  5. installs the Docker-after-Tailscale drop-in and the nightly backup timer,
#     with this checkout's real path (needs sudo; skip with --no-systemd)
# Values you already set in .env are never overwritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--no-systemd] [--mac-host NAME] [--env-file FILE]

  --dry-run        Show what would change, change nothing
  --no-systemd     Skip the systemd drop-in and backup timer
  --mac-host NAME  Tailnet name of the Mac (default: dorkmini)
  --env-file FILE  Env file to create/update (default: repo .env)
  -h, --help       Show this help

Next steps afterwards: make preflight && make up-pi && make provision
EOF
}

DRY=0 SYSTEMD=1 MAC_HOST="dorkmini"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --no-systemd) SYSTEMD=0; shift ;;
    --mac-host) MAC_HOST="${2:?--mac-host needs a name}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

step()    { printf '\n== %s\n' "$*" >&2; }
changed() { printf '   [changed] %s\n' "$*" >&2; }
ok()      { printf '   [ok]      %s\n' "$*" >&2; }
skip()    { printf '   [skip]    %s\n' "$*" >&2; }

run() { # run a command, or print it in --dry-run
  if [[ "$DRY" -eq 1 ]]; then printf '   [dry-run] %s\n' "$*" >&2; else "$@"; fi
}

SUDO=()
[[ "$(id -u)" -eq 0 ]] || SUDO=(sudo)

random_hex() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  else python3 -c 'import secrets; print(secrets.token_hex(32))'; fi
}

# env_get KEY -> current value in $ENV_FILE ("" if missing)
env_get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }

# env_set KEY VALUE -> replace the KEY= line (values here are hex/IPs only)
env_set() {
  local key="$1" value="$2" tmp
  if [[ "$DRY" -eq 1 ]]; then printf '   [dry-run] set %s\n' "$key" >&2; return; fi
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  if grep -q "^$key=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

is_placeholder() {
  local v="$1"
  [[ -z "$v" || "$v" == replace-with* || "$v" == sk-replace-me || "$v" == 127.0.0.1 ]]
}

# ---------------------------------------------------------------------------
step "Prerequisites"
[[ "$(uname -s)" == "Linux" ]] || die "run this on the Raspberry Pi (Linux)"
require_cmd docker awk sed
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin missing (apt install docker-compose-plugin)"
docker info >/dev/null 2>&1 || die "cannot talk to Docker; add yourself to the docker group: sudo usermod -aG docker $USER (then log in again)"
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) + compose $(docker compose version --short 2>/dev/null)"
case "$(uname -m)" in
  aarch64|arm64) ok "arch $(uname -m)" ;;
  *) warn "arch $(uname -m): set N8N_PLATFORM in .env to match (e.g. linux/amd64)" ;;
esac
TS=""
if command -v tailscale >/dev/null 2>&1; then
  TS=tailscale
  ok "tailscale $(tailscale version 2>/dev/null | head -n1)"
else
  warn "tailscale CLI not found; IPs must be filled in .env by hand"
fi

# ---------------------------------------------------------------------------
step "Environment file ($ENV_FILE)"
if [[ ! -f "$ENV_FILE" ]]; then
  run cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  run chmod 600 "$ENV_FILE"
  changed "created from .env.example"
  [[ "$DRY" -eq 0 ]] || ENV_FILE="$REPO_ROOT/.env.example"   # read placeholders in dry-run
else
  ok "exists"
  if [[ "$(stat -c %a "$ENV_FILE")" != 600 ]]; then run chmod 600 "$ENV_FILE"; changed "chmod 600"; fi
fi

fill_ip() { # KEY PEER(optional)
  local key="$1" peer="${2:-}" ip=""
  if ! is_placeholder "$(env_get "$key")"; then ok "$key already set"; return; fi
  [[ -n "$TS" ]] || { warn "$key: set it by hand (tailscale ip -4${peer:+ $peer})"; return; }
  # shellcheck disable=SC2086
  ip="$($TS ip -4 $peer 2>/dev/null | head -n1 || true)"
  if [[ "$ip" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    env_set "$key" "$ip"; changed "$key=$ip"
  else
    warn "$key: 'tailscale ip -4${peer:+ $peer}' gave no address${peer:+ (is $peer online and named so in the admin console?)}"
  fi
}
fill_ip PI_TAILSCALE_IP
fill_ip MAC_TAILSCALE_IP "$MAC_HOST"

fill_secret() { # KEY [prefix]
  local key="$1" prefix="${2:-}"
  if is_placeholder "$(env_get "$key")"; then
    env_set "$key" "$prefix$(random_hex)"; changed "$key generated"
  else
    ok "$key already set"
  fi
}

# Encryption key: never invent one for an existing n8n volume.
VOLUME="$(env_get N8N_VOLUME_NAME)"; VOLUME="${VOLUME:-n8n_data}"
HELPER="$(env_get BACKUP_HELPER_IMAGE)"; HELPER="${HELPER:-docker.io/library/alpine:3.20}"
current_key="$(env_get N8N_ENCRYPTION_KEY)"
volume_key=""
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  volume_key="$(docker run --rm -v "$VOLUME:/data:ro" "$HELPER" cat /data/config 2>/dev/null \
    | sed -n 's/.*"encryptionKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
fi
if is_placeholder "$current_key"; then
  if [[ -n "$volume_key" ]]; then
    env_set N8N_ENCRYPTION_KEY "$volume_key"; changed "N8N_ENCRYPTION_KEY adopted from existing volume '$VOLUME'"
  else
    env_set N8N_ENCRYPTION_KEY "$(random_hex)"; changed "N8N_ENCRYPTION_KEY generated (fresh install)"
  fi
elif [[ -n "$volume_key" && "$volume_key" != "$current_key" ]]; then
  die "N8N_ENCRYPTION_KEY in $ENV_FILE differs from the key in volume '$VOLUME'; n8n could not decrypt its credentials. Fix .env before continuing."
else
  ok "N8N_ENCRYPTION_KEY already set"
fi

fill_secret DASHBOARD_TOKEN
fill_secret N8N_WEBHOOK_TOKEN
fill_secret LITELLM_MASTER_KEY "sk-"
fill_secret OPENCLAW_GATEWAY_TOKEN

for k in TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
  [[ -n "$(env_get "$k")" ]] || warn "$k is empty: Telegram alerts stay off until you set it (docs/runbook.md)"
done
if [[ -z "$(env_get GEMINI_API_KEY)$(env_get GROQ_API_KEY)$(env_get CEREBRAS_API_KEY)$(env_get OPENROUTER_API_KEY)" ]]; then
  warn "no cloud API keys set: LiteLLM has no fallback when dorkmini is down"
fi

# ---------------------------------------------------------------------------
step "Backup directory"
BACKUP_DIR="$(env_get BACKUP_DIR)"; BACKUP_DIR="${BACKUP_DIR:-/srv/n8n-backups}"
if [[ -d "$BACKUP_DIR/status" && -w "$BACKUP_DIR" && -w "$BACKUP_DIR/status" ]]; then
  ok "$BACKUP_DIR is writable"
else
  run "${SUDO[@]}" install -d -o "$(id -u)" -g "$(id -g)" "$BACKUP_DIR" "$BACKUP_DIR/status"
  run "${SUDO[@]}" chown "$(id -u):$(id -g)" "$BACKUP_DIR" "$BACKUP_DIR/status"
  changed "created $BACKUP_DIR/status (owner $(id -un))"
fi

# ---------------------------------------------------------------------------
step "systemd (Docker ordering + backup timer)"
if [[ "$SYSTEMD" -eq 0 ]]; then
  skip "--no-systemd"
elif ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
  skip "systemd not running on this host"
else
  install_file() { # src dest [sed-expr]
    local src="$1" dest="$2" expr="${3:-}" tmp
    tmp="$(mktemp)"
    if [[ -n "$expr" ]]; then sed "$expr" "$src" > "$tmp"; else cp "$src" "$tmp"; fi
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
      ok "$dest up to date"; rm -f "$tmp"; return 1
    fi
    run "${SUDO[@]}" install -D -m 644 "$tmp" "$dest"; rm -f "$tmp"
    changed "$dest"
  }
  reload=0
  install_file "$REPO_ROOT/scripts/systemd/docker-wait-for-tailscale.conf" \
    /etc/systemd/system/docker.service.d/docker-wait-for-tailscale.conf && reload=1
  for unit in n8n-backup@.service n8n-backup@.timer; do
    install_file "$REPO_ROOT/scripts/systemd/$unit" "/etc/systemd/system/$unit" \
      "s#/opt/ai-homelab#$REPO_ROOT#g" && reload=1
  done
  if [[ "$reload" -eq 1 ]]; then run "${SUDO[@]}" systemctl daemon-reload; changed "daemon-reload"; fi
  TIMER="n8n-backup@$(id -un).timer"
  if systemctl is-enabled --quiet "$TIMER" 2>/dev/null; then ok "$TIMER enabled"
  else run "${SUDO[@]}" systemctl enable --now "$TIMER"; changed "enabled $TIMER"; fi
fi

step "Done"
log "next: make preflight && make up-pi && make provision"
[[ "$DRY" -eq 0 ]] || log "(dry run: nothing was changed)"
