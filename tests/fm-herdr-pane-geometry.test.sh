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
# Where the probe actually placed this call, recorded so a test can observe the
# directory its children run in rather than the one it claims to use. A deleted
# directory has no readable name and is recorded as such.
if [ -n "${FM_TEST_CWD_LOG:-}" ]; then
  pwd -P >> "$FM_TEST_CWD_LOG" 2>/dev/null \
    || printf 'unreadable\n' >> "$FM_TEST_CWD_LOG"
fi
# The real server is told which pane to answer about; it does not read the
# caller's environment. This fixture does the same, so a probe bound entirely on
# its command line is answered exactly as the server would answer it.
case "${1:-} ${2:-}" in
  'pane get') HERDR_PANE_ID=${3:-${HERDR_PANE_ID:-}} ;;
  'pane layout') [ "${3:-}" != --pane ] || HERDR_PANE_ID=${4:-${HERDR_PANE_ID:-}} ;;
esac
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
          '{result:{layout:{panes:[{pane_id:$pane,rect:{x:0,y:0,width:45,height:20}}]}}}'
        ;;
      omitted)
        jq -cn '{result:{layout:{panes:[{pane_id:"w1:p9",rect:{x:0,y:0,width:45,height:20}}]}}}'
        ;;
      incomplete) jq -cn '{result:{layout:{panes:[{}]}}}' ;;
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

# Set to a path to have the server fixture record the directory each call was
# placed from; empty leaves the fixture silent, which is every other case here.
CWD_LOG=

run_probe() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION=geometry-test HERDR_PANE_ID=w1:p2 \
    FM_TEST_CWD_LOG="$CWD_LOG" \
    FM_TEST_PANE_CWD="$1" FM_TEST_LAYOUT_STATE="${2:-live}" \
    FM_TEST_PANE_STATE="${3:-live}" "$PROBE"
}

