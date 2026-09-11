#!/usr/bin/env bash
# Shared build-output rule table and deletion boundary.
# Rust: a root Cargo.toml enables the root target/ directory; no other rules ship.
# Build output is not unlanded work: only gitignored, reproducible directories
# qualify, never tracked or non-ignored files. Teardown calls this only after its
# landed-work checks and process cleanup; a refused teardown never reaches it.
# fm_prune_build_output <worktree> [dry-run|delete] prints path and allocated KiB.
# Symlink roots, nested repositories, tracked paths (including index-hidden
# paths), non-ignored files, and unreadable Git inventories are never deleted.
# Callers own exclusive access: returned-copy pruning holds the pool lock;
# the sweep holds the same lock and excludes every task reference.

fm_build_output_rules() {
  printf '%s\n' 'Cargo.toml target'
}

fm_prune_build_output() {
  local wt=$1 mode=${2:-delete} marker output protected ignored nested size top
  [ -d "$wt" ] && [ ! -L "$wt" ] || return 0
  top=$(git -C "$wt" rev-parse --show-toplevel) || return 1
  [ "$(cd "$wt" && pwd -P)" = "$(cd "$top" && pwd -P)" ] || return 1
  while read -r marker output; do
    [ -f "$wt/$marker" ] && [ ! -L "$wt/$marker" ] || continue
    [ -d "$wt/$output" ] && [ ! -L "$wt/$output" ] || continue
    protected=$(git -C "$wt" ls-files --cached --others --exclude-standard -- "$output") || return 1
    [ -z "$protected" ] || continue
    ignored=$(git -C "$wt" ls-files --others --ignored --exclude-standard --directory -- "$output") || return 1
    [ -n "$ignored" ] || continue
    nested=$(find "$wt/$output" -name .git -print -quit) || return 1
    [ -z "$nested" ] || continue
    size=$(du -sk "$wt/$output") || return 1
    size=${size%%[[:space:]]*}
    case "$mode" in
      dry-run) printf 'would prune %s (%s KiB)\n' "$wt/$output" "$size" ;;
      delete)
        git -C "$wt" clean -fdX -- "$output" >/dev/null || return 1
        printf 'pruned %s (%s KiB)\n' "$wt/$output" "$size"
        ;;
      *) return 2 ;;
    esac
  done < <(fm_build_output_rules)
}

fm_prune_returned_build_output() (
  local wt=$1 pool marker output candidate=0
  while read -r marker output; do
    if [ -f "$wt/$marker" ] && [ -d "$wt/$output" ]; then candidate=1; fi
  done < <(fm_build_output_rules)
  [ "$candidate" -eq 1 ] || return 0
  pool=$(dirname "$(dirname "$wt")")
  [ -f "$pool/treehouse-state.lock" ] && [ ! -L "$pool/treehouse-state.lock" ] || {
    echo "error: unrecognized Treehouse pool lock: $pool" >&2
    return 1
  }
  exec 9<"$pool/treehouse-state.lock" || return 1
  flock -x 9 || return 1
  node - "$pool/treehouse-state.json" "$wt" <<'JS' || return 1
const fs = require('fs');
const [file, wt] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(file, 'utf8'));
if (!Array.isArray(state.worktrees)) throw Error('unreadable pool state');
const entries = state.worktrees.filter(e => e.path === wt);
if (entries.length !== 1) throw Error('ambiguous pool entry');
const e = entries[0];
if (e.leased || e.lease_id || e.destroying || e.owner_pid)
  throw Error('returned copy is no longer idle; preserving build output');
JS
  fm_prune_build_output "$wt"
)
