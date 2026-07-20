#!/usr/bin/env bash
# Behavior tests for per-task codeburn baseline subtraction and snapshots.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE="$ROOT/bin/fm-task-usage.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-usage)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/worktree"

cat > "$FAKEBIN/codeburn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CODEBURN_ARGS_LOG"
cat "$FM_CODEBURN_FIXTURE"
SH
chmod +x "$FAKEBIN/codeburn"

cat > "$TMP_ROOT/baseline.json" <<'JSON'
{"overview":{"cost":1.25,"calls":2,"tokens":{"input":10,"output":20,"cacheRead":30,"cacheWrite":40}},"models":[{"name":"Sonnet 5","calls":2,"inputTokens":10,"outputTokens":20,"cacheReadTokens":30,"cacheWriteTokens":40,"cost":1.25}]}
JSON
cat > "$TMP_ROOT/current.json" <<'JSON'
{"overview":{"cost":2.75,"calls":5,"tokens":{"input":14,"output":29,"cacheRead":80,"cacheWrite":47}},"models":[{"name":"Sonnet 5","calls":4,"inputTokens":14,"outputTokens":29,"cacheReadTokens":80,"cacheWriteTokens":47,"cost":2.75},{"name":"<synthetic>","calls":1,"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0,"cost":0}]}
JSON

fm_write_meta "$HOME_DIR/state/task-a.meta" \
  "worktree=$HOME_DIR/worktree" \
  "harness=claude" \
  "model=sonnet" \
  "kind=ship" \
  "spawned_at=2026-07-19T12:34:56Z"

export FM_CODEBURN_BIN="$FAKEBIN/codeburn"
export FM_CODEBURN_ARGS_LOG="$TMP_ROOT/args.log"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/baseline.json"
FM_HOME="$HOME_DIR" "$USAGE" task-a --baseline

export FM_CODEBURN_FIXTURE="$TMP_ROOT/current.json"
json=$(FM_HOME="$HOME_DIR" "$USAGE" task-a --json)
node -e '
const u=JSON.parse(process.argv[1])
if (u.harness !== "claude" || u.configured_model !== "sonnet") process.exit(1)
if (u.actual_models.join(",") !== "Sonnet 5") process.exit(1)
if (JSON.stringify(u.tokens) !== JSON.stringify({input:4,output:9,cache_read:50,cache_write:7})) process.exit(1)
if (u.cost_usd !== 1.5 || u.calls !== 3 || !u.correlation.baseline) process.exit(1)
' "$json" || fail "task usage did not subtract the spawn baseline: $json"
pass "live task usage subtracts pooled-worktree baseline totals"

text=$(FM_HOME="$HOME_DIR" "$USAGE" task-a --snapshot)
assert_contains "$text" "claude / Sonnet 5" "compact usage should identify harness and actual model"
assert_contains "$text" '$1.5000 | 3 calls' "compact usage should include cost and calls"
assert_present "$HOME_DIR/data/task-a/usage.json" "teardown-style snapshot was not saved"
rm -f "$HOME_DIR/state/task-a.meta"
historical=$(FM_HOME="$HOME_DIR" "$USAGE" task-a --json)
node -e 'const u=JSON.parse(process.argv[1]); if (u.id !== "task-a" || u.cost_usd !== 1.5) process.exit(1)' "$historical" \
  || fail "durable usage snapshot was not readable after metadata removal"
pass "snapshot survives task metadata and worktree lifecycle"

fm_write_meta "$HOME_DIR/state/old-task.meta" \
  "worktree=$HOME_DIR/worktree" \
  "harness=codex" \
  "kind=scout"
FM_HOME="$HOME_DIR" "$USAGE" old-task --json >/dev/null
grep -Eq -- '--from [0-9]{4}-[0-9]{2}-[0-9]{2}' "$TMP_ROOT/args.log" \
  || fail "old metadata should fall back to a date-scoped query"
pass "old metadata without spawned_at degrades to a date-scoped total"

cat > "$FAKEBIN/codeburn" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "$FAKEBIN/codeburn"
unset FM_CODEBURN_FIXTURE

fm_write_meta "$HOME_DIR/state/hung-task.meta" \
  "worktree=$HOME_DIR/worktree" \
  "harness=claude" \
  "kind=ship" \
  "spawned_at=2026-07-19T12:34:56Z"

start=$(date +%s)
FM_TASK_USAGE_TIMEOUT=1 FM_HOME="$HOME_DIR" "$USAGE" hung-task --json >/dev/null 2>"$TMP_ROOT/hung.err"
rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -ne 0 ] || fail "usage query should fail when codeburn hangs past the timeout"
[ "$elapsed" -lt 20 ] || fail "usage query took ${elapsed}s, timeout did not bound the hung codeburn call"
assert_contains "$(cat "$TMP_ROOT/hung.err")" "codeburn usage unavailable" \
  "hung codeburn call should be reported as unavailable, not hang"
pass "hung codeburn report is bounded by a timeout instead of blocking"

printf '# all fm-task-usage tests passed\n'
