#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin, and
# observe pending changes from an optional upstream template remote.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or
# a standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. The optional remote named `upstream` is fetched only for observation:
# the script reports whether its template branch advanced since the last fetch
# and whether commits remain outside the fork, but never merges, rebases, resets,
# or advances a home to that remote. A tracked-files fast-forward never touches
# the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - upstream-template: current|pending|unavailable
#   - upstream-template-latest: <commit> <subject>   (when pending)
#   - upstream-catchup-last: <date>|unknown          (when pending)
#   - upstream-catchup: merge-required              (when pending)
#   - review-upstream: yes|no
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

upstream_remote_default_branch() {
  local dir=$1
  git -C "$dir" ls-remote --symref upstream HEAD 2>/dev/null \
    | awk '$1 == "ref:" && $3 == "HEAD" && sub(/^refs\/heads\//, "", $2) { print $2; exit }'
}

plural() {
  local count=$1 singular=$2
  if [ "$count" -eq 1 ]; then
    printf '%s' "$singular"
  else
    printf '%ss' "$singular"
  fi
}

latest_upstream_catchup_date() {
  local dir=$1 fork_ref=$2 upstream_ref=$3 merges merge parents parent
  merges=$(git -C "$dir" rev-list --first-parent --merges "$fork_ref" 2>/dev/null || true)
  for merge in $merges; do
    parents=$(git -C "$dir" rev-list --parents -n1 "$merge" 2>/dev/null || true)
    parents=${parents#* }
    parents=${parents#* }
    for parent in $parents; do
      if git -C "$dir" merge-base --is-ancestor "$parent" "$upstream_ref" 2>/dev/null; then
        git -C "$dir" show -s --format=%cs "$merge"
        return 0
      fi
    done
  done
  return 1
}

observe_upstream_template() {
  local old_rev default new_rev changed fork_default fork_ref upstream_ref
  local pending merge_base changed_files latest catchup_date

  if ! git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1; then
    echo "upstream-template: unavailable: no upstream remote; only origin updates are observable"
    echo "review-upstream: no"
    return 0
  fi

  default=$(upstream_remote_default_branch "$FM_ROOT" || true)
  if [ -z "$default" ]; then
    echo "upstream-template: unavailable: cannot determine upstream default branch"
    echo "review-upstream: no"
    return 0
  fi
  old_rev=$(git -C "$FM_ROOT" rev-parse --verify --quiet \
    "refs/remotes/upstream/$default^{commit}" 2>/dev/null || true)

  if ! git -C "$FM_ROOT" fetch upstream --prune --quiet --refmap= \
    '+refs/heads/*:refs/remotes/upstream/*' 2>/dev/null; then
    echo "upstream-template: unavailable: fetch failed"
    echo "review-upstream: no"
    return 0
  fi

  upstream_ref="refs/remotes/upstream/$default"
  new_rev=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$upstream_ref^{commit}" 2>/dev/null || true)
  if [ -z "$new_rev" ]; then
    echo "upstream-template: unavailable: upstream/$default does not exist"
    echo "review-upstream: no"
    return 0
  fi

  changed="unknown"
  if [ -n "$old_rev" ]; then
    changed="no"
    [ "$old_rev" = "$new_rev" ] || changed="yes"
  fi

  fork_default=$(default_branch "$FM_ROOT" || true)
  fork_ref="refs/heads/$fork_default"
  if [ -z "$fork_default" ] \
    || ! git -C "$FM_ROOT" rev-parse --verify --quiet "$fork_ref^{commit}" >/dev/null; then
    echo "upstream-template: unavailable: cannot determine fork default branch"
    echo "review-upstream: no"
    return 0
  fi

  pending=$(git -C "$FM_ROOT" rev-list --count "$fork_ref..$upstream_ref" 2>/dev/null || true)
  if [ -z "$pending" ]; then
    echo "upstream-template: unavailable: fork and upstream histories cannot be compared"
    echo "review-upstream: no"
    return 0
  fi
  if [ "$pending" -eq 0 ]; then
    echo "upstream-template: current with upstream/$default; changed-since-last-fetch: $changed"
    echo "review-upstream: no"
    return 0
  fi

  merge_base=$(git -C "$FM_ROOT" merge-base "$fork_ref" "$upstream_ref" 2>/dev/null || true)
  if [ -z "$merge_base" ]; then
    echo "upstream-template: unavailable: fork and upstream have no common history"
    echo "review-upstream: no"
    return 0
  fi
  changed_files=$(git -C "$FM_ROOT" diff --name-only "$merge_base" "$upstream_ref" -- 2>/dev/null \
    | awk 'END { print NR + 0 }')
  latest=$(git -C "$FM_ROOT" log -1 --format='%h %s' "$fork_ref..$upstream_ref" 2>/dev/null || true)

  printf 'upstream-template: pending %s %s from upstream/%s (%s changed %s); changed-since-last-fetch: %s\n' \
    "$pending" "$(plural "$pending" commit)" "$default" \
    "$changed_files" "$(plural "$changed_files" file)" "$changed"
  [ -z "$latest" ] || echo "upstream-template-latest: $latest"
  catchup_date=$(latest_upstream_catchup_date "$FM_ROOT" "$fork_ref" "$upstream_ref" || true)
  if [ -n "$catchup_date" ]; then
    echo "upstream-catchup-last: $catchup_date"
  else
    echo "upstream-catchup-last: unknown; no upstream merge commit was found"
  fi
  echo "upstream-catchup: merge-required"
  echo "review-upstream: yes"
}

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      echo "secondmate registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    process_secondmate "$id" "$home" "" origin no
  done < "$SECONDMATES_MD"
fi

# --- upstream template observation ----------------------------------------
# This is intentionally separate from the origin fast-forward path. A fork
# catch-up requires a reviewed merge commit; observing upstream never moves a
# checkout or creates that merge.

observe_upstream_template

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
