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

# An absent registry is a wrong path, not an empty board. Reading it as "no
# sessions" is how /free came to verify itself against a file nothing writes:
# hooks run with CLAUDE_PLUGIN_DATA set and a Bash tool call does not, so the
# two used to resolve different files and this script reported a live board of
# eight sessions as empty. lib.sh now finds the plugin data dir by name, but say
# so loudly if the file still is not there rather than inventing a verdict.
if [ ! -f "$WB_REGISTRY" ]; then
  echo "claude-whiteboard: no registry at $WB_REGISTRY" >&2
  echo "Nothing has written to the board there. If sessions ARE running, this is" >&2
  echo "the wrong path — point CC_WHITEBOARD_REGISTRY at the file the hooks use." >&2
  exit 1
fi

echo "claude-whiteboard registry: $WB_REGISTRY"
echo

peers="$(wb_peer_names)"

rows="$(wb_read_fresh | jq -r --arg now "$(wb_now)" --argjson peers "$peers" '
  .sessions | to_entries
  | sort_by(.value.updated) | reverse
  | map(
      (.key[0:8])
      + "\t" + (.value.ticket // "(none)")
      + "\t" + (if .value.ticket then (.value.ticket_src // "prompt") else "-" end)
      + "\t" + ((.value.label // "") | if . == "" then "-" else . end)
      + "\t" + ((.value.branch // "") | if . == "" then "-" else . end)
      + "\t" + ((($peers[.key] // {}).name // "") | if . == "" then "-" else . end)
      + "\t" + (((($now|tonumber) - .value.updated) / 60) | floor | tostring) + "m ago"
    )
  | .[]' 2>/dev/null)"

if [ -z "$rows" ]; then
  echo "No active sessions."
  exit 0
fi

printf 'SESSION\tTICKET\tSRC\tLABEL\tBRANCH\tPEER\tLAST SEEN\n'
printf '%s\n' "$rows"

echo

# Shared resources. Held and waited-on rows come from the same session-centric
# registry, so a session that ages out of the TTL takes its holds and waits with
# it and cannot leave a ghost row here.
resrows="$(wb_read_fresh | jq -r --argjson peers "$peers" --arg now "$(wb_now)" '
  ($now|tonumber) as $t
  | [ .sessions | to_entries[] as $s
      | ($s.value.holds // {}) | to_entries[]
      | {res: .key, who: $s.key, since: .value} ] as $held
  | [ .sessions | to_entries[] as $s
      | ($s.value.waits // {}) | to_entries[]
      | {res: .key, who: $s.key, since: .value.since} ] as $waiting
  | (($held + $waiting) | map(.res) | unique)
  | map(. as $r
      | ($held    | map(select(.res == $r)) | first) as $h
      | ($waiting | map(select(.res == $r))
         | map((($peers[.who] // {}).name // .who[0:8])
               + "(" + ((($t - .since) / 60) | floor | tostring) + "m)")
         | join(", ")) as $w
      | $r
        + "\t" + (if $h then ($h.who[0:8]) else "-" end)
        + "\t" + (if $h then (($peers[$h.who] // {}).name // "-") else "-" end)
        + "\t" + (if $h then (((($t - $h.since) / 60) | floor | tostring) + "m") else "-" end)
        + "\t" + (if $w == "" then "-" else $w end))
  | .[]' 2>/dev/null)"

if [ -z "$resrows" ]; then
  echo "No shared resources claimed."
else
  printf 'RESOURCE\tHOLDER\tPEER\tSINCE\tWAITING\n'
  printf '%s\n' "$resrows"
fi
