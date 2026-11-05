#!/usr/bin/env bash
# scripts/tests/test-install-pi.sh - regression test for scripts/install-pi.sh
# and the .env checks in scripts/preflight.sh. Runs in a throwaway copy of the
# repo with a fake `tailscale` CLI; needs Docker (for the volume-key cases).
# Usage: scripts/tests/test-install-pi.sh   (also run by `make test`)
# check() evals its single-quoted condition later, so these are intentional:
# shellcheck disable=SC2016,SC2034
set -euo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
VOL="hltest_install_$$"
cleanup() {
  docker volume rm -f "$VOL" >/dev/null 2>&1 || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# Throwaway repo copy + fake tailscale
mkdir -p "$WORK/repo" "$WORK/bin" "$WORK/backups"
(cd "$ROOT" && git ls-files -co --exclude-standard | grep -v '^\.env$' | tar -cf - -T -) | tar -xf - -C "$WORK/repo"
cat > "$WORK/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "ip -4") echo 100.101.1.1 ;;  # secret-scan: allow (fake IP)
  "ip -4 dorkmini") echo 100.101.1.2 ;;  # secret-scan: allow (fake IP)
  version) echo 1.0.0-test ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/tailscale"
export PATH="$WORK/bin:$PATH"

ENV="$WORK/repo/.env"
cp "$WORK/repo/.env.example" "$ENV"
chmod 644 "$ENV"
sed -i -e "s|^BACKUP_DIR=.*|BACKUP_DIR=$WORK/backups|" -e "s|^N8N_VOLUME_NAME=.*|N8N_VOLUME_NAME=$VOL|" \
       -e 's|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=-1001234|' "$ENV"
get() { sed -n "s/^$1=//p" "$ENV"; }
INSTALL=("$WORK/repo/scripts/install-pi.sh" --no-systemd --env-file "$ENV")

out="$("${INSTALL[@]}" 2>&1)" || { echo "$out"; fail "first install run exits 0"; }
check "PI_TAILSCALE_IP filled from tailscale"     '[[ "$(get PI_TAILSCALE_IP)" == 100.101.1.1 ]]'  # secret-scan: allow (fake IP)
check "MAC_TAILSCALE_IP filled from tailscale"    '[[ "$(get MAC_TAILSCALE_IP)" == 100.101.1.2 ]]'  # secret-scan: allow (fake IP)
for k in N8N_ENCRYPTION_KEY DASHBOARD_TOKEN N8N_WEBHOOK_TOKEN OPENCLAW_GATEWAY_TOKEN; do
  check "$k is 64 random hex chars" "[[ \"\$(get $k)\" =~ ^[0-9a-f]{64}$ ]]"
done
check "LITELLM_MASTER_KEY is sk-<hex>"            '[[ "$(get LITELLM_MASTER_KEY)" =~ ^sk-[0-9a-f]{64}$ ]]'
check "user value preserved"                      '[[ "$(get TELEGRAM_CHAT_ID)" == -1001234 ]]'
check ".env tightened to 600"                     '[[ "$(stat -c %a "$ENV")" == 600 ]]'
check "backup status dir created"                 '[[ -d "$WORK/backups/status" ]]'

before="$(sha256sum "$ENV")"
out="$("${INSTALL[@]}" 2>&1)" || fail "second install run exits 0"
check "second run changes nothing"                '[[ "$(sha256sum "$ENV")" == "$before" ]] && ! grep -q "\[changed\]" <<<"$out"'

out="$("$WORK/repo/scripts/preflight.sh" --env-file "$ENV" 2>&1 || true)"
check "preflight: env values complete"            'grep -q "^env-values *OK" <<<"$out"'

# Existing n8n volume: key is adopted, mismatch is refused.
docker volume create "$VOL" >/dev/null
docker run --rm -v "$VOL:/data" docker.io/library/alpine:3.20 \
  sh -c 'printf "{\n\t\"encryptionKey\": \"existingkey1234567890\"\n}" > /data/config' >/dev/null
sed -i 's|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=replace-with-openssl-rand-hex-32|' "$ENV"
"${INSTALL[@]}" >/dev/null 2>&1 || fail "install with existing volume exits 0"
check "key adopted from existing volume"          '[[ "$(get N8N_ENCRYPTION_KEY)" == existingkey1234567890 ]]'
sed -i 's|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=someotherkey|' "$ENV"
check "mismatched key refused by install"         '! "${INSTALL[@]}" >/dev/null 2>&1'
out="$("$WORK/repo/scripts/preflight.sh" --env-file "$ENV" 2>&1 || true)"
check "mismatched key is a preflight FAIL"        'grep -q "^n8n-key *FAIL" <<<"$out"'

if [[ "$fails" -gt 0 ]]; then echo "$fails install test(s) failed"; exit 1; fi
echo "install-pi tests: OK"
