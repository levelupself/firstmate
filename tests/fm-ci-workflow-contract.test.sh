#!/usr/bin/env bash
# Semantic contract checks for the CI workflow's job-level execution bounds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
python3 -c 'import yaml' 2>/dev/null || fail "Python PyYAML is required"

timeout=$(python3 - "$ROOT/.github/workflows/ci.yml" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as workflow_file:
    workflow = yaml.safe_load(workflow_file)

try:
    timeout = workflow["jobs"]["macos-stock-bash"]["timeout-minutes"]
except (KeyError, TypeError):
    raise SystemExit(1)

if isinstance(timeout, bool) or not isinstance(timeout, int):
    raise SystemExit(1)

print(timeout)
PY
) || fail "CI workflow must define a numeric timeout for macos-stock-bash"

[ "$timeout" -eq 20 ] \
  || fail "macos-stock-bash job timeout must be 20 minutes, got $timeout"

pass "CI workflow gives the measured stock-Bash suite a 20-minute bounded job ceiling"
