#!/usr/bin/env bash
# mac/install-ollama-launchd.sh - install/refresh the Ollama LaunchAgent on
# dorkmini so `ollama serve` listens on the Tailscale IP only (OLLAMA_HOST).
#
# Renders mac/com.homelab.ollama.plist into ~/Library/LaunchAgents and
# (re)loads it. Idempotent: if the rendered plist is unchanged and the agent is
# loaded, nothing happens. Run on the Mac Mini as your normal user (not sudo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"

LABEL="com.homelab.ollama"
TEMPLATE="$SCRIPT_DIR/$LABEL.plist"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/ollama"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--ip TAILSCALE_IP] [--bin PATH] [--dry-run] [--uninstall]

Installs a LaunchAgent that runs 'ollama serve' with OLLAMA_HOST=<ip>:11434.

  --ip IP       Bind IP. Default: MAC_TAILSCALE_IP from .env, else 'tailscale ip -4'.
  --bin PATH    Ollama binary. Default: first 'ollama' on PATH.
  --dry-run     Print the rendered plist, change nothing.
  --uninstall   Unload and remove the LaunchAgent.
  -h, --help    Show this help.
EOF
}

IP="" BIN="" DRY_RUN=0 UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) IP="${2:?--ip needs a value}"; shift 2 ;;
    --bin) BIN="${2:?--bin needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "this script is for macOS (dorkmini) only"
DOMAIN="gui/$(id -u)"

if [[ "$UNINSTALL" -eq 1 ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$TARGET"
  log "removed $LABEL"
  exit 0
fi

load_env optional
if [[ -z "$IP" && -n "${MAC_TAILSCALE_IP:-}" && "${MAC_TAILSCALE_IP}" != "127.0.0.1" ]]; then
  IP="$MAC_TAILSCALE_IP"
fi
if [[ -z "$IP" ]]; then
  TS_BIN="$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"
  [[ -x "$TS_BIN" ]] || die "tailscale CLI not found; pass --ip"
  IP="$("$TS_BIN" ip -4 | head -n1)"
fi
[[ "$IP" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || warn "$IP does not look like a Tailscale (100.x) address"
[[ "$IP" != "0.0.0.0" ]] || die "refusing to bind Ollama to 0.0.0.0"

[[ -n "$BIN" ]] || BIN="$(command -v ollama || true)"
[[ -x "$BIN" ]] || die "ollama binary not found; install it (brew install ollama) or pass --bin"

RENDERED="$(sed -e "s|__OLLAMA_BIN__|$BIN|g" \
                -e "s|__OLLAMA_BIND_IP__|$IP|g" \
                -e "s|__LOG_DIR__|$LOG_DIR|g" "$TEMPLATE")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$RENDERED"
  exit 0
fi

mkdir -p "$LOG_DIR" "$(dirname "$TARGET")"
if [[ -f "$TARGET" ]] && [[ "$(cat "$TARGET")" == "$RENDERED" ]] \
   && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  log "$LABEL already installed and loaded with OLLAMA_HOST=$IP:11434; nothing to do"
  exit 0
fi

printf '%s\n' "$RENDERED" > "$TARGET"
plutil -lint "$TARGET" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$TARGET"
launchctl enable "$DOMAIN/$LABEL"
log "loaded $LABEL; Ollama should answer on http://$IP:11434 (logs: $LOG_DIR)"
log "reminder: quit the Ollama menu-bar app and disable its login item, or it will grab the port"
