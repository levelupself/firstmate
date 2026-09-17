#!/usr/bin/env bash
# Print a live task's context size and compaction count from its own session record.
# Usage: fm-context-watch.sh <task-id> [--json]
# Prints `context=<tokens> peak=<tokens> compactions=<n> harness=<h> source=<record>`
# (or the JSON object with --json); a task with no bound record exits 1 with a
# named refusal. Never opens the pane or reads rendered text. See
# fm-context-watch.mjs for the record fields per harness, the watcher tick, and
# the state/<id>.context-watch cache.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,8s/^# //p' "$0"; exit 0 ;;
  ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) echo 'fm-context-watch: invalid task id' >&2; exit 2 ;;
esac
command -v node >/dev/null 2>&1 || { echo 'fm-context-watch: node not found' >&2; exit 2; }
if [ "${2:-}" = --json ]; then
  exec node "$SCRIPT_DIR/fm-context-watch.mjs" read "$1"
fi
[ $# -eq 1 ] || { sed -n '2,8s/^# //p' "$0" >&2; exit 2; }
exec node "$SCRIPT_DIR/fm-context-watch.mjs" read "$1" --line
