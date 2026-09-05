#!/usr/bin/env bash
# Configure repository-local shared conflict-resolution reuse.
# Usage: fm-project-git-setup.sh <project-clone-root>
# Called during project registration and fleet refresh (including local-only
# and no-origin projects). --local writes the common repository config, inherited
# by linked worktrees; it never writes global config or changes worktree files.
# Only rerere.enabled=true and rerere.autoUpdate=false are managed. Matching
# values are left untouched, making repeated setup a no-op. Git config failures
# stop setup; no config lock is removed or bypassed.
# autoUpdate=false replays content but leaves the index unmerged, requiring the
# worker to inspect and explicitly stage a cached resolution before continuing.
# Reject enclosing-repository discovery before writing anything.
set -eu

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# //; s/^#$//'
  exit 0
fi
[ "$#" -eq 1 ] || { echo "usage: fm-project-git-setup.sh <project-clone-root>" >&2; exit 1; }
project=$1
physical=$(cd "$project" && pwd -P) || exit 1
top=$(git -C "$physical" rev-parse --show-toplevel) || exit 1
[ "$top" = "$physical" ] || {
  echo "error: project Git setup requires a clone root: $project (Git found $top)" >&2
  exit 1
}
for setting in rerere.enabled=true rerere.autoUpdate=false; do
  key=${setting%%=*}
  value=${setting#*=}
  current=$(git -C "$physical" config --local --bool --get-all "$key" 2>/dev/null) || current=
  if [ "$current" != "$value" ]; then
    git -C "$physical" config --local --replace-all "$key" "$value"
  fi
done
