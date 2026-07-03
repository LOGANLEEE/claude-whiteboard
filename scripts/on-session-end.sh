#!/usr/bin/env bash
# SessionEnd hook. Remove this session from the whiteboard and prune any
# stale entries (crashed sessions that never reached SessionEnd).
#
# Input: JSON on stdin (session_id, reason, ...). No meaningful output.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

input="$(cat)"
wb_have_jq || exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
cutoff=$(( $(wb_now) - WB_TTL ))

# Delete self AND drop anything older than the TTL.
wb_update 'del(.sessions[$sid])
  | .sessions |= with_entries(select(.value.updated >= ($cutoff|tonumber)))' \
  --arg sid "$sid" --arg cutoff "$cutoff"

exit 0
