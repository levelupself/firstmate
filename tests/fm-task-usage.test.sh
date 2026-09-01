#!/usr/bin/env bash
# Behavior tests for per-task codeburn discovery, baseline subtraction, and snapshots.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE="$ROOT/bin/fm-task-usage.sh"
ALLOCATION="$ROOT/bin/fm-worktree-allocation.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-usage)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
POOLED_WORKTREE="$HOME_DIR/pooled-worktree"
OTHER_WORKTREE="$HOME_DIR/other-worktree"
FRESH_WORKTREE="$HOME_DIR/fresh-worktree"
CROSS_WORKTREE="$HOME_DIR/cross-worktree"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$POOLED_WORKTREE" "$OTHER_WORKTREE" "$FRESH_WORKTREE" "$CROSS_WORKTREE"

cat > "$FAKEBIN/codeburn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CODEBURN_ARGS_LOG"
project=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --project ]; then
    project=${2:-}
    break
  fi
  shift
done
node - "$FM_CODEBURN_FIXTURE" "$project" <<'NODE'
const fs = require('fs')
const [fixturePath, selected] = process.argv.slice(2)
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'))
const empty = {
  overview: {cost: 0, calls: 0, sessions: 0, tokens: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0}},
  projects: [],
  models: [],
}
if (!selected) {
  const projects = fixture.projects.map(project => ({name: project.name, path: project.path}))
  process.stdout.write(JSON.stringify({...empty, projects}) + '\n')
} else {
  const project = fixture.projects.find(candidate => candidate.name === selected)
  process.stdout.write(JSON.stringify(project && !project.filter_miss ? project.report : empty) + '\n')
}
NODE
SH
chmod +x "$FAKEBIN/codeburn"

