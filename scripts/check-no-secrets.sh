#!/usr/bin/env bash
# scripts/check-no-secrets.sh - fail if git-tracked files contain things that
# must never be committed: a tracked .env, Tailscale/LAN IP addresses, or
# common token formats (Telegram, OpenAI-style sk-, Groq, Google, Tailscale
# auth keys, private keys). Read-only; run from anywhere inside the repo.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0")

Scans files tracked by git (plus staged ones) for secrets and real IPs.
  -h, --help  Show this help
EOF
}
case "${1:-}" in -h|--help) usage; exit 0 ;; "") ;; *) usage >&2; exit 2 ;; esac

cd "$(git rev-parse --show-toplevel)"
SELF="scripts/check-no-secrets.sh"
failed=0

if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  echo "FAIL .env is tracked by git; run: git rm --cached .env"
  failed=1
fi

# label|extended regex
PATTERNS=(
  'Tailscale IP|\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b'
  'LAN IP|\b(192\.168|10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b'
  'Telegram bot token|\b[0-9]{8,10}:[A-Za-z0-9_-]{35,}'
  'sk- API key|\bsk-[A-Za-z0-9_-]{24,}'
  'Groq key|\bgsk_[A-Za-z0-9]{20,}'
  'Google API key|\bAIza[0-9A-Za-z_-]{35}\b'
  'Tailscale auth key|\btskey-[A-Za-z0-9-]{10,}'
  'Private key|-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

FILES=()
while IFS= read -r f; do
  [[ "$f" == "$SELF" || ! -f "$f" ]] || FILES+=("$f")
done < <( { git ls-files; git diff --cached --name-only; } | sort -u)

for entry in "${PATTERNS[@]}"; do
  label="${entry%%|*}"
  regex="${entry#*|}"
  if hits="$(grep -nEI -- "$regex" "${FILES[@]}" 2>/dev/null)"; then
    echo "FAIL possible $label:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "Secret check failed. Move values to .env (git-ignored) and use placeholders."
  exit 1
fi
echo "OK   no secrets or real IPs found in ${#FILES[@]} tracked files"
