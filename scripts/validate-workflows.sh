#!/usr/bin/env bash
# scripts/validate-workflows.sh - static checks for n8n workflow exports.
#
# For each file: valid JSON; has name/nodes/connections; every node has
# id/name/type/typeVersion/position/parameters; node types are on an allowlist
# of real n8n core node type strings; node names are unique; every connection
# points at an existing node; no credential IDs other than placeholders.
# Read-only, needs jq.
set -euo pipefail

# Real n8n core node types used by this repo. Extend when adding nodes.
ALLOWED_TYPES='[
  "n8n-nodes-base.scheduleTrigger",
  "n8n-nodes-base.webhook",
  "n8n-nodes-base.respondToWebhook",
  "n8n-nodes-base.httpRequest",
  "n8n-nodes-base.set",
  "n8n-nodes-base.if",
  "n8n-nodes-base.code",
  "n8n-nodes-base.telegram",
  "n8n-nodes-base.readWriteFile",
  "n8n-nodes-base.extractFromFile",
  "n8n-nodes-base.stickyNote"
]'

usage() {
  cat <<EOF
Usage: $(basename "$0") FILE.json [FILE.json ...]

Validates n8n workflow JSON exports (see header for the checks).
  -h, --help  Show this help
EOF
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

failed=0
for f in "$@"; do
  if ! jq empty "$f" 2>/dev/null; then
    echo "FAIL $f: invalid JSON"
    failed=$((failed + 1))
    continue
  fi
  problems="$(jq -r --argjson allowed "$ALLOWED_TYPES" '
    def err(m): "  - " + m;
    [ (if (.name | type) != "string" then err("missing workflow name") else empty end),
      (if (.nodes | type) != "array" or (.nodes | length) == 0 then err("nodes must be a non-empty array") else empty end),
      (if (.connections | type) != "object" then err("connections must be an object") else empty end),
      ( (.nodes // [])[] as $n
        | ( (["id","name","type","typeVersion","position","parameters"][]
             | select($n[.] == null) | err("node \($n.name // "?") missing \(.)")),
            (if ($allowed | index($n.type)) == null
               then err("node \($n.name) has unknown type \($n.type)") else empty end),
            ( ($n.credentials // {}) | to_entries[]
              | select(.value.id != "REPLACE_ON_IMPORT")
              | err("node \($n.name) has a non-placeholder credential id for \(.key)")) ) ),
      ( (.nodes // []) | map(.name) | group_by(.)[] | select(length > 1)
        | err("duplicate node name \(.[0])") ),
      ( ((.nodes // []) | map(.name)) as $names
        | (.connections // {}) | to_entries[] | .key as $src
        | ( (if ($names | index($src)) == null then err("connection from unknown node \($src)") else empty end),
            (.value.main // [] | .[] | .[]? | .node as $dst
              | select(($names | index($dst)) == null) | err("connection to unknown node \($dst)")) ) )
    ] | .[]' "$f")"
  if [[ -n "$problems" ]]; then
    echo "FAIL $f"
    printf '%s\n' "$problems"
    failed=$((failed + 1))
  else
    echo "OK   $f ($(jq '.nodes | length' "$f") nodes)"
  fi
done

[[ "$failed" -eq 0 ]] || { echo "$failed workflow file(s) failed validation"; exit 1; }
