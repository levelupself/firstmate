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
    FM_TREEHOUSE_SYSTEM_PATH="$TMP_ROOT/system-local:$TMP_ROOT/system-homebrew" \
    "$ROOT/bin/fm-pool-build-sweep.sh" --dry-run
}
# Contain the login-shell fallback so tests never consult real pool inventories.
rm "$TMP_ROOT/bin/bash"
cat > "$TMP_ROOT/bin/bash" <<'SH'
#!/bin/bash
if [ "${1:-}" = -lc ]; then
  printf '%s\n' "$2" >> "$TEST_FALLBACK_LOG"
  exit 127
fi
exec /bin/bash "$@"
SH
chmod +x "$TMP_ROOT/bin/bash"
export TEST_FALLBACK_LOG="$TMP_ROOT/fallback-log"
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
mkdir -p "$TMP_ROOT/system-local" "$TMP_ROOT/system-homebrew"
cp "$TMP_ROOT/account/.local/bin/treehouse" "$TMP_ROOT/system-homebrew/treehouse"
printf '#!/missing/interpreter\n' > "$TMP_ROOT/system-local/treehouse"
chmod +x "$TMP_ROOT/system-local/treehouse"
sweep > "$TMP_ROOT/local-precedence"
assert_not_contains "$(cat "$TMP_ROOT/local-precedence")" 'skipped=' 'system install took precedence over local install'
rm "$TMP_ROOT/account/.local/bin/treehouse"
sweep > "$TMP_ROOT/system-precedence"
assert_contains "$(cat "$TMP_ROOT/system-precedence")" 'skipped=treehouse-not-found' 'system install order was not preserved'
rm "$TMP_ROOT/system-local/treehouse"
: > "$TEST_DISCOVERY_LOG"
sweep > "$TMP_ROOT/system-fallback"
for project in one two; do
  assert_contains "$(cat "$TEST_DISCOVERY_LOG")" "$TMP_ROOT/home/projects/$project" 'system fallback was not used for each project'
done
pass 'isolated system fallbacks preserve discovery order'
# A broken interpreter produces ENOENT even when discovery found the file.
printf '#!/missing/interpreter\n' > "$TMP_ROOT/bin/treehouse"
chmod +x "$TMP_ROOT/bin/treehouse"
sweep > "$TMP_ROOT/broken"
assert_contains "$(cat "$TMP_ROOT/broken")" 'skipped=treehouse-not-found' 'launch ENOENT escaped per-project skip handling'
assert_contains "$(cat "$TMP_ROOT/broken")" "$TMP_ROOT/home/projects/two" 'launch ENOENT stopped project iteration'
pass 'PATH precedence and launch ENOENT remain per-project skips'

assert_contains "$(cat "$TEST_FALLBACK_LOG")" 'treehouse status --json' 'launch failure never tried login-shell fallback'
pass 'failed login-shell fallback stays a per-project skip'
