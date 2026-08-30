#!/usr/bin/env bash
# Classification tests for the authoritative Herdr pane-geometry probe.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-pane-geometry)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PROBE="$ROOT/bin/fm-herdr-pane-geometry.sh"
PANE_HOME="$TMP_ROOT/live-home"
mkdir -p "$PANE_HOME"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'pane get')
    case "${FM_TEST_PANE_STATE:-live}" in
      live)
        jq -cn --arg pane "${HERDR_PANE_ID:?}" --arg cwd "${FM_TEST_PANE_CWD:?}" \
          '{result:{pane:{pane_id:$pane,foreground_cwd:$cwd}}}'
        ;;
      malformed) printf '%s\n' '{"result":{"pane":' ;;
      wrong-identity)
        jq -cn --arg cwd "${FM_TEST_PANE_CWD:?}" \
          '{result:{pane:{pane_id:"w1:p9",foreground_cwd:$cwd}}}'
        ;;
      incomplete) jq -cn --arg pane "${HERDR_PANE_ID:?}" '{result:{pane:{pane_id:$pane}}}' ;;
      *) exit 2 ;;
    esac
    ;;
  'pane layout')
    case "${FM_TEST_LAYOUT_STATE:-live}" in
      live)
        jq -cn --arg pane "${HERDR_PANE_ID:?}" \
          '{result:{layout:{panes:[{pane_id:$pane,rect:{width:45,height:20}}]}}}'
        ;;
      omitted)
        jq -cn '{result:{layout:{panes:[{pane_id:"w1:p9",rect:{width:45,height:20}}]}}}'
        ;;
      malformed)
        printf '%s\n' '{"result":{"layout":'
        ;;
      transient) exit 1 ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

run_probe() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION=geometry-test HERDR_PANE_ID=w1:p2 \
    FM_TEST_PANE_CWD="$1" FM_TEST_LAYOUT_STATE="${2:-live}" \
    FM_TEST_PANE_STATE="${3:-live}" "$PROBE"
}

test_live_pane_reports_geometry() {
  local out
  out=$(run_probe "$PANE_HOME") || fail "a live pane with a real cwd did not report geometry"
  [ "$out" = '45 20' ] || fail "the live pane reported unexpected geometry: $out"
  pass "the geometry probe accepts a live authoritative pane and cwd"
}

test_missing_cwd_is_permanent() {
  local rc=0
  run_probe "$TMP_ROOT/deleted-home" >/dev/null 2>&1 || rc=$?
  expect_code 64 "$rc" "a missing authoritative foreground cwd must be permanent"
  pass "a missing authoritative foreground cwd is classified as permanent"
}

test_healthy_pane_layout_failure_is_transient() {
  local rc=0
  run_probe "$PANE_HOME" transient >/dev/null 2>&1 || rc=$?
  expect_code 75 "$rc" "a layout read failure for a healthy pane must be transient"
  pass "a healthy pane's layout read failure is classified as transient"
}

test_successful_layout_omitting_exact_pane_is_permanent() {
  local rc=0
  run_probe "$PANE_HOME" omitted >/dev/null 2>&1 || rc=$?
  expect_code 64 "$rc" "a successful layout omitting the exact pane must be permanent"
  pass "a successful authoritative layout omission is classified as permanent"
}

test_malformed_layout_is_transient() {
  local rc=0
  run_probe "$PANE_HOME" malformed >/dev/null 2>&1 || rc=$?
  expect_code 75 "$rc" "a malformed layout read must remain transient"
  pass "a malformed authoritative layout read is classified as transient"
}

test_malformed_pane_get_is_transient() {
  local rc=0
  run_probe "$PANE_HOME" live malformed >/dev/null 2>&1 || rc=$?
  expect_code 75 "$rc" "a malformed pane-get response must remain transient"
  pass "a malformed pane-get response is classified as transient"
}

test_wrong_pane_identity_is_transient() {
  local rc=0
  run_probe "$PANE_HOME" live wrong-identity >/dev/null 2>&1 || rc=$?
  expect_code 75 "$rc" "a wrong pane identity must not prove permanent absence"
  pass "a wrong pane identity is classified as transient"
}

test_incomplete_pane_get_is_transient() {
  local rc=0
  run_probe "$PANE_HOME" live incomplete >/dev/null 2>&1 || rc=$?
  expect_code 75 "$rc" "an incomplete pane-get response must remain transient"
  pass "an incomplete pane-get response is classified as transient"
}

test_live_pane_reports_geometry
test_missing_cwd_is_permanent
test_healthy_pane_layout_failure_is_transient
test_successful_layout_omitting_exact_pane_is_permanent
test_malformed_layout_is_transient
test_malformed_pane_get_is_transient
test_wrong_pane_identity_is_transient
test_incomplete_pane_get_is_transient
