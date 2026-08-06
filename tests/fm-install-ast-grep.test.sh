#!/usr/bin/env bash
# Behavior tests for the pinned ast-grep installer and its sg collision boundary.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-install-ast-grep-tests)

make_fake_tools() {  # <dir> <reported-version>
  local dir=$1 reported_version=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '%s  %s\n' '78931ae35ebac33d9a72b3aecea3e3d62d6e5b0b718ac8bbedfbe69d68421e41' "$1"
SH
  cat > "$fakebin/python3" <<SH
#!/usr/bin/env bash
cat >/dev/null
cat > "\$3" <<'BIN'
#!/usr/bin/env bash
printf '%s\n' 'ast-grep $reported_version'
BIN
SH
  chmod +x "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/python3"
  printf '%s\n' "$fakebin"
}

test_installs_only_ast_grep_and_preserves_sg() {
  local case_dir fakebin destination out
  case_dir="$TMP_ROOT/install-only-ast-grep"
  destination="$case_dir/destination"
  mkdir -p "$destination"
  printf '%s\n' 'standard sg sentinel' > "$destination/sg"
  fakebin=$(make_fake_tools "$case_dir" 0.45.0)
  out=$(PATH="$fakebin:/usr/bin:/bin" "$ROOT/bin/fm-install-ast-grep.sh" "$destination" 2>&1) \
    || fail "ast-grep installer rejected its exact pin fixture"
  assert_contains "$out" "ast-grep 0.45.0" "installer did not verify the exact ast-grep pin"
  [ -x "$destination/ast-grep" ] || fail "installer did not create the ast-grep executable"
  [ "$(cat "$destination/sg")" = "standard sg sentinel" ] \
    || fail "installer changed the existing sg command"
  pass "ast-grep installer installs only ast-grep and preserves sg"
}

test_rejects_wrong_installed_version() {
  local case_dir fakebin destination out rc
  case_dir="$TMP_ROOT/wrong-version"
  destination="$case_dir/destination"
  mkdir -p "$destination"
  printf '%s\n' 'working ast-grep sentinel' > "$destination/ast-grep"
  chmod +x "$destination/ast-grep"
  fakebin=$(make_fake_tools "$case_dir" 0.44.1)
  out=$(PATH="$fakebin:/usr/bin:/bin" "$ROOT/bin/fm-install-ast-grep.sh" "$destination" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an ast-grep binary outside the exact pin"
  assert_contains "$out" "expected exact pin 0.45.0" "installer did not explain the version rejection"
  [ "$(cat "$destination/ast-grep")" = "working ast-grep sentinel" ] \
    || fail "installer replaced an existing ast-grep before validating the candidate"
  pass "ast-grep installer rejects a binary outside the exact pin"
}

test_installs_only_ast_grep_and_preserves_sg
test_rejects_wrong_installed_version
