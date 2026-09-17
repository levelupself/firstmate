#!/usr/bin/env bash
# Shared rule table for return-time pruning and live build-output sweeping.
# Root Cargo.toml retains compatibility with incomplete root builds; nested
# target/ directories require Cargo markers or a profile .fingerprint directory.
# Return cleanup also removes ignored .oracle-work scratch except small evidence.
# fm-build-output-roots.mjs executes these rules without following symlinks and
# refuses roots containing tracked or non-ignored files in the owning copy.
# Callers own process/lease serialization; live sweep only consumes cargo roots.
# fm-build-output-files.mjs owns live file exclusions and nested-repo protection.
fm_build_output_rules() {
  printf '%s\n' root-cargo cargo-target oracle-scratch
}

fm_build_output_run() {
  local wt=$1 mode=$2 lib_dir rules=() rule
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  while IFS= read -r rule; do rules+=("$rule"); done < <(fm_build_output_rules)
  node "$lib_dir/fm-build-output-roots.mjs" "$wt" "$mode" "${rules[@]}"
}

# JSON array avoids interpreting whitespace in nested output paths.
fm_build_output_target() {
  fm_build_output_run "$1" targets
}

fm_prune_build_output() {
  fm_build_output_run "$1" "${2:-delete}"
}
