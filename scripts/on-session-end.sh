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

# Hand every resource this session holds back to whoever is waiting, BEFORE the
# entry is deleted. SessionEnd output is not injected into any session's context,
# so this cannot notify anyone directly — it opens the priority window and the
# waiter learns at its own next prompt. That still completes the handoff when a
# holder simply exits instead of releasing.
for res in $(jq -r --arg s "$sid" '.sessions[$s].holds // {} | keys[]' \
               "$WB_REGISTRY" 2>/dev/null); do
  wb_open_window "$res" "$WB_RESERVE"
done

# Delete self AND drop anything older than the TTL.
wb_update 'del(.sessions[$sid])
  | .sessions |= with_entries(select(.value.updated >= ($cutoff|tonumber)))' \
  --arg sid "$sid" --arg cutoff "$cutoff"

exit 0