pooled_reported_path=${POOLED_WORKTREE#/}
pooled_reported_path=${pooled_reported_path//-/\/}
other_reported_path=${OTHER_WORKTREE#/}
other_reported_path=${other_reported_path//-/\/}

write_fixture() { # <file> <pooled cost> <pooled calls> <pooled sessions> <other cost> <other calls>
  local file=$1 pooled_cost=$2 pooled_calls=$3 pooled_sessions=$4 other_cost=$5 other_calls=$6
  cat > "$file" <<JSON
{"projects":[
  {"name":"opaque-key-reported-by-codeburn","path":"$pooled_reported_path","report":{"overview":{"cost":$pooled_cost,"calls":$pooled_calls,"sessions":$pooled_sessions,"tokens":{"input":$((pooled_calls * 10)),"output":$((pooled_calls * 20)),"cacheRead":$((pooled_calls * 30)),"cacheWrite":$((pooled_calls * 40))}},"projects":[{"name":"opaque-key-reported-by-codeburn","path":"$pooled_reported_path","cost":$pooled_cost,"calls":$pooled_calls,"sessions":$pooled_sessions}],"models":[{"name":"gpt-5.6-sol","calls":$pooled_calls,"inputTokens":$((pooled_calls * 10)),"outputTokens":$((pooled_calls * 20)),"cacheReadTokens":$((pooled_calls * 30)),"cacheWriteTokens":$((pooled_calls * 40)),"cost":$pooled_cost}]}},
  {"name":"another-opaque-codeburn-key","path":"$other_reported_path","report":{"overview":{"cost":$other_cost,"calls":$other_calls,"sessions":1,"tokens":{"input":$((other_calls * 11)),"output":$((other_calls * 21)),"cacheRead":$((other_calls * 31)),"cacheWrite":$((other_calls * 41))}},"projects":[{"name":"another-opaque-codeburn-key","path":"$other_reported_path","cost":$other_cost,"calls":$other_calls,"sessions":1}],"models":[{"name":"Opus 5","calls":$other_calls,"inputTokens":$((other_calls * 11)),"outputTokens":$((other_calls * 21)),"cacheReadTokens":$((other_calls * 31)),"cacheWriteTokens":$((other_calls * 41)),"cost":$other_cost}]}}
]}
JSON
}

fm_write_meta "$HOME_DIR/state/task-a.meta" \
  "worktree=$POOLED_WORKTREE" \
  "project=/srv/projects/firstmate" \
  "harness=codex" \
  "model=configured-model" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawned_at=2026-07-19T12:34:56Z"
mkdir -p "$HOME_DIR/data/task-a"
cat > "$HOME_DIR/data/task-a/brief.md" <<'MD'
You are a crewmate.

# Task
Fix task usage attribution

More task detail follows.
MD

export FM_CODEBURN_BIN="$FAKEBIN/codeburn"
export FM_CODEBURN_ARGS_LOG="$TMP_ROOT/args.log"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/baseline-a.json"
write_fixture "$FM_CODEBURN_FIXTURE" 1.25 2 1 5 8
FM_HOME="$HOME_DIR" "$USAGE" task-a --baseline

export FM_CODEBURN_FIXTURE="$TMP_ROOT/current-a.json"
write_fixture "$FM_CODEBURN_FIXTURE" 2.75 5 3 7 11
json_a=$(FM_HOME="$HOME_DIR" "$USAGE" task-a --json)
node -e '
const u=JSON.parse(process.argv[1])
if (u.schema !== "fm-task-usage.v2") process.exit(1)
if (u.id !== "task-a" || u.title !== "Fix task usage attribution") process.exit(1)
if (u.kind !== "ship" || u.project !== "/srv/projects/firstmate" || u.delivery_mode !== "no-mistakes") process.exit(1)
if (u.harness !== "codex" || u.configured_model !== "configured-model") process.exit(1)
if (u.actual_models.join(",") !== "gpt-5.6-sol") process.exit(1)
if (JSON.stringify(u.tokens) !== JSON.stringify({input:30,output:60,cache_read:90,cache_write:120})) process.exit(1)
if (u.cost_usd !== 1.5 || u.calls !== 3 || u.sessions !== 2 || !u.correlation.baseline) process.exit(1)
if (u.correlation.project_key !== "opaque-key-reported-by-codeburn") process.exit(1)
if (!(u.duration_seconds > 0) || !u.spawned_at || !u.captured_at) process.exit(1)
' "$json_a" || fail "task usage did not discover the reported project key and subtract the spawn baseline: $json_a"
assert_contains "$(cat "$TMP_ROOT/args.log")" '--project opaque-key-reported-by-codeburn' \
  "the codeburn filter must use the key reported by project discovery"
if grep -F -- "--project $POOLED_WORKTREE" "$TMP_ROOT/args.log" >/dev/null; then
  fail "the codeburn filter must not use the filesystem path directly"
fi
pass "project discovery selects codeburn's reported key and returns attributed totals and actual models"

text=$(FM_HOME="$HOME_DIR" "$USAGE" task-a --snapshot)
assert_contains "$text" "codex / gpt-5.6-sol" "compact usage should identify harness and actual model"
# shellcheck disable=SC2016  # single-quoted: literal '$1.5000' string, not a bash expansion
assert_contains "$text" '$1.5000 | 3 calls | 2 sessions | elapsed ' \
  "compact usage should surface cost, calls, sessions, and wall-clock duration"
assert_present "$HOME_DIR/data/task-a/usage.json" "teardown-style snapshot was not saved"
EFFORT_DB="$HOME_DIR/data/effort-store.sqlite"
assert_present "$EFFORT_DB" "live usage snapshot did not populate the effort store"
snapshot_row=$(node - "$EFFORT_DB" <<'NODE'
process.emitWarning = () => {}
const {DatabaseSync} = require('node:sqlite')
const db = new DatabaseSync(process.argv[2], {readOnly: true})
const task = db.prepare('SELECT model, tokens_in, tokens_out, tokens_cached_read, tokens_cached_write, notional_cost_usd, api_calls, sessions, teardown_at FROM task WHERE task_id = ?').get('task-a')
const models = db.prepare('SELECT model FROM task_model WHERE task_id = ? ORDER BY model').all('task-a').map(row => row.model)
process.stdout.write(JSON.stringify({task, models}))
NODE
)
node -e '
const row=JSON.parse(process.argv[1])
if (!row.task || row.task.model !== "configured-model") process.exit(1)
if (row.task.tokens_in !== 30 || row.task.tokens_out !== 60) process.exit(1)
if (row.task.tokens_cached_read !== 90 || row.task.tokens_cached_write !== 120) process.exit(1)
if (row.task.notional_cost_usd !== 1.5 || row.task.api_calls !== 3 || row.task.sessions !== 2) process.exit(1)
if (row.task.teardown_at !== null || row.models.join(",") !== "gpt-5.6-sol") process.exit(1)
' "$snapshot_row" || fail "live usage snapshot did not capture attributed effort and models: $snapshot_row"
pass "real v2 usage snapshot incrementally populates live task effort"
rm -f "$HOME_DIR/state/task-a.meta"
historical=$(FM_HOME="$HOME_DIR" "$USAGE" task-a --json)
node -e 'const u=JSON.parse(process.argv[1]); if (u.id !== "task-a" || u.cost_usd !== 1.5) process.exit(1)' "$historical" \
  || fail "durable usage snapshot was not readable after metadata removal"
pass "v2 snapshot survives task metadata and worktree lifecycle"

# A later occupant of the same pooled worktree starts at task A's final total.
fm_write_meta "$HOME_DIR/state/task-b.meta" \
  "worktree=$POOLED_WORKTREE" \
  "project=/srv/projects/firstmate" \
  "title=Verify pooled attribution" \
  "harness=claude" \
  "kind=scout" \
  "spawned_at=2026-07-19T13:34:56Z"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/baseline-b.json"
write_fixture "$FM_CODEBURN_FIXTURE" 2.75 5 3 7 11
FM_HOME="$HOME_DIR" "$USAGE" task-b --baseline
export FM_CODEBURN_FIXTURE="$TMP_ROOT/current-b.json"
write_fixture "$FM_CODEBURN_FIXTURE" 3.25 7 4 7 11
json_b=$(FM_HOME="$HOME_DIR" "$USAGE" task-b --json)
node -e '
const a=JSON.parse(process.argv[1]), b=JSON.parse(process.argv[2])
if (b.cost_usd !== 0.5 || b.calls !== 2 || b.sessions !== 1) process.exit(1)
if (b.tokens.input !== 20 || b.actual_models.join(",") !== "gpt-5.6-sol") process.exit(1)
if (a.cost_usd === b.cost_usd || a.calls === b.calls || a.tokens.input === b.tokens.input) process.exit(1)
' "$json_a" "$json_b" || fail "different tasks were not independently attributed: a=$json_a b=$json_b"
pass "a later pooled-worktree occupant subtracts the earlier occupant and two tasks have different totals"

# codeburn 0.9.19 applies --project to projects/models but leaves overview at
# the account-wide total. The filtered rows, not overview, own task attribution.
fm_write_meta "$HOME_DIR/state/filtered-overview.meta" \
  "worktree=$OTHER_WORKTREE" \
  "project=/srv/projects/other" \
  "harness=claude" \
  "kind=ship" \
  "spawned_at=2026-07-19T14:00:00Z"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/filtered-overview-baseline.json"
write_fixture "$FM_CODEBURN_FIXTURE" 3.25 7 4 1 2
node - "$FM_CODEBURN_FIXTURE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'))
fixture.projects[1].report.overview = {
  cost: 101,
  calls: 1002,
  sessions: 101,
  tokens: {input: 10000, output: 20000, cacheRead: 30000, cacheWrite: 40000},
}
fs.writeFileSync(file, `${JSON.stringify(fixture)}\n`)
NODE
FM_HOME="$HOME_DIR" "$USAGE" filtered-overview --baseline
export FM_CODEBURN_FIXTURE="$TMP_ROOT/filtered-overview-current.json"
write_fixture "$FM_CODEBURN_FIXTURE" 3.25 7 4 2.5 5
node - "$FM_CODEBURN_FIXTURE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'))
fixture.projects[1].report.overview = {
  cost: 202.5,
  calls: 2005,
  sessions: 202,
  tokens: {input: 20000, output: 40000, cacheRead: 60000, cacheWrite: 80000},
}
fs.writeFileSync(file, `${JSON.stringify(fixture)}\n`)
NODE
filtered_usage=$(FM_HOME="$HOME_DIR" "$USAGE" filtered-overview --json)
node -e '
const u=JSON.parse(process.argv[1])
if (u.cost_usd !== 1.5 || u.calls !== 3 || u.sessions !== 0) process.exit(1)
if (JSON.stringify(u.tokens) !== JSON.stringify({input:33,output:63,cache_read:93,cache_write:123})) process.exit(1)
' "$filtered_usage" || fail "account-wide overview leaked into filtered task usage: $filtered_usage"
pass "filtered project and model rows override codeburn's unfiltered account-wide overview"

# A slot with no earlier same-day owner has a true zero at launch even though
# codeburn does not publish its key until the first call lands.
fresh_reported_path=${FRESH_WORKTREE#/}
fresh_reported_path=${fresh_reported_path//-/\/}
fm_write_meta "$HOME_DIR/state/fresh-late-key.meta" \
  "worktree=$FRESH_WORKTREE" \
  "project=/srv/projects/fresh" \
  "harness=codex" \
  "kind=ship" \
  "spawned_at=2026-07-20T10:00:00Z"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/fresh-before-first-call.json"
write_fixture "$FM_CODEBURN_FIXTURE" 3.25 7 4 7 11
node - "$FM_CODEBURN_FIXTURE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'))
fixture.projects = fixture.projects.filter(project => project.name === 'another-opaque-codeburn-key')
fs.writeFileSync(file, `${JSON.stringify(fixture)}\n`)
NODE
rm -f "$HOME_DIR/data/cost-attribution.tsv"
if FM_HOME="$HOME_DIR" "$USAGE" fresh-late-key --baseline >/dev/null 2>"$TMP_ROOT/missing-ledger.err"; then
  fail "a missing ownership ledger proved a fresh zero baseline"
fi
assert_contains "$(cat "$TMP_ROOT/missing-ledger.err")" "could not be verified" \
  "a missing ownership ledger did not preserve attribution uncertainty"
printf '%s\n' 'unstructured ownership data' > "$HOME_DIR/data/cost-attribution.tsv"
if FM_HOME="$HOME_DIR" "$USAGE" fresh-late-key --baseline >/dev/null 2>"$TMP_ROOT/incomplete-ledger.err"; then
  fail "an incomplete ownership ledger proved a fresh zero baseline"
fi
assert_contains "$(cat "$TMP_ROOT/incomplete-ledger.err")" "could not be verified" \
  "an incomplete ownership ledger did not preserve attribution uncertainty"
printf '%s\n' '# schema=firstmate-effort-attribution-v2' \
  > "$HOME_DIR/data/cost-attribution.tsv"
printf 'task\tworktree\tharness\tmodel\teffort\tkind\tproject\tstarted_at\tended_at\n' \
  >> "$HOME_DIR/data/cost-attribution.tsv"
if FM_HOME="$HOME_DIR" "$USAGE" fresh-late-key --baseline >/dev/null 2>"$TMP_ROOT/header-only-ledger.err"; then
  fail "a header-only lifecycle ledger proved a fresh zero baseline"
fi
assert_contains "$(cat "$TMP_ROOT/header-only-ledger.err")" "could not be verified" \
  "a header-only ledger without allocation provenance did not preserve uncertainty"
FM_HOME="$HOME_DIR" "$ALLOCATION" acquire history-start "$OTHER_WORKTREE" 2026-07-20T09:00:00Z reused >/dev/null \
  || fail "allocation history initialization failed"
FRESH_DISPOSITION=$(FM_HOME="$HOME_DIR" "$ALLOCATION" acquire fresh-late-key "$FRESH_WORKTREE" 2026-07-20T10:00:00Z fresh) \
  || fail "fresh allocation provenance failed"
[ "$FRESH_DISPOSITION" = first-owner ] || fail "new working-copy identity was not recorded as first owner"
printf '%s\n' 'worktree_allocation=first-owner' >> "$HOME_DIR/state/fresh-late-key.meta"
FM_HOME="$HOME_DIR" "$USAGE" fresh-late-key --baseline \
  || fail "a fresh worktree without a pre-call codeburn key did not record a zero baseline"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/fresh-after-first-call.json"
cat > "$FM_CODEBURN_FIXTURE" <<JSON
{"projects":[{"name":"late-codeburn-key","path":"$fresh_reported_path","report":{"overview":{"cost":999,"calls":999,"sessions":999,"tokens":{"input":999,"output":999,"cacheRead":999,"cacheWrite":999}},"projects":[{"name":"late-codeburn-key","path":"$fresh_reported_path","cost":0.75,"calls":4,"sessions":1}],"models":[{"name":"gpt-5.6-sol","calls":4,"inputTokens":120,"outputTokens":30,"cacheReadTokens":400,"cacheWriteTokens":0,"cost":0.75}]}}]}
JSON
fresh_usage=$(FM_HOME="$HOME_DIR" "$USAGE" fresh-late-key --json)
node -e '
const u=JSON.parse(process.argv[1])
if (u.cost_usd !== 0.75 || u.calls !== 4 || u.sessions !== 1) process.exit(1)
if (u.tokens.input !== 120 || u.tokens.output !== 30 || u.tokens.cache_read !== 400) process.exit(1)
if (u.correlation.baseline_kind !== "fresh-worktree-zero") process.exit(1)
' "$fresh_usage" || fail "the first post-work read did not measure a late-published key from zero: $fresh_usage"
pass "a fresh worktree reports real usage on its first read after codeburn publishes the key"
FM_HOME="$HOME_DIR" "$ALLOCATION" release fresh-late-key "$FRESH_WORKTREE" 2026-07-20T10:20:00Z \
  || fail "fresh allocation release history failed"
RECREATED_DISPOSITION=$(FM_HOME="$HOME_DIR" "$ALLOCATION" acquire recreated-slot "$FRESH_WORKTREE" 2026-07-20T10:25:00Z fresh) \
  || fail "recreated allocation history failed"
[ "$RECREATED_DISPOSITION" = reused ] \
  || fail "recreated path identity lost its durable prior-owner history"
pass "recreated working-copy paths retain prior-owner allocation history"
rm -f "$HOME_DIR/state/fresh-late-key.meta"

# The same absent-key observation is not a zero when a prior task already held
# the slot during this report period.
fm_write_meta "$HOME_DIR/state/reused-late-key.meta" \
  "worktree=$POOLED_WORKTREE" \
  "project=/srv/projects/firstmate" \
  "harness=codex" \
  "kind=ship" \
  "worktree_allocation=reused" \
  "spawned_at=2026-07-19T17:00:00Z"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/reused-before-key.json"
write_fixture "$FM_CODEBURN_FIXTURE" 3.25 7 4 7 11
node - "$FM_CODEBURN_FIXTURE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'))
fixture.projects = fixture.projects.filter(project => project.name === 'another-opaque-codeburn-key')
fs.writeFileSync(file, `${JSON.stringify(fixture)}\n`)
NODE
if FM_HOME="$HOME_DIR" "$USAGE" reused-late-key --baseline >/dev/null 2>"$TMP_ROOT/reused-baseline.err"; then
  fail "a reused worktree with earlier same-day ownership accepted an unknown zero baseline"
fi
assert_contains "$(cat "$TMP_ROOT/reused-baseline.err")" "reused worktree" \
  "the reused-worktree refusal did not explain why zero was unsafe"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/current-b.json"
if FM_HOME="$HOME_DIR" "$USAGE" reused-late-key --json >/dev/null 2>"$TMP_ROOT/reused-read.err"; then
  fail "a later key caused reused-worktree spend to be attributed without a baseline"
fi
assert_contains "$(cat "$TMP_ROOT/reused-read.err")" "saved baseline is unavailable" \
  "the reused worktree did not preserve missingness after its key appeared"
pass "a reused worktree with prior period spend refuses an unsafe zero baseline"

# A prior owner that starts before midnight still contaminates the report
# period when its lifecycle ends after midnight.
fm_write_meta "$HOME_DIR/state/cross-day-owner.meta" \
  "worktree=$CROSS_WORKTREE" \
  "project=/srv/projects/fresh" \
  "harness=codex" \
  "kind=ship" \
  "spawned_at=2026-07-19T23:50:00Z" \
  "teardown_at=2026-07-20T00:10:00Z"
fm_write_meta "$HOME_DIR/state/cross-day-next.meta" \
  "worktree=$CROSS_WORKTREE" \
  "project=/srv/projects/fresh" \
  "harness=codex" \
  "kind=ship" \
  "worktree_allocation=first-owner" \
  "spawned_at=2026-07-20T10:30:00Z"
FM_HOME="$HOME_DIR" "$ALLOCATION" acquire cross-day-next "$CROSS_WORKTREE" 2026-07-20T10:30:00Z fresh >/dev/null \
  || fail "cross-day allocation provenance failed"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/cross-day-before-key.json"
write_fixture "$FM_CODEBURN_FIXTURE" 3.25 7 4 7 11
node - "$FM_CODEBURN_FIXTURE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'))
fixture.projects = fixture.projects.filter(project => project.name === 'another-opaque-codeburn-key')
fs.writeFileSync(file, `${JSON.stringify(fixture)}\n`)
NODE
if FM_HOME="$HOME_DIR" "$USAGE" cross-day-next --baseline >/dev/null 2>"$TMP_ROOT/cross-day.err"; then
  fail "a cross-midnight prior owner accepted an unsafe zero baseline"
fi
assert_contains "$(cat "$TMP_ROOT/cross-day.err")" "overlapping the report period" \
  "the cross-midnight ownership refusal did not identify lifecycle overlap"
pass "cross-midnight lifecycle overlap refuses an unsafe zero baseline"

fm_write_meta "$HOME_DIR/state/task-zero.meta" \
  "worktree=$POOLED_WORKTREE" \
  "harness=codex" \
  "model=configured-model" \
  "kind=ship" \
  "spawned_at=2026-07-19T14:34:56Z"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/baseline-zero.json"
write_fixture "$FM_CODEBURN_FIXTURE" 3.25 7 4 7 11
FM_HOME="$HOME_DIR" "$USAGE" task-zero --baseline
zero_usage=$(FM_HOME="$HOME_DIR" "$USAGE" task-zero --json)
node -e '
const u=JSON.parse(process.argv[1])
if (u.cost_usd !== 0 || u.calls !== 0 || u.sessions !== 0) process.exit(1)
if (Object.values(u.tokens).some(value => value !== 0) || u.models.length !== 0) process.exit(1)
' "$zero_usage" || fail "legitimate exact-zero deltas were rejected: $zero_usage"
pass "explicit equal counters preserve legitimate exact-zero deltas"

for invalid_counter in missing nonnumeric decreasing; do
  task="invalid-$invalid_counter"
  fm_write_meta "$HOME_DIR/state/$task.meta" \
    "worktree=$POOLED_WORKTREE" \
    "harness=codex" \
    "kind=ship" \
    "spawned_at=2026-07-19T15:34:56Z"
  export FM_CODEBURN_FIXTURE="$TMP_ROOT/$task-baseline.json"
  write_fixture "$FM_CODEBURN_FIXTURE" 1.25 2 1 5 8
  FM_HOME="$HOME_DIR" "$USAGE" "$task" --baseline
  export FM_CODEBURN_FIXTURE="$TMP_ROOT/$task-current.json"
  write_fixture "$FM_CODEBURN_FIXTURE" 2.75 5 3 7 11
  node - "$FM_CODEBURN_FIXTURE" "$invalid_counter" <<'NODE'
const fs = require('fs')
const [file, kind] = process.argv.slice(2)
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'))
const report = fixture.projects[0].report
if (kind === 'missing') delete report.models[0].inputTokens
if (kind === 'nonnumeric') report.projects[0].calls = '5'
if (kind === 'decreasing') report.projects[0].sessions = 0
fs.writeFileSync(file, `${JSON.stringify(fixture)}\n`)
NODE
  FM_HOME="$HOME_DIR" "$USAGE" "$task" --snapshot >"$TMP_ROOT/$task.out" 2>"$TMP_ROOT/$task.err"
  rc=$?
  [ "$rc" -ne 0 ] || fail "$invalid_counter counter produced a usage snapshot"
  [ ! -e "$HOME_DIR/data/$task/usage.json" ] \
    || fail "$invalid_counter counter persisted plausible-zero attribution"
done
pass "missing, nonnumeric, and decreasing counters leave usage unavailable"

fm_write_meta "$HOME_DIR/state/duplicate-model.meta" \
  "worktree=$POOLED_WORKTREE" \
  "harness=codex" \
  "kind=ship" \
  "spawned_at=2026-07-19T16:34:56Z"
export FM_CODEBURN_FIXTURE="$TMP_ROOT/duplicate-model-baseline.json"
write_fixture "$FM_CODEBURN_FIXTURE" 1.25 2 1 5 8
node - "$FM_CODEBURN_FIXTURE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'))
fixture.projects[0].report.models[0].provider = 'openai'
fs.writeFileSync(file, `${JSON.stringify(fixture)}\n`)
NODE
FM_HOME="$HOME_DIR" "$USAGE" duplicate-model --baseline
export FM_CODEBURN_FIXTURE="$TMP_ROOT/duplicate-model-current.json"
write_fixture "$FM_CODEBURN_FIXTURE" 2.75 5 3 7 11
node - "$FM_CODEBURN_FIXTURE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const fixture = JSON.parse(fs.readFileSync(file, 'utf8'))
const model = fixture.projects[0].report.models[0]
model.provider = 'openai'
fixture.projects[0].report.models.push({...model, name: ` ${model.name} `, provider: ' openai '})
fs.writeFileSync(file, `${JSON.stringify(fixture)}\n`)
NODE
FM_HOME="$HOME_DIR" "$USAGE" duplicate-model --snapshot >"$TMP_ROOT/duplicate-model.out" 2>"$TMP_ROOT/duplicate-model.err"
rc=$?
[ "$rc" -ne 0 ] || fail "duplicate current models produced a usage snapshot"
[ ! -e "$HOME_DIR/data/duplicate-model/usage.json" ] \
  || fail "duplicate current models persisted ambiguous attribution"
pass "normalization-equivalent current model identities leave usage unavailable"

fm_write_meta "$HOME_DIR/state/missing-project.meta" \
  "worktree=$HOME_DIR/unreported-worktree" \
  "harness=codex" \
  "kind=ship" \
  "spawned_at=2026-07-19T12:34:56Z"
FM_HOME="$HOME_DIR" "$USAGE" missing-project --json >"$TMP_ROOT/missing.out" 2>"$TMP_ROOT/missing.err"
rc=$?
[ "$rc" -ne 0 ] || fail "usage query should fail when codeburn reports no matching project"
assert_contains "$(cat "$TMP_ROOT/missing.err")" "no codeburn project matches worktree" \
  "an unmatched project must be reported as an attribution error, not as zero usage"
[ ! -s "$TMP_ROOT/missing.out" ] || fail "an unmatched project must not emit a plausible zero summary"
pass "project discovery fails loudly instead of turning an unmatched filter into zero"

fm_write_meta "$HOME_DIR/state/ineffective-filter.meta" \
  "worktree=$POOLED_WORKTREE" \
  "harness=codex" \
  "kind=ship" \
  "spawned_at=2026-07-19T12:34:56Z"
cat > "$TMP_ROOT/ineffective-filter.json" <<JSON
{"projects":[{"name":"opaque-key-reported-by-codeburn","path":"$pooled_reported_path","filter_miss":true}]}
JSON
export FM_CODEBURN_FIXTURE="$TMP_ROOT/ineffective-filter.json"
FM_HOME="$HOME_DIR" "$USAGE" ineffective-filter --json >"$TMP_ROOT/ineffective.out" 2>"$TMP_ROOT/ineffective.err"
rc=$?
[ "$rc" -ne 0 ] || fail "usage query should fail when codeburn ignores a discovered project key"
assert_contains "$(cat "$TMP_ROOT/ineffective.err")" "project filter matched nothing" \
  "a valid-looking zero report from an ineffective filter must be rejected"
[ ! -s "$TMP_ROOT/ineffective.out" ] || fail "an ineffective filter must not emit a plausible zero summary"
pass "an ineffective codeburn project filter fails loudly instead of reporting zero"

mkdir -p "$HOME_DIR/data/legacy"
cat > "$HOME_DIR/data/legacy/usage.json" <<'JSON'
{"schema":"fm-task-usage.v1","id":"legacy","harness":"codex","actual_models":[],"tokens":{"input":1,"output":2,"cache_read":3,"cache_write":4},"cost_usd":0.01,"calls":1,"spawned_at":null,"captured_at":"2026-07-01T00:00:00Z","correlation":{"worktree":"/old","baseline":false}}
JSON
legacy=$(FM_HOME="$HOME_DIR" "$USAGE" legacy --json)
node -e 'const u=JSON.parse(process.argv[1]); if (u.schema !== "fm-task-usage.v1" || u.tokens.input !== 1) process.exit(1)' "$legacy" \
  || fail "v1 snapshots must remain readable after the v2 schema ships"
pass "historical v1 snapshots remain readable"

cat > "$FAKEBIN/codeburn" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "$FAKEBIN/codeburn"

fm_write_meta "$HOME_DIR/state/hung-task.meta" \
  "worktree=$OTHER_WORKTREE" \
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
