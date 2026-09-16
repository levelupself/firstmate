#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-build-sweep-discovery)
mkdir -p "$TMP_ROOT/home"/{projects/one,projects/two,data} "$TMP_ROOT/bin" "$TMP_ROOT/account"
printf '%s\n' '- one - fixture' '- two - fixture' > "$TMP_ROOT/home/data/projects.md"
# Isolate discovery from installed tools without modifying the account's HOME.
for cmd in bash node dirname; do ln -s "$(command -v "$cmd")" "$TMP_ROOT/bin/$cmd"; done
sweep() {
  env HOME="$TMP_ROOT/account" PATH="$TMP_ROOT/bin" FM_HOME="$TMP_ROOT/home" \
    "$ROOT/bin/fm-pool-build-sweep.sh" --dry-run
}
if ! sweep > "$TMP_ROOT/missing" 2>&1; then
  cat "$TMP_ROOT/missing"
  fail 'missing treehouse aborted the sweep'
fi
for project in one two; do
  assert_contains "$(cat "$TMP_ROOT/missing")" "$TMP_ROOT/home/projects/$project" 'missing binary stopped project iteration'
done
assert_contains "$(cat "$TMP_ROOT/missing")" 'skipped=treehouse-not-found' 'missing binary was not reported as a skip'
pass 'missing treehouse skips every project without aborting'
mkdir -p "$TMP_ROOT/account/.local/bin"
cat > "$TMP_ROOT/account/.local/bin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >> "$TEST_DISCOVERY_LOG"
printf '[]\n'
SH
chmod +x "$TMP_ROOT/account/.local/bin/treehouse"
export TEST_DISCOVERY_LOG="$TMP_ROOT/discovery"
sweep > "$TMP_ROOT/fallback"
for project in one two; do
  assert_contains "$(cat "$TEST_DISCOVERY_LOG")" "$TMP_ROOT/home/projects/$project" 'local install was not used for each project'
done
pass 'documented local install works outside PATH'
# A broken interpreter produces ENOENT even when discovery found the file.
printf '#!/missing/interpreter\n' > "$TMP_ROOT/bin/treehouse"
chmod +x "$TMP_ROOT/bin/treehouse"
sweep > "$TMP_ROOT/broken"
assert_contains "$(cat "$TMP_ROOT/broken")" 'skipped=treehouse-not-found' 'launch ENOENT escaped per-project skip handling'
assert_contains "$(cat "$TMP_ROOT/broken")" "$TMP_ROOT/home/projects/two" 'launch ENOENT stopped project iteration'
pass 'PATH precedence and launch ENOENT remain per-project skips'
