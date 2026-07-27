#!/usr/bin/env bash
# On-demand dump of the whiteboard registry (used by /claude-whiteboard:status).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

if ! wb_have_jq; then
  echo "claude-whiteboard: 'jq' not installed."
  exit 0
fi

echo "claude-whiteboard registry: $WB_REGISTRY"
echo

rows="$(wb_read_fresh | jq -r --arg now "$(wb_now)" '
  .sessions | to_entries
  | sort_by(.value.updated) | reverse
  | map(
      (.key[0:8])
      + "\t" + (.value.ticket // "(none)")
      + "\t" + (if .value.ticket then (.value.ticket_src // "prompt") else "-" end)
      + "\t" + ((.value.label // "") | if . == "" then "-" else . end)
      + "\t" + ((.value.branch // "") | if . == "" then "-" else . end)
      + "\t" + (((($now|tonumber) - .value.updated) / 60) | floor | tostring) + "m ago"
    )
  | .[]' 2>/dev/null)"

if [ -z "$rows" ]; then
  echo "No active sessions."
  exit 0
fi

printf 'SESSION\tTICKET\tSRC\tLABEL\tBRANCH\tLAST SEEN\n'
printf '%s\n' "$rows"
