#!/usr/bin/env bash
# Semantic contract checks for the CI workflow's job-level execution bounds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

workflow_job_timeout() {
  local workflow=$1 job=$2
  awk -v wanted="$job" '
    /^[^ ]/ { top = $0 }
    top == "jobs:" && /^  [A-Za-z0-9_-]+:$/ {
      current = $0
      sub(/^  /, "", current)
      sub(/:$/, "", current)
    }
    top == "jobs:" && current == wanted && /^    timeout-minutes: [0-9]+$/ {
      value = $0
      sub(/^    timeout-minutes: /, "", value)
      print value
      found++
    }
    END {
      if (found != 1) exit 1
    }
  ' "$workflow"
}

timeout=$(workflow_job_timeout "$ROOT/.github/workflows/ci.yml" macos-stock-bash) \
  || fail "CI workflow must define exactly one numeric timeout for macos-stock-bash"

[ "$timeout" -eq 20 ] \
  || fail "macos-stock-bash job timeout must be 20 minutes, got $timeout"

pass "CI workflow gives the measured stock-Bash suite a 20-minute bounded job ceiling"
