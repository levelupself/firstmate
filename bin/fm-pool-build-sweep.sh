#!/usr/bin/env bash
# Sweep stale Rust artifacts in registered projects' Treehouse inventories.
# Usage: fm-pool-build-sweep.sh [--dry-run] [--age-hours N] [--max-gb N]
# Defaults: FM_POOL_BUILD_AGE_HOURS=24, FM_POOL_BUILD_MAX_GB=8 (decimal GB).
# Both knobs require positive finite values; zero age is not supported.
# Stale artifacts have superseded Cargo fingerprints, are not referenced by a
# protected current build unit, and have mtime older than the age threshold.
# Above the size cap, evict eligible files oldest first regardless of age.
# Current build units and their transitive fingerprint dependencies always win;
# oversized protected output is reported, never evicted. Unknown artifacts,
# including incremental caches with no fingerprint mapping, remain protected.
# cargo-sweep, when installed, supplies a dry-run --maxsize plan; the engine
# filters it through the same preservation boundary before deleting anything.
# Only ignored target/ output qualifies; source, symlinks, nested repositories,
# tracked and non-ignored output are excluded by fm-build-output-lib.sh.
# Treehouse status --json is the inventory/process authority; cargo/rustc or
# unknown process evidence skips the copy. Existing Cargo profile locks also
# serialize deletion against a build starting after the inventory snapshot.
# One line per copy: path, bytes_before, bytes_after, and reason (including skips).
# --dry-run does not delete or schedule work; reported bytes_after is actual.
# This is best-effort disk pressure control, not a build correctness mechanism.
# --periodic starts one finite worker without waiting; --scheduled is internal.
# state/.pool-build-sweep.lock and .pool-build-sweep.last provide exclusion and
# a durable one-hour cadence per FM_HOME, including failures and restarts.
# state/.pool-build-sweep.log contains bounded worker output; timeout is 300s.
# --return-copy PATH [--dry-run] is teardown's full-prune entry after landed-work
# and process cleanup, retaining its existing contract via the shared rule table.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
case "${1:-}" in
  --help|-h) sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
  --return-copy)
    # shellcheck source=bin/fm-build-output-lib.sh
    . "$SCRIPT_DIR/fm-build-output-lib.sh"
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || exit 2
    mode=delete
    if [ "$#" -eq 3 ]; then [ "$3" = --dry-run ] || exit 2; mode=dry-run; fi
    fm_prune_build_output "$2" "$mode"
    exit
    ;;
  --scheduled)
    state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
    mkdir -p "$state"
    exec 9>"$state/.pool-build-sweep.lock"
    flock -n 9 || exit 0
    timeout 300 node "$SCRIPT_DIR/fm-pool-build-sweep.mjs" --scheduled || {
      rc=$?; echo "pool build sweep failed: exit=$rc" >&2; exit "$rc";
    }
    exit
    ;;
esac
exec node "$SCRIPT_DIR/fm-pool-build-sweep.mjs" "$@"