# The same probe with NO pane identity in the environment at all, so only what
# the caller passes on the command line can bind it to a pane. This is the
# channel the cockpit adapter owns: the environment a painter is launched with
# is the vendor's to fill, while an argument is the adapter's own.
run_probe_argv() {  # <cwd> <probe arguments...>
  local cwd=$1
  shift
  env -u HERDR_SESSION -u HERDR_PANE_ID \
    PATH="$FAKEBIN:$PATH" FM_TEST_PANE_CWD="$cwd" \
    FM_TEST_LAYOUT_STATE=live FM_TEST_PANE_STATE=live "$PROBE" "$@"
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

# This probe runs as a child of the fleet painter, so for as long as it works it
# is part of the pane's foreground process group and its directory is what Herdr
# reports as that pane's foreground_cwd. bin/backends/herdr.sh proves painter
# ownership from exactly that value, so a probe that moved to the tracked code
# root for every server call made its own pane read as a painter belonging to
# another home for the whole window it was open, and any liveness read landing
# in that window reported a healthy cockpit frame as not live.
test_server_calls_stay_in_the_callers_directory() {
  local log="$TMP_ROOT/call-cwd.log" expected line seen=0
  expected=$(cd "$PANE_HOME" && pwd -P)
  rm -f "$log"
  CWD_LOG=$log
  (cd "$PANE_HOME" && run_probe "$PANE_HOME") >/dev/null \
    || fail "the probe did not report geometry from a live caller directory"
  CWD_LOG=
  [ -s "$log" ] || fail "the probe made no server call to observe"
  while IFS= read -r line; do
    seen=$((seen + 1))
    [ "$line" = "$expected" ] \
      || fail "a server call ran in [$line] instead of the caller's own directory [$expected]"
  done < "$log"
  [ "$seen" -ge 2 ] || fail "the probe made fewer server calls than expected: $seen"
  pass "every server call runs in the caller's own directory"
}

# The move to the tracked code root exists for the home deleted under a running
# painter, where the caller's directory no longer has a usable name at all.
# Making that move conditional must not cost the probe that fallback, so a call
# placed from a deleted directory still has to land in a readable one.
test_deleted_caller_directory_falls_back_to_the_code_root() {
  local doomed="$TMP_ROOT/doomed-home" log="$TMP_ROOT/doomed-cwd.log" expected line seen=0
  expected=$(cd "$ROOT" && pwd -P)
  rm -rf "$doomed"
  mkdir -p "$doomed"
  rm -f "$log"
  CWD_LOG=$log
  (cd "$doomed" && rm -rf "$doomed" && run_probe "$PANE_HOME") >/dev/null 2>&1 || true
  CWD_LOG=
  [ -s "$log" ] || fail "the probe placed no server call from the deleted directory"
  while IFS= read -r line; do
    seen=$((seen + 1))
    [ "$line" = "$expected" ] \
      || fail "a server call from a deleted directory ran in [$line] instead of the tracked code root [$expected]"
  done < "$log"
  [ "$seen" -ge 1 ] || fail "no server call was recorded from the deleted directory"
  pass "a deleted caller directory falls back to the tracked code root"
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

test_incomplete_layout_inventory_is_transient() {
  local rc=0
  run_probe "$PANE_HOME" incomplete >/dev/null 2>&1 || rc=$?
  expect_code 75 "$rc" "an incomplete pane inventory must remain transient"
  pass "an incomplete layout inventory is classified as transient"
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

# --- explicit identity channel ---------------------------------------------
#
# A painter is launched into a pane by the cockpit adapter, which already knows
# the exact session and pane it recorded. Reading that identity back out of the
# environment makes the probe depend on a variable nobody in this repo sets, so
# these pin the argument form the adapter can actually guarantee.

test_explicit_identity_reports_geometry_without_environment() {
  local out
  out=$(run_probe_argv "$PANE_HOME" --session geometry-test --pane w1:p2) \
    || fail "an explicitly bound pane did not report geometry"
  [ "$out" = '45 20' ] \
    || fail "the explicitly bound pane reported unexpected geometry: $out"
  pass "an explicit --session/--pane binding resolves geometry with no environment identity"
}

test_explicit_identity_accepts_the_equals_spelling() {
  local out
  out=$(run_probe_argv "$PANE_HOME" --session=geometry-test --pane=w1:p2) \
    || fail "the --flag=value spelling did not report geometry"
  [ "$out" = '45 20' ] || fail "the --flag=value spelling reported: $out"
  pass "the explicit binding accepts the --flag=value spelling"
}

test_explicit_identity_overrides_the_environment() {
  local rc=0
  # The environment names a pane the server does not have; the argument names
  # the one it does. The argument has to win, or the adapter cannot bind a
  # painter whose ambient identity is wrong.
  PATH="$FAKEBIN:$PATH" HERDR_SESSION=wrong-session HERDR_PANE_ID=w1:p9 \
    FM_TEST_PANE_CWD="$PANE_HOME" FM_TEST_LAYOUT_STATE=live FM_TEST_PANE_STATE=live \
    "$PROBE" --session geometry-test --pane w1:p2 >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "an explicit binding must override a conflicting environment"
  pass "an explicit binding overrides a conflicting ambient pane identity"
}

test_absent_identity_is_permanent() {
  local rc=0
  run_probe_argv "$PANE_HOME" >/dev/null 2>&1 || rc=$?
  expect_code 64 "$rc" "an identity that cannot be resolved at all must be permanent"
  pass "a probe with no identity at all is classified as permanent, not retryable"
}

test_half_given_identity_is_refused() {
  local rc=0
  run_probe_argv "$PANE_HOME" --pane w1:p2 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a pane without a session must be refused as a caller error"
  rc=0
  run_probe_argv "$PANE_HOME" --session geometry-test >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a session without a pane must be refused as a caller error"
  pass "a half-given explicit identity is refused instead of silently falling back"
}

test_malformed_identity_is_refused() {
  local rc=0
  run_probe_argv "$PANE_HOME" --session geometry-test --pane '' >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an empty pane value must be refused"
  rc=0
  run_probe_argv "$PANE_HOME" --session geometry-test --pane 'w1:p2 extra' >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a pane value carrying whitespace must be refused"
  rc=0
  run_probe_argv "$PANE_HOME" --session --pane w1:p2 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a flag swallowed as a value must be refused"
  pass "a malformed explicit identity is refused rather than probed"
}

test_malformed_environment_identity_is_permanent() {
  local rc=0
  PATH="$FAKEBIN:$PATH" HERDR_SESSION=geometry-test HERDR_PANE_ID='w1:p2 extra' \
    FM_TEST_PANE_CWD="$PANE_HOME" FM_TEST_LAYOUT_STATE=live FM_TEST_PANE_STATE=live \
    "$PROBE" >/dev/null 2>&1 || rc=$?
  expect_code 64 "$rc" "an unusable ambient identity must be permanent, not retryable"
  pass "an unusable ambient pane identity is classified as permanent"
}

test_unknown_argument_is_refused() {
  local rc=0
  run_probe_argv "$PANE_HOME" --session geometry-test --pane w1:p2 --extra >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown argument must be refused"
  pass "an unknown argument is refused instead of ignored"
}

test_live_pane_reports_geometry
test_missing_cwd_is_permanent
test_server_calls_stay_in_the_callers_directory
test_deleted_caller_directory_falls_back_to_the_code_root
test_healthy_pane_layout_failure_is_transient
test_successful_layout_omitting_exact_pane_is_permanent
test_malformed_layout_is_transient
test_incomplete_layout_inventory_is_transient
test_malformed_pane_get_is_transient
test_wrong_pane_identity_is_transient
test_incomplete_pane_get_is_transient
test_explicit_identity_reports_geometry_without_environment
test_explicit_identity_accepts_the_equals_spelling
test_explicit_identity_overrides_the_environment
test_absent_identity_is_permanent
test_half_given_identity_is_refused
test_malformed_identity_is_refused
test_malformed_environment_identity_is_permanent
test_unknown_argument_is_refused
