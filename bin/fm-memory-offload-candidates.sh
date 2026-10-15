#!/usr/bin/env bash
# Read-only, deterministic startup-memory offload proposals.
# Usage: fm-memory-offload-candidates.sh [--json]
# FM_HOME (otherwise FM_ROOT_OVERRIDE or code root) selects the home; the usual
# FM_DATA_OVERRIDE selects data. The .mjs companion owns entry boundaries,
# ranking, description-keyword hints and table/JSON fields. No eligibility or
# migration is decided here. Missing memory/registry/skills are empty inputs;
# unsafe present files and Git inspection failures reject the sweep.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-memory-offload-candidates.mjs" "$@"
