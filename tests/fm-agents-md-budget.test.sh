#!/usr/bin/env bash
# Behavioral coverage for the visible AGENTS.md budget and its shared estimator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agents-md-budget)
BUDGET="$ROOT/bin/fm-agents-md-budget.sh"

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config"
  printf '%s\n' "$home"
}

test_report_classifies_within_and_over_budget() {
  local home out
  home=$(new_home accounting)
  printf 'abcde\n' > "$home/AGENTS.md"
  printf '2\n' > "$home/config/agents-md-budget"

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate' \
    "report did not name the shared estimator"
  assert_contains "$out" 'effective_budget_tokens=2' \
    "report did not expose the configured budget"
  assert_contains "$out" 'file=AGENTS.md bytes=6 estimated_tokens=2 status=present' \
    "report did not measure AGENTS.md with the shared estimator"
  assert_contains "$out" 'total_estimated_tokens=2' \
    "report did not expose the estimated token total"
  assert_contains "$out" 'budget_status=within-budget' \
    "report did not classify an equal total as within budget"

  printf '1\n' > "$home/config/agents-md-budget"
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$BUDGET" report)
  assert_contains "$out" 'budget_status=over-budget' \
    "report did not classify a larger total as over budget"
  pass "AGENTS.md accounting uses the shared estimator and classifies both budget states"
}

expect_rejected_report() {
  local home=$1 expected=$2 out rc
  set +e
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$BUDGET" report 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "invalid AGENTS.md budget should fail the report"
  assert_contains "$out" "$expected" \
    "invalid AGENTS.md budget did not produce a concrete error"
}

test_missing_and_malformed_configuration_fail_concretely() {
  local home
  home=$(new_home invalid)
  printf '%s\n' instructions > "$home/AGENTS.md"

  expect_rejected_report "$home" \
    'invalid config/agents-md-budget - file is absent'
  printf 'not-a-budget\n' > "$home/config/agents-md-budget"
  expect_rejected_report "$home" \
    'invalid config/agents-md-budget - value must be one positive decimal integer'
  pass "missing and malformed AGENTS.md budgets fail with actionable errors"
}

test_report_classifies_within_and_over_budget
test_missing_and_malformed_configuration_fail_concretely

echo '# all fm-agents-md-budget tests passed'
