#!/usr/bin/env bash
# Behavioral coverage for bootstrap's explicit primary-harness auth probe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-harness-auth)
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

make_probe_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'ps from procps-ng (fake)'
  exit 0
fi
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=)
    if [ "${FM_FAKE_AMBIENT_HARNESS:-none}" = claude ] && [ "$pid" = 4242 ]; then
      printf '%s\n' claude
    else
      printf '%s\n' bash
    fi
    ;;
  ppid=)
    if [ "${FM_FAKE_AMBIENT_HARNESS:-none}" = claude ] && [ "$pid" != 4242 ]; then
      printf '%s\n' 4242
    else
      printf '%s\n' 1
    fi
    ;;
  args=) printf '%s\n' bash ;;
esac
SH
  chmod +x "$fakebin/gh" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

run_network_probe() {
  local fakebin=$1 ambient=$2
  env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u PI_CODING_AGENT -u GROK_AGENT -u FM_BOOTSTRAP_PRIMARY_HARNESS \
    PATH="$fakebin:$BASE_PATH" FM_FAKE_AMBIENT_HARNESS="$ambient" \
    FM_BACKEND=tmux FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$BOOTSTRAP"
}

test_ambient_ancestry_does_not_select_the_auth_probe() {
  local fakebin without_ambient with_ambient
  mkdir -p "$TMP_ROOT/home/config"
  fakebin=$(make_probe_toolchain "$TMP_ROOT")

  without_ambient=$(run_network_probe "$fakebin" none)
  with_ambient=$(run_network_probe "$fakebin" claude)

  [ "$with_ambient" = "$without_ambient" ] || fail \
    "sandboxed bootstrap auth changed with ambient harness ancestry: without='$without_ambient' with='$with_ambient'"
  [ -z "$with_ambient" ] || fail \
    "sandboxed bootstrap auth should be silent without an explicit primary harness, got: $with_ambient"
  pass "bootstrap auth selection ignores ambient harness ancestry"
}

test_explicit_primary_harness_still_selects_the_auth_probe() {
  local fakebin out
  fakebin=$(make_probe_toolchain "$TMP_ROOT/explicit")
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" != 'auth status' ]
SH
  chmod +x "$fakebin/claude"

  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_FAKE_AMBIENT_HARNESS=none \
    FM_BOOTSTRAP_PRIMARY_HARNESS=claude FM_BACKEND=tmux \
    FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$BOOTSTRAP")

  [ "$out" = 'NEEDS_HARNESS_AUTH: claude (interactive: claude auth login --claudeai)' ] || fail \
    "an explicit Claude primary should run the auth probe, got: $out"
  pass "bootstrap auth selection honors an explicit primary harness"
}

test_ambient_ancestry_does_not_select_the_auth_probe
test_explicit_primary_harness_still_selects_the_auth_probe
