#!/usr/bin/env bash
# Generate a curated Hunk sidecar from tab-separated uncertainty notes on stdin.
#
# Usage: fm-review-notes.sh <task-id> --summary <summary> [--output <path>]
# Input columns: path<TAB>new-start<TAB>new-end<TAB>summary<TAB>rationale
# The rationale column is optional. Include only the few places the delivering
# crewmate is least sure of; every emitted annotation is confidence "low".
# This intentionally does not generate one annotation per diff hunk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() { sed -n '2,/^set -euo pipefail$/s/^# \{0,1\}//p' "$0" | sed '$d'; }
fail() { echo "fm-review-notes: $*" >&2; exit 1; }

case "${1:-}" in -h|--help|'') usage; exit 0 ;; esac
ID=$1
shift
case "$ID" in *[!A-Za-z0-9._-]*|'') fail "invalid task id: $ID" ;; esac
SUMMARY=
OUTPUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --summary) [ $# -ge 2 ] || fail "--summary needs a value"; SUMMARY=$2; shift 2 ;;
    --output) [ $# -ge 2 ] || fail "--output needs a value"; OUTPUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$SUMMARY" ] || fail "--summary is required"
command -v jq >/dev/null 2>&1 || fail "jq not found"
OUTPUT=${OUTPUT:-$DATA/$ID/review-notes.json}
mkdir -p "$(dirname "$OUTPUT")"
TMP="$OUTPUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT HUP INT TERM

jq -Rn --arg summary "$SUMMARY" '
  [inputs | select(length > 0 and (startswith("#") | not))
    | split("\t")
    | if length < 4 or .[0] == "" or .[3] == "" then error("each note needs path, start, end, and summary") else . end
    | {path: .[0], start: (.[1] | tonumber), end: (.[2] | tonumber), summary: .[3], rationale: (.[4] // "")}
    | if .start < 1 or .end < .start then error("note ranges must be positive and ordered") else . end] as $notes
  | if ($notes | length) == 0 then error("provide at least one curated uncertainty note") else
      {version: 1, summary: $summary,
       files: [$notes | group_by(.path)[] |
         {path: .[0].path,
          annotations: [.[ ] |
            ({newRange: [.start, .end], summary: .summary, confidence: "low"}
             + if .rationale == "" then {} else {rationale: .rationale} end)]}]}
    end
' > "$TMP" || fail "invalid note input"
mv "$TMP" "$OUTPUT"
trap - EXIT HUP INT TERM
echo "$OUTPUT"
