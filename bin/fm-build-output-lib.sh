#!/usr/bin/env bash
# Shared build-output rule table and deletion boundary.
# Rust: a root Cargo.toml enables the root target/ directory; no other rules ship.
# Build output is not unlanded work: only gitignored, reproducible directories
# qualify, never tracked or non-ignored files. Teardown calls this only after its
# landed-work checks and process cleanup; a refused teardown never reaches it.
# fm_prune_build_output <worktree> [dry-run|delete] prints path and allocated KiB.
# Symlink roots, any tracked paths (including index-hidden paths), non-ignored
# files, or unreadable Git inventories disqualify the whole output root.
# Callers own concurrency protection: fm-teardown.sh, fm-pool-prune.sh, and
# fm-pool-build-sweep.sh document their respective process and locking guards.

fm_build_output_rules() {
  printf '%s\n' 'Cargo.toml target'
}

# fm_build_output_target prints the sole eligible output root, or nothing.
# Both live eviction and return-time full pruning use this root boundary.
# fm-build-output-files.mjs owns the subsequent file-granularity exclusions.
fm_build_output_target() {
  local wt=$1 marker output protected ignored top
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
    printf '%s\n' "$wt/$output"
  done < <(fm_build_output_rules)
}

fm_prune_build_output() {
  local wt=$1 mode=${2:-delete} target lib_dir
  target=$(fm_build_output_target "$wt") || return 1
  [ -n "$target" ] || return 0
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  node "$lib_dir/fm-build-output-files.mjs" "$target" "$mode"
}
