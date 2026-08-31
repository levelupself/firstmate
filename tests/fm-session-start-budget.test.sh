#!/usr/bin/env bash
# Behavioral coverage for the visible session-start briefing budget and reporter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-start-budget)
BUDGET="$ROOT/bin/fm-session-start-budget.sh"

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config"
  printf '%s\n' "$home"
}

test_report_classifies_a_captured_briefing() {
  local home digest out
  home=$(new_home accounting)
  digest="$home/digest.txt"
  printf '123456\n' > "$digest"
  printf '3\n' > "$home/config/session-start-budget"

  out=$(FM_HOME="$home" "$BUDGET" report "$digest")
  assert_contains "$out" 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate' \
    "report did not name the shared estimator"
  assert_contains "$out" 'effective_budget_tokens=3' \
    "report did not expose the configured budget"
  assert_contains "$out" "file=$digest bytes=7 estimated_tokens=3 status=present" \
    "report did not measure the captured digest with the shared estimator"
  assert_contains "$out" 'total_estimated_tokens=3' \
    "report did not expose the briefing total"
  assert_contains "$out" 'budget_status=within-budget' \
    "report did not classify an equal total as within budget"

  printf '2\n' > "$home/config/session-start-budget"
  out=$(FM_HOME="$home" "$BUDGET" report "$digest")
  assert_contains "$out" 'budget_status=over-budget' \
    "report did not classify a larger briefing as over budget"
  assert_contains "$out" 'budget_overage_tokens=1' \
    "over-budget report did not quantify the excess"
  assert_contains "$out" 'budget_remedy=trim fleet detail or raise config/session-start-budget above 3 estimated tokens' \
    "over-budget report did not provide a concrete remedy"
  pass "session-start accounting uses the shared estimator and classifies captured output"
}

test_missing_and_unsafe_inputs_fail_concretely() {
  local home outside out rc
  home=$(new_home invalid)
  outside="$home/outside"
  printf '10\n' > "$home/config/session-start-budget"
  printf 'digest\n' > "$outside"

  set +e
  out=$(FM_HOME="$home" "$BUDGET" report "$home/missing" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "an absent briefing capture should fail the report"
  assert_contains "$out" 'briefing file is absent' \
    "absent briefing input did not produce a concrete error"

  ln -s "$outside" "$home/digest-link"
  set +e
  out=$(FM_HOME="$home" "$BUDGET" report "$home/digest-link" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a symlinked briefing capture should fail the report"
  assert_contains "$out" 'briefing file is not an ordinary regular file' \
    "unsafe briefing input did not produce a concrete error"
  pass "session-start reporter rejects absent and unsafe briefing captures"
}

test_report_classifies_a_captured_briefing
test_missing_and_unsafe_inputs_fail_concretely

echo '# all fm-session-start-budget tests passed'
