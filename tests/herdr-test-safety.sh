#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
# Direct execution also runs hard-bounded binary-resolution and recursion
# regressions without touching a real Herdr session.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

herdr_test_safety_fail() {
  echo "herdr-test-safety: $*" >&2
  return 1
}

herdr_test_shadowed_path_terminates() {
  local tmp fakebin fakehome real_herdr calls output status count
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/herdr-test-safety.XXXXXX") || return 1
  fakebin="$tmp/fakebin"
  fakehome="$tmp/home"
  real_herdr="$fakehome/.local/bin/herdr"
  calls="$tmp/shim-calls"
  output="$tmp/output"
  mkdir -p "$fakebin" "$(dirname "$real_herdr")"

  cat > "$real_herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
EOF
cat > "$fakebin/herdr" <<'EOF'
#!/usr/bin/env bash
count=0
args=()
if [ -f "$FM_HERDR_TEST_SHIM_CALLS" ]; then
  count=$(cat "$FM_HERDR_TEST_SHIM_CALLS")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FM_HERDR_TEST_SHIM_CALLS"
if [ "$count" -gt 5 ]; then
  echo "herdr-test-safety: shadow shim process ceiling exceeded" >&2
  exit 97
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "${2:-}" = "$FM_HERDR_TEST_SESSION" ] || exit 1
    shift 2
    continue
  fi
  args+=("$1")
  shift
done
exec "$FM_HERDR_TEST_HELPER" run "$FM_HERDR_TEST_SESSION" "${args[@]}"
EOF
  chmod +x "$real_herdr" "$fakebin/herdr"

  status=0
  PATH="$fakebin:/usr/bin:/bin" \
    HOME="$fakehome" \
    FM_HERDR_TEST_HELPER="$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh" \
    FM_HERDR_TEST_SESSION=fm-lab-shadow-safety \
    FM_HERDR_TEST_SHIM_CALLS="$calls" \
    timeout 5 "$fakebin/herdr" status --json > "$output" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    cat "$output" >&2
    rm -rf "$tmp"
    herdr_test_safety_fail "shadowed PATH call failed with status $status"
    return 1
  fi
  count=$(cat "$calls")
  if [ "$count" -ne 1 ]; then
    rm -rf "$tmp"
    herdr_test_safety_fail "shadow shim was entered $count times instead of once"
    return 1
  fi
  if ! grep -Fxq 'status --json --session fm-lab-shadow-safety' "$output"; then
    cat "$output" >&2
    rm -rf "$tmp"
    herdr_test_safety_fail "real Herdr did not receive the isolated lab invocation"
    return 1
  fi
  rm -rf "$tmp"
}

herdr_test_explicit_bin_fails_closed() {
  local output status=0
  output=$(mktemp "${TMPDIR:-/tmp}/herdr-test-safety-output.XXXXXX") || return 1
  FM_HERDR_BIN=/definitely/not/an/executable \
    "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh" run fm-lab-explicit-bin status > "$output" 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$output"
    herdr_test_safety_fail "non-executable FM_HERDR_BIN was accepted"
    return 1
  fi
  if ! grep -Fq 'FM_HERDR_BIN is not executable' "$output"; then
    cat "$output" >&2
    rm -f "$output"
    herdr_test_safety_fail "non-executable FM_HERDR_BIN lacked a clear diagnostic"
    return 1
  fi
  rm -f "$output"
}

herdr_test_depth_guard() {
  local output status=0
  output=$(mktemp "${TMPDIR:-/tmp}/herdr-test-safety-depth.XXXXXX") || return 1
  FM_HERDR_LAB_DEPTH=2 \
    "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh" name depth > "$output" 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$output"
    herdr_test_safety_fail "depth guard allowed entry past depth 2"
    return 1
  fi
  if ! grep -Fq 'a herdr shim on PATH is the likely cause' "$output"; then
    cat "$output" >&2
    rm -f "$output"
    herdr_test_safety_fail "depth guard lacked the shadow-shim diagnostic"
    return 1
  fi
  rm -f "$output"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  herdr_test_shadowed_path_terminates
  herdr_test_explicit_bin_fails_closed
  herdr_test_depth_guard
  echo "herdr-test-safety: PASS"
fi
