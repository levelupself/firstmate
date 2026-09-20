#!/usr/bin/env bash
# Behavior tests for bin/fm-effort-store.sh - the derived agentic-effort store.
#
# Every assertion goes through the CLI and a read-only query of the resulting
# database, never through the ingestion source itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STORE="$ROOT/bin/fm-effort-store.sh"
ROOTDIR=$(fm_test_tmproot fm-effort-store)
fm_git_identity

export FM_HOME="$ROOTDIR/home"
export FM_EFFORT_STORE_CODEBURN_TIMEOUT=30
mkdir -p "$FM_HOME/data" "$FM_HOME/state"

PROJECT="$ROOTDIR/project"
WT_A="$ROOTDIR/worktrees/a"
WT_B="$ROOTDIR/worktrees/b"
WT_POOLED="$ROOTDIR/worktrees/pooled"
DB="$FM_HOME/data/effort-store.sqlite"

# --- fixture: a project whose second task renames the first task's file ------

fixture_commit() {  # <message> <iso-date>
  GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
    git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$1"
}

mkdir -p "$PROJECT/src"
git -C "$PROJECT" init -q -b main
printf 'export const remember = (x: number) => x + 1\n' > "$PROJECT/src/Memory.ts"
printf 'export const helper = () => 1\n' > "$PROJECT/src/util.ts"
git -C "$PROJECT" add -A
fixture_commit 'introduce memory [901-introduce-memory]' '2026-01-01T00:00:00Z'

mkdir -p "$PROJECT/src/engine"
git -C "$PROJECT" mv src/Memory.ts src/engine/Memory.ts
printf 'export const forget = (x: number) => x - 1\n' >> "$PROJECT/src/engine/Memory.ts"
printf "import { remember } from './engine/Memory'\nexport const use = () => remember(1)\n" > "$PROJECT/src/consumer.ts"
git -C "$PROJECT" add -A
fixture_commit 'rename and extend memory [902-extend-memory]' '2026-02-01T00:00:00Z'

printf 'export const durable = true\n' >> "$PROJECT/src/engine/Memory.ts"
git -C "$PROJECT" add -A
fixture_commit 'modify memory again [905-modify-memory]' '2026-03-01T00:00:00Z'

printf '\000\001\002\003' > "$PROJECT/src/image.bin"
git -C "$PROJECT" add -A
fixture_commit 'add binary fixture [906-add-binary]' '2026-03-02T00:00:00Z'

printf 'export const prefix = true\n' > "$PROJECT/src/prefix.ts"
git -C "$PROJECT" add -A
fixture_commit 'add prefix task [907-prefix]' '2026-03-03T00:00:00Z'
PREFIX_COMMIT=$(git -C "$PROJECT" rev-parse HEAD)

printf 'export const longer = true\n' > "$PROJECT/src/longer.ts"
printf 'export const longerHelper = true\n' > "$PROJECT/src/longer-helper.ts"
git -C "$PROJECT" add -A
fixture_commit 'add longer prefix task [907-prefix-more]' '2026-03-04T00:00:00Z'
LONGER_PREFIX_COMMIT=$(git -C "$PROJECT" rev-parse HEAD)

# --- fixture: the raw teardown capture, with a legacy region above the v2 one -

RAW="$FM_HOME/data/cost-attribution.tsv"
{
  printf 'task\tworktree\tharness\tmodel\teffort\tkind\tproject\tcaptured\n'
  printf 'hand-written-row\t/tmp/legacy\tclaude\tdefault\thigh\tship\t/tmp/legacy\t2026-01-01T00:00:00Z\n'
  printf 'opaque legacy prose that has no declared columns\n'
  printf '# schema=firstmate-effort-attribution-v2\n'
  printf 'task\tworktree\tharness\tmodel\teffort\tkind\tproject\tstarted_at\tended_at\n'
  printf '901-introduce-memory\t%s\tclaude\tdefault\txhigh\tship\t%s\t2026-01-01T00:00:00Z\t2026-01-01T02:00:00Z\n' "$WT_A" "$PROJECT"
  printf '902-extend-memory\t%s\tcodex\tdefault\thigh\tship\t%s\t2026-02-01T00:00:00Z\t2026-02-01T01:00:00Z\n' "$WT_B" "$PROJECT"
  printf '903-unlinked-scout\t%s\tclaude\tfable\tlow\tscout\t%s\t2026-03-01T00:00:00Z\t2026-03-01T00:30:00Z\n' "$WT_POOLED" "$PROJECT"
  printf '904-later-occupant\t%s\tclaude\tfable\tlow\tscout\t%s\t2026-04-01T00:00:00Z\t2026-04-01T00:30:00Z\n' "$WT_POOLED" "$PROJECT"
  printf '905-modify-memory\t%s\tcodex\tdefault\thigh\tship\t%s\t2026-03-01T00:00:00Z\t2026-03-01T01:00:00Z\n' "$WT_B" "$PROJECT"
  printf '906-add-binary\t%s\tcodex\tdefault\thigh\tship\t%s\t2026-03-02T00:00:00Z\t2026-03-02T01:00:00Z\n' "$WT_B" "$PROJECT"
  printf '907-prefix\t%s\tcodex\tdefault\thigh\tship\t%s\t2026-03-03T00:00:00Z\t2026-03-03T01:00:00Z\n' "$WT_B" "$PROJECT"
  printf '907-prefix-more\t%s\tcodex\tdefault\thigh\tship\t%s\t2026-03-04T00:00:00Z\t2026-03-04T01:00:00Z\n' "$WT_B" "$PROJECT"
} > "$RAW"

# --- fixture: codeburn ------------------------------------------------------
#
# Worktree A is spent inside and outside 901's window; the pooled worktree
# carries spend only inside 904's window, so 903 must come back with a real zero
# rather than 904's tokens.

FAKEBIN=$(fm_fakebin "$ROOTDIR")
cat > "$FAKEBIN/codeburn" <<EOF
#!/usr/bin/env bash
touch "$ROOTDIR/codeburn-called"
out=
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac
done
cat > "\$out" <<'JSON'
{"schema":"codeburn.export.v2","records":[
 {"project":"$WT_A","sessionId":"s1","timestamp":"2026-01-01T00:30:00.000Z","provider":"claude","model":"claude-opus-5","inputTokens":100,"outputTokens":20,"reasoningTokens":5,"cacheWriteTokens":7,"cacheReadTokens":900,"cost":0.5},
 {"project":"$WT_A","sessionId":"s1","timestamp":"2026-01-01T00:31:00.000Z","provider":"claude","model":"claude-opus-5","inputTokens":10,"outputTokens":2,"reasoningTokens":0,"cacheWriteTokens":1,"cacheReadTokens":90,"cost":0.25},
 {"project":"$WT_A","sessionId":"s9","timestamp":"2026-05-05T00:00:00.000Z","provider":"claude","model":"claude-opus-5","inputTokens":9999,"outputTokens":9999,"reasoningTokens":0,"cacheWriteTokens":0,"cacheReadTokens":0,"cost":99},
 {"project":"$WT_B","sessionId":"s2","timestamp":"2026-02-01T00:10:00.000Z","provider":"openai","model":"gpt-x","inputTokens":7,"outputTokens":3,"reasoningTokens":0,"cacheWriteTokens":0,"cacheReadTokens":0,"cost":0.01},
 {"project":"$WT_POOLED","sessionId":"s4","timestamp":"2026-04-01T00:10:00.000Z","provider":"claude","model":"claude-opus-5","inputTokens":42,"outputTokens":8,"reasoningTokens":0,"cacheWriteTokens":0,"cacheReadTokens":0,"cost":0.02}
]}
JSON
EOF
chmod +x "$FAKEBIN/codeburn"
export FM_CODEBURN_BIN="$FAKEBIN/codeburn"

# Durable task-usage snapshots are the cost source. Rebuilds must not consult
# mutable account-wide codeburn history after teardown.
write_usage() { # <task> <input> <output> <cost> <calls> <actual-model> [spawned-at]
  local task=$1 input=$2 output=$3 cost=$4 calls=$5 actual_model=$6 spawned_at=${7:-2026-01-01T00:00:00Z}
  mkdir -p "$FM_HOME/data/$task"
  cat > "$FM_HOME/data/$task/usage.json" <<JSON
{"schema":"fm-task-usage.v2","id":"$task","harness":"codex","configured_model":"default","actual_models":["$actual_model"],"models":[{"name":"$actual_model","calls":$calls,"input_tokens":$input,"output_tokens":$output,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":$cost}],"tokens":{"input":$input,"output":$output,"cache_read":0,"cache_write":0},"cost_usd":$cost,"calls":$calls,"sessions":1,"spawned_at":"$spawned_at","captured_at":"2026-01-01T02:00:00Z","correlation":{"baseline":true}}
JSON
}
write_usage 901-introduce-memory 110 22 0.75 2 claude-opus-5
write_usage 902-extend-memory 7 3 0.01 1 gpt-x 2026-02-01T00:00:00Z
write_usage 903-unlinked-scout 0 0 0 0 none 2026-03-01T00:00:00Z
write_usage 904-later-occupant 42 8 0.02 1 claude-opus-5 2026-04-01T00:00:00Z
mkdir -p "$FM_HOME/data/900-broken-cycle"
cat > "$FM_HOME/data/900-broken-cycle/usage.json" <<'JSON'
{"schema":"fm-task-usage.v1","id":"900-broken-cycle","harness":"codex","configured_model":"default","actual_models":[],"models":[],"tokens":{"input":0,"output":0,"cache_read":0,"cache_write":0},"cost_usd":0,"calls":0,"spawned_at":"2026-08-10T00:00:00Z","captured_at":"2026-08-10T01:00:00Z"}
JSON
mkdir -p "$FM_HOME/data/899-pretracking-task"
printf '%s\n' '{"generated":"2026-01-01T00:00:00.000Z","overview":{"cost":0}}' \
  > "$FM_HOME/data/899-pretracking-task/usage-baseline.json"

# --- query helper -----------------------------------------------------------
#
# Reads the store through SQL only, so no test can pass by inspecting the
# ingestion source instead of the ingested result.

QUERY="$ROOTDIR/query.mjs"
cat > "$QUERY" <<'EOF'
process.emitWarning = () => {}
const {DatabaseSync} = await import('node:sqlite')
const db = new DatabaseSync(process.argv[2], {readOnly: true})
const rows = db.prepare(process.argv[3]).all()
process.stdout.write(rows.map(row =>
  Object.values(row).map(value => (value === null ? 'NULL' : String(value))).join('|')
).join('\n') + '\n')
EOF

query() {  # <sql>
  "$STORE" report --sync >/dev/null || fail "pending ingestion failed"
  node "$QUERY" "$DB" "$1"
}

# --- annotations ------------------------------------------------------------

"$STORE" annotate 901-introduce-memory \
  --failure-mode quietly \
  --round 1:discovery \
  --round '2:churn:the acceptance list changed' \
  --title 'Introduce memory' >/dev/null \
  || fail 'annotate should record a task'
"$STORE" annotate 902-extend-memory --failure-mode loudly --round 1:discovery >/dev/null \
  || fail 'annotate should record a second task'
ANNOTATION_SIZE=$(wc -c < "$FM_HOME/data/effort-annotations.jsonl")
for lifecycle_option in --outcome --merged-at --pr-opened-at; do
  if "$STORE" annotate 902-extend-memory "$lifecycle_option" merged >/dev/null 2>&1; then
    fail "annotate accepted lifecycle-owned option $lifecycle_option"
  fi
done
[ "$(wc -c < "$FM_HOME/data/effort-annotations.jsonl")" -eq "$ANNOTATION_SIZE" ] \
  || fail 'rejected lifecycle annotation options changed the durable annotation record'
pass 'manual annotations reject lifecycle-owned outcome and timestamp fields'
for process_option in --findings --review-rounds --ask-user --gate-failures; do
  if "$STORE" annotate 902-extend-memory "$process_option" 1 >/dev/null 2>&1; then
    fail "annotate accepted pipeline-owned option $process_option"
  fi
done
pass 'manual annotations reject pipeline-owned process fields'
printf '%s\n' '{"task":"905-modify-memory","pr_opened_at":"2026-03-01T00:30:00Z","findings":9,"review_rounds":8,"ask_user_count":7,"gate_failures":6}' \
  >> "$FM_HOME/data/effort-annotations.jsonl"

# --- rebuild ----------------------------------------------------------------

REBUILD_OUT=$("$STORE" rebuild 2>&1) || fail "rebuild failed: $REBUILD_OUT"
assert_contains "$REBUILD_OUT" 'rebuilt 11 tasks' 'rebuild should report every task it discovered'
assert_present "$DB" 'rebuild should create the store'
pass 'rebuild builds the store from raw lifecycle capture, durable task usage, and git'

UNPROVEN_MERGE=$(query "SELECT merged_at FROM task WHERE task_id = '901-introduce-memory'")
[ "$UNPROVEN_MERGE" = 'NULL' ] \
  || fail "git history invented an unsanctioned merge timestamp: $UNPROVEN_MERGE"
pass 'merge timestamp remains missing without lifecycle proof'
MANUAL_PR_OPEN=$(query "SELECT pr_opened_at FROM task WHERE task_id = '905-modify-memory'")
[ "$MANUAL_PR_OPEN" = 'NULL' ] \
  || fail "manual annotation populated PR-open lifecycle time: $MANUAL_PR_OPEN"
pass 'PR-open timestamp remains missing without forge lifecycle proof'
MANUAL_PROCESS=$(query "SELECT findings, review_rounds, ask_user_count, gate_failures FROM task WHERE task_id = '905-modify-memory'")
[ "$MANUAL_PROCESS" = 'NULL|NULL|NULL|NULL' ] \
  || fail "manual annotation populated pipeline-owned process cost: $MANUAL_PROCESS"
pass 'pipeline process cost remains missing without a structured run record'

# Rebuild consumed the durable snapshots and never queried account-wide logs.
[ ! -e "$ROOTDIR/codeburn-called" ] || fail 'rebuild unexpectedly queried mutable codeburn history'

# --- the join ---------------------------------------------------------------

ROW=$(query "SELECT harness, effort, kind, files_changed, prod_src_files, distinct_areas, tokens_in, notional_cost_usd, wall_clock_seconds FROM task WHERE task_id = '901-introduce-memory'")
[ "$ROW" = 'claude|xhigh|ship|2|2|1|110|0.75|7200' ] \
  || fail "the three sources should join on one task row, got: $ROW"
pass 'ingestion joins raw dispatch, git structure, and durable codeburn effort on one task'

PREFIX_LINKS=$(query "SELECT task_id, sha FROM task_commit WHERE task_id IN ('907-prefix','907-prefix-more') ORDER BY task_id, sha")
[ "$PREFIX_LINKS" = "907-prefix|$PREFIX_COMMIT
907-prefix-more|$LONGER_PREFIX_COMMIT" ] \
  || fail "prefix-related task identifiers must not claim each other's commits, got: $PREFIX_LINKS"
PREFIX_STRUCTURE=$(query "SELECT task_id, files_changed FROM task WHERE task_id IN ('907-prefix','907-prefix-more') ORDER BY task_id")
[ "$PREFIX_STRUCTURE" = '907-prefix|1
907-prefix-more|2' ] \
  || fail "prefix-related task identifiers must not inflate each other's structure, got: $PREFIX_STRUCTURE"
pass 'commit linking keeps prefix-related task identifiers isolated'

# Spend outside the task's own window belongs to whoever held the worktree then.
POOLED=$(query "SELECT task_id, tokens_in, api_calls FROM task WHERE task_id IN ('903-unlinked-scout','904-later-occupant') ORDER BY task_id")
[ "$POOLED" = '903-unlinked-scout|0|0
904-later-occupant|42|1' ] \
  || fail "a pooled worktree should attribute spend by window, got: $POOLED"
pass 'task-bounded usage snapshots keep pooled-worktree occupants distinct'

ACTUAL_MODEL=$(query "SELECT model, tokens_in, notional_cost_usd FROM task_model WHERE task_id = '901-introduce-memory'")
[ "$ACTUAL_MODEL" = 'claude-opus-5|110|0.75' ] \
  || fail "the actual model should come from the durable usage snapshot, got: $ACTUAL_MODEL"
pass 'actual model, tokens, and cost come from the durable task snapshot'

# --- missing is not zero ----------------------------------------------------

SOURCES=$(query "SELECT source, status FROM task_source WHERE task_id = '903-unlinked-scout' ORDER BY source")
assert_contains "$SOURCES" 'codeburn|present' 'a consulted codeburn with no spend in window is present'
assert_contains "$SOURCES" 'git|missing' 'a task with no resolvable commits records git as missing'
assert_contains "$SOURCES" 'annotation|missing' 'a task never annotated records the annotation source as missing'
assert_contains "$SOURCES" 'raw|present' 'a task with a teardown row records the raw source as present'

NULLED=$(query "SELECT files_changed, adds, import_in_degree FROM task WHERE task_id = '903-unlinked-scout'")
[ "$NULLED" = 'NULL|NULL|NULL' ] \
  || fail "a missing source must leave its columns NULL, got: $NULLED"
ZEROED=$(query "SELECT tokens_in, tokens_out, api_calls FROM task WHERE task_id = '903-unlinked-scout'")
[ "$ZEROED" = '0|0|0' ] \
  || fail "a present source that found nothing must record real zeros, got: $ZEROED"
pass 'an absent source records NULL and missing; a present source that found nothing records zero'

BROKEN_USAGE=$(query "SELECT tokens_in, tokens_out, notional_cost_usd FROM task WHERE task_id = '905-modify-memory'")
[ "$BROKEN_USAGE" = 'NULL|NULL|NULL' ] \
  || fail "a historical task without a durable usage snapshot must be missing, got: $BROKEN_USAGE"
[ "$(query "SELECT status FROM task_source WHERE task_id = '905-modify-memory' AND source = 'codeburn'")" = missing ] \
  || fail 'a historical task without a usage snapshot did not record the source as missing'
pass 'tasks that ran during broken attribution are visibly missing rather than silently zero'

BROKEN_CYCLE=$(query "SELECT tokens_in, tokens_out, notional_cost_usd FROM task WHERE task_id = '900-broken-cycle'")
[ "$BROKEN_CYCLE" = 'NULL|NULL|NULL' ] \
  || fail "a discovered legacy zero snapshot must not become a real zero, got: $BROKEN_CYCLE"
[ "$(query "SELECT status FROM task_source WHERE task_id = '900-broken-cycle' AND source = 'raw'")" = missing ] \
  || fail 'a task discovered only from a usage artifact did not show its missing lifecycle row'
pass 'legacy broken-attribution snapshots are discovered but their zero totals remain missing'

PRETRACKING=$(query "SELECT task_id, findings, review_rounds, ask_user_count, gate_failures FROM task WHERE task_id = '899-pretracking-task'")
[ "$PRETRACKING" = '899-pretracking-task|NULL|NULL|NULL|NULL' ] \
  || fail "a pre-tracking task was absent or acquired invented process values: $PRETRACKING"
PRETRACKING_ISSUE=$(query "SELECT kind FROM ingest_issue WHERE task_id = '899-pretracking-task'")
[ "$PRETRACKING_ISSUE" = 'usage-pre-deterministic-attribution' ] \
  || fail "a pre-tracking task did not retain its honest missingness reason: $PRETRACKING_ISSUE"
pass 'a baseline-only pre-tracking task remains visible with NULL values and a stamped reason'

# --- nothing is silently dropped -------------------------------------------

LEGACY=$(query "SELECT kind, detail FROM ingest_issue WHERE source = 'raw' ORDER BY ordinal")
assert_contains "$LEGACY" 'legacy-column-count' 'malformed rows under the legacy header must state why they are unparseable'
assert_contains "$LEGACY" 'opaque legacy prose' 'the genuinely unstructured legacy line must remain classified'
LEGACY_ROW=$(query "SELECT worktree, harness, model, effort, kind, project_path, started_at FROM task WHERE task_id = 'hand-written-row'")
[ "$LEGACY_ROW" = '/tmp/legacy|claude|NULL|high|ship|/tmp/legacy|NULL' ] \
  || fail "the declared legacy columns were not ingested without inventing lifecycle time: $LEGACY_ROW"
if printf '%s\n' "$LEGACY" | grep -F 'hand-written-row' >/dev/null; then
  fail 'a row under the recognized legacy header remained an ingest issue'
fi
pass 'declared legacy rows are parsed while genuinely unstructured lines retain a stated issue'

# --- the two fields that are not automatic ----------------------------------

ROUNDS=$(query "SELECT task_id, round_index, reason, note FROM round_reason ORDER BY task_id, round_index")
[ "$ROUNDS" = '901-introduce-memory|1|discovery|NULL
901-introduce-memory|2|churn|the acceptance list changed
902-extend-memory|1|discovery|NULL' ] \
  || fail "round reasons must keep discovery and churn distinct, got: $ROUNDS"
pass 'round_reasons records discovery and churn separately, exactly as given'

MODES=$(query "SELECT task_id, failure_mode FROM task WHERE failure_mode IS NOT NULL ORDER BY task_id")
[ "$MODES" = '901-introduce-memory|quietly
902-extend-memory|loudly' ] \
  || fail "the loud/quiet bit must be stored per task, got: $MODES"
UNASKED=$(query "SELECT failure_mode FROM task WHERE task_id = '903-unlinked-scout'")
[ "$UNASKED" = 'NULL' ] || fail 'a task never asked the loud/quiet question must not be given an answer'
pass 'failed_loudly and failed_quietly are recorded per task and never inferred'

BAD=$("$STORE" annotate 905-bad --round '1:mostly-discovery' 2>&1)
expect_code 2 $? 'an unknown round reason must be refused'
assert_contains "$BAD" 'discovery' 'the refusal should name the reasons it accepts'
BAD_MODE=$("$STORE" annotate 905-bad --failure-mode sometimes 2>&1)
expect_code 2 $? 'an unknown failure mode must be refused'
assert_contains "$BAD_MODE" 'quietly' 'the refusal should name the failure modes it accepts'
pass 'annotations are validated rather than coerced into a value nobody gave'

# --- the durability relation ------------------------------------------------

DURABILITY=$(query "SELECT introducing_task_id, modifying_task_id, introduced_path, modified_path FROM durability ORDER BY modifying_task_id")
[ "$DURABILITY" = '901-introduce-memory|902-extend-memory|src/Memory.ts|src/engine/Memory.ts
901-introduce-memory|905-modify-memory|src/Memory.ts|src/engine/Memory.ts' ] \
  || fail "the durability relation should link the later task across the rename, got: $DURABILITY"
pass 'durability skips an intermediate modifier while retaining links to the introducing task across a rename'

# --- unavailable binary diff measurements ----------------------------------

BINARY_FILE=$(query "SELECT adds, dels FROM task_file WHERE task_id = '906-add-binary' AND path = 'src/image.bin'")
[ "$BINARY_FILE" = 'NULL|NULL' ] \
  || fail "binary file measurements should remain unknown, got: $BINARY_FILE"
BINARY_TASK=$(query "SELECT files_changed, prod_src_files, distinct_areas, adds, dels FROM task WHERE task_id = '906-add-binary'")
[ "$BINARY_TASK" = '1|0|1|NULL|NULL' ] \
  || fail "task totals containing binary measurements should remain unknown, got: $BINARY_TASK"
pass 'binary diff measurements remain NULL at file and task levels while known counts remain real'

# --- rebuild identity -------------------------------------------------------

FIRST=$("$STORE" fingerprint) || fail 'fingerprint should read the store'
rm -f "$DB"
"$STORE" rebuild >/dev/null || fail 'rebuild after deletion failed'
SECOND=$("$STORE" fingerprint) || fail 'fingerprint should read the rebuilt store'
[ -n "$FIRST" ] || fail 'fingerprint should not be empty'
[ "$FIRST" = "$SECOND" ] \
  || fail "deleting and rebuilding the store must reproduce it exactly: $FIRST vs $SECOND"
pass 'the store is fully rebuildable: deleting it and rebuilding reproduces identical content'

# The recorded-by-hand fields must survive the rebuild, which is why they live
# outside the database.
AFTER=$(query "SELECT failure_mode FROM task WHERE task_id = '901-introduce-memory'")
[ "$AFTER" = 'quietly' ] || fail 'a recorded-by-hand field must survive deleting the store'
pass 'recorded-by-hand fields survive a delete and rebuild'

# --- lifecycle capture and one-command reporting ---------------------------

fm_write_meta "$FM_HOME/state/910-lifecycle.meta" \
  "worktree=$ROOTDIR/worktrees/lifecycle" \
  "project=$PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawned_at=2026-06-01T10:00:00Z" \
  "pr=https://github.com/example/repo/pull/10" \
  "pr_opened_at=2026-06-01T10:15:00Z" \
  "merged_at=2026-06-01T11:00:00Z" \
  "teardown_at=2026-06-01T11:05:00Z" \
  "outcome=pr-merged"
write_usage 910-lifecycle 321 45 1.25 6 gpt-5.6-sol 2026-06-01T10:00:00Z

rm -f "$DB"
CAPTURE_OUT=$("$STORE" capture 910-lifecycle --outcome pr-merged 2>&1) \
  || fail "lifecycle capture failed: $CAPTURE_OUT"
"$STORE" report --sync >/dev/null || fail "lifecycle ingestion failed"
assert_present "$DB" 'a lifecycle capture should create the store automatically'
LIFECYCLE=$(query "SELECT launch_to_pr_seconds, tokens_in, tokens_out, notional_cost_usd, pr_opened_at, merged_at, teardown_at, outcome FROM task WHERE task_id = '910-lifecycle'")
[ "$LIFECYCLE" = '900|321|45|1.25|2026-06-01T10:15:00Z|2026-06-01T11:00:00Z|2026-06-01T11:05:00Z|merged' ] \
  || fail "captured lifecycle fields were incomplete: $LIFECYCLE"
pass 'lifecycle capture creates and populates the store without a remembered rebuild'

fm_write_meta "$FM_HOME/state/914-reversed-pr.meta" \
  "worktree=$ROOTDIR/worktrees/reversed-pr" \
  "project=$PROJECT" \
  "kind=ship" \
  "spawned_at=2026-06-05T10:00:00Z" \
  "pr_opened_at=2026-06-05T09:59:59Z"
"$STORE" capture 914-reversed-pr >/dev/null || fail 'reversed PR capture failed'
REVERSED_PR=$(query "SELECT launch_to_pr_seconds FROM task WHERE task_id = '914-reversed-pr'")
[ "$REVERSED_PR" = 'NULL' ] || fail "reversed launch-to-PR was not missing: $REVERSED_PR"
pass 'PR timestamps before launch produce a missing duration'

fm_write_meta "$FM_HOME/state/916-invalid-launch.meta" \
  "worktree=$ROOTDIR/worktrees/invalid-launch" \
  "project=$PROJECT" \
  "kind=ship" \
  "spawned_at=2026-02-30T10:00:00Z" \
  "pr_opened_at=2026-03-02T11:00:00Z" \
  "teardown_at=2026-03-02T12:00:00Z" \
  "outcome=forced"
write_usage 916-invalid-launch 12 3 0.25 2 forged-model 2026-02-30T10:00:00Z
"$STORE" capture 916-invalid-launch >/dev/null || fail 'invalid launch capture failed'
INVALID_LAUNCH=$(query "SELECT started_at, pr_opened_at, launch_to_pr_seconds, teardown_at, outcome, model, tokens_in, tokens_out, notional_cost_usd, api_calls, sessions, (SELECT group_concat(model) FROM task_model WHERE task_id = '916-invalid-launch') FROM task WHERE task_id = '916-invalid-launch'")
[ "$INVALID_LAUNCH" = 'NULL|NULL|NULL|NULL|NULL|NULL|NULL|NULL|NULL|NULL|NULL|NULL' ] \
  || fail "an impossible launch authorized lifecycle fields: $INVALID_LAUNCH"
pass 'impossible launch timestamps invalidate lifecycle and usage attribution'

fm_write_meta "$FM_HOME/state/917-invalid-lifecycle.meta" \
  "worktree=$ROOTDIR/worktrees/invalid-lifecycle" \
  "project=$PROJECT" \
  "kind=ship" \
  "spawned_at=2026-02-01T10:00:00Z" \
  "pr_opened_at=2026-02-30T11:00:00Z" \
  "teardown_at=2026-02-30T12:00:00Z" \
  "outcome=forced"
"$STORE" capture 917-invalid-lifecycle >/dev/null || fail 'invalid lifecycle capture failed'
INVALID_LIFECYCLE=$(query "SELECT pr_opened_at, launch_to_pr_seconds, ended_at, wall_clock_seconds, teardown_at, outcome FROM task WHERE task_id = '917-invalid-lifecycle'")
[ "$INVALID_LIFECYCLE" = 'NULL|NULL|NULL|NULL|NULL|NULL' ] \
  || fail "impossible lifecycle timestamps were accepted: $INVALID_LIFECYCLE"
pass 'impossible PR, end, and teardown timestamps remain missing'

fm_write_meta "$FM_HOME/state/915-unproven-outcome.meta" \
  "worktree=$ROOTDIR/worktrees/unproven-outcome" \
  "project=$PROJECT" \
  "kind=ship" \
  "spawned_at=2026-06-05T10:00:00Z" \
  "teardown_at=2026-06-05T11:00:00Z" \
  "outcome=pr-merged"
if "$STORE" capture 915-unproven-outcome --outcome invented >/dev/null 2>&1; then
  fail 'capture accepted an arbitrary lifecycle outcome'
fi
"$STORE" capture 915-unproven-outcome >/dev/null || fail 'unproven outcome capture failed'
UNPROVEN_OUTCOME=$(query "SELECT merged_at, outcome FROM task WHERE task_id = '915-unproven-outcome'")
[ "$UNPROVEN_OUTCOME" = 'NULL|NULL' ] || fail "an outcome without lifecycle proof was accepted: $UNPROVEN_OUTCOME"
pass 'arbitrary and unproven landing outcomes remain missing'

sed -i 's/"baseline":true/"baseline":false/' "$FM_HOME/data/910-lifecycle/usage.json"
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'unbounded usage capture failed'
UNBOUNDED_USAGE=$(query "SELECT tokens_in, tokens_out, notional_cost_usd FROM task WHERE task_id = '910-lifecycle'")
[ "$UNBOUNDED_USAGE" = 'NULL|NULL|NULL' ] \
  || fail "usage without a launch baseline was accepted: $UNBOUNDED_USAGE"
grep -q '"baseline":false' "$FM_HOME/data/910-lifecycle/usage.json" \
  || fail 'unbounded usage snapshot was not preserved for diagnostics'
pass 'usage without a valid launch baseline remains missing'
sed -i 's/"baseline":false/"baseline":true/' "$FM_HOME/data/910-lifecycle/usage.json"

sed -i 's/"sessions":1/"sessions":"malformed"/' "$FM_HOME/data/910-lifecycle/usage.json"
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'malformed sessions capture failed'
MALFORMED_SESSIONS=$(query "SELECT tokens_in, tokens_out, notional_cost_usd, api_calls, sessions, (SELECT group_concat(model) FROM task_model WHERE task_id = '910-lifecycle') FROM task WHERE task_id = '910-lifecycle'")
[ "$MALFORMED_SESSIONS" = 'NULL|NULL|NULL|NULL|NULL|NULL' ] \
  || fail "usage with malformed sessions was partially accepted: $MALFORMED_SESSIONS"
pass 'malformed sessions makes the entire usage source missing'
sed -i 's/"sessions":"malformed"/"sessions":1/' "$FM_HOME/data/910-lifecycle/usage.json"

node - "$FM_HOME/data/910-lifecycle/usage.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const usage = JSON.parse(fs.readFileSync(file, 'utf8'))
usage.tokens.input = '321'
fs.writeFileSync(file, `${JSON.stringify(usage)}\n`)
NODE
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'string total capture failed'
STRING_TOTAL=$(query "SELECT tokens_in, tokens_out, notional_cost_usd, api_calls, sessions, (SELECT group_concat(model) FROM task_model WHERE task_id = '910-lifecycle') FROM task WHERE task_id = '910-lifecycle'")
[ "$STRING_TOTAL" = 'NULL|NULL|NULL|NULL|NULL|NULL' ] \
  || fail "usage with a string total was partially accepted: $STRING_TOTAL"
pass 'numeric-looking strings make the entire usage source missing'
write_usage 910-lifecycle 321 45 1.25 6 gpt-5.6-sol 2026-06-01T10:00:00Z

node - "$FM_HOME/data/910-lifecycle/usage.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const usage = JSON.parse(fs.readFileSync(file, 'utf8'))
usage.models[0].calls = true
fs.writeFileSync(file, `${JSON.stringify(usage)}\n`)
NODE
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'boolean model total capture failed'
BOOLEAN_MODEL_TOTAL=$(query "SELECT tokens_in, tokens_out, notional_cost_usd, api_calls, sessions, (SELECT group_concat(model) FROM task_model WHERE task_id = '910-lifecycle') FROM task WHERE task_id = '910-lifecycle'")
[ "$BOOLEAN_MODEL_TOTAL" = 'NULL|NULL|NULL|NULL|NULL|NULL' ] \
  || fail "usage with a boolean model total was partially accepted: $BOOLEAN_MODEL_TOTAL"
pass 'non-numeric model totals make the entire usage source missing'
write_usage 910-lifecycle 321 45 1.25 6 gpt-5.6-sol 2026-06-01T10:00:00Z

node - "$FM_HOME/data/910-lifecycle/usage.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const usage = JSON.parse(fs.readFileSync(file, 'utf8'))
usage.models = {}
fs.writeFileSync(file, `${JSON.stringify(usage)}\n`)
NODE
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'malformed model collection capture failed'
MALFORMED_MODELS=$(query "SELECT tokens_in, notional_cost_usd, sessions, (SELECT group_concat(model) FROM task_model WHERE task_id = '910-lifecycle') FROM task WHERE task_id = '910-lifecycle'")
[ "$MALFORMED_MODELS" = 'NULL|NULL|NULL|NULL' ] \
  || fail "usage with a malformed model collection was partially accepted: $MALFORMED_MODELS"
pass 'malformed model collections make the entire usage source missing'
write_usage 910-lifecycle 321 45 1.25 6 gpt-5.6-sol 2026-06-01T10:00:00Z

node - "$FM_HOME/data/910-lifecycle/usage.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const usage = JSON.parse(fs.readFileSync(file, 'utf8'))
usage.actual_models = ['different-model']
fs.writeFileSync(file, `${JSON.stringify(usage)}\n`)
NODE
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'inconsistent model collection capture failed'
INCONSISTENT_MODELS=$(query "SELECT tokens_in, notional_cost_usd, sessions, (SELECT group_concat(model) FROM task_model WHERE task_id = '910-lifecycle') FROM task WHERE task_id = '910-lifecycle'")
[ "$INCONSISTENT_MODELS" = 'NULL|NULL|NULL|NULL' ] \
  || fail "usage with inconsistent model collections was partially accepted: $INCONSISTENT_MODELS"
pass 'inconsistent model collections make the entire usage source missing'
write_usage 910-lifecycle 321 45 1.25 6 gpt-5.6-sol 2026-06-01T10:00:00Z

node - "$FM_HOME/data/910-lifecycle/usage.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const usage = JSON.parse(fs.readFileSync(file, 'utf8'))
usage.models.push({...usage.models[0]})
usage.actual_models.push(usage.actual_models[0])
fs.writeFileSync(file, `${JSON.stringify(usage)}\n`)
NODE
rm -f "$DB"
"$STORE" rebuild >/dev/null || fail 'duplicate durable models aborted delete-and-rebuild'
DUPLICATE_MODELS=$(query "SELECT tokens_in, tokens_out, notional_cost_usd, api_calls, sessions, (SELECT group_concat(model) FROM task_model WHERE task_id = '910-lifecycle') FROM task WHERE task_id = '910-lifecycle'")
[ "$DUPLICATE_MODELS" = 'NULL|NULL|NULL|NULL|NULL|NULL' ] \
  || fail "duplicate durable model identities were ingested: $DUPLICATE_MODELS"
pass 'duplicate durable model identities remain missing without aborting rebuild'
write_usage 910-lifecycle 321 45 1.25 6 gpt-5.6-sol 2026-06-01T10:00:00Z
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'restoring valid usage after duplicate model test failed'

fm_write_meta "$FM_HOME/state/911-receipt-outcome.meta" \
  "worktree=$ROOTDIR/worktrees/receipt-outcome" \
  "project=$PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawned_at=2026-06-02T10:00:00Z" \
  "pr=https://github.com/example/repo/pull/11" \
  "teardown_at=2026-06-02T11:05:00Z"
mkdir -p "$FM_HOME/data/pr-merges"
fm_write_meta "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" \
  "schema=fm-pr-merge.v1" \
  "task_id=911-receipt-outcome" \
  "spawned_at=2026-06-02T10:00:00Z" \
  "phase=merged" \
  "pr=https://github.com/example/repo/pull/11" \
  "authorization=live-meta" \
  "prepared_epoch=1780396200" \
  "merged_epoch=1780398000"
"$STORE" capture 911-receipt-outcome >/dev/null \
  || fail 'receipt-backed lifecycle capture failed'
RECEIPT_OUTCOME=$(query "SELECT merged_at IS NOT NULL, outcome FROM task WHERE task_id = '911-receipt-outcome'")
[ "$RECEIPT_OUTCOME" = '1|merged' ] \
  || fail "a durable sanctioned merge receipt did not supply merge lifecycle proof: $RECEIPT_OUTCOME"
pass 'durable merge receipt supplies missing merge lifecycle proof'

fm_write_meta "$FM_HOME/state/918-forge-time-missing.meta" \
  "worktree=$ROOTDIR/worktrees/forge-time-missing" \
  "project=$PROJECT" \
  "harness=codex" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawned_at=2026-06-06T10:00:00Z" \
  "pr=https://github.com/example/repo/pull/18" \
  "outcome=pr-merged"
fm_write_meta "$FM_HOME/data/pr-merges/918-forge-time-missing.receipt" \
  "schema=fm-pr-merge.v2" \
  "task_id=918-forge-time-missing" \
  "spawned_at=2026-06-06T10:00:00Z" \
  "phase=merged" \
  "pr=https://github.com/example/repo/pull/18" \
  "authorization=live-meta" \
  "prepared_epoch=1780743600" \
  "merged_at="
"$STORE" capture 918-forge-time-missing --outcome pr-merged >/dev/null \
  || fail 'forge-time-missing lifecycle capture failed'
FORGE_TIME_MISSING=$(query "SELECT merged_at, outcome FROM task WHERE task_id = '918-forge-time-missing'")
[ "$FORGE_TIME_MISSING" = 'NULL|merged' ] \
  || fail "an unavailable forge time was replaced or lost the proven outcome: $FORGE_TIME_MISSING"
pass 'an unavailable forge merge time remains NULL while the sanctioned outcome stays merged'

mv "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" "$FM_HOME/data/pr-merges/911-receipt-outcome.target"
ln -s 911-receipt-outcome.target "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
"$STORE" capture 911-receipt-outcome >/dev/null || fail 'symlinked merge receipt aborted capture'
SYMLINKED_MERGE=$(query "SELECT merged_at, outcome FROM task WHERE task_id = '911-receipt-outcome'")
[ "$SYMLINKED_MERGE" = 'NULL|NULL' ] \
  || fail "symlinked merge receipt proved landing: $SYMLINKED_MERGE"
rm "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
mv "$FM_HOME/data/pr-merges/911-receipt-outcome.target" "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
pass 'symlinked merge receipts remain untrusted'

for duplicate_field in task_id authorization; do
  case "$duplicate_field" in
    task_id) printf '%s\n' 'task_id=911-receipt-outcome' >> "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" ;;
    authorization) printf '%s\n' 'authorization=live-meta' >> "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" ;;
  esac
  "$STORE" capture 911-receipt-outcome >/dev/null || fail "duplicate $duplicate_field merge receipt aborted capture"
  DUPLICATE_RECEIPT=$(query "SELECT merged_at, outcome FROM task WHERE task_id = '911-receipt-outcome'")
  [ "$DUPLICATE_RECEIPT" = 'NULL|NULL' ] \
    || fail "duplicate $duplicate_field merge receipt proved landing: $DUPLICATE_RECEIPT"
  sed -i '$d' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
done
pass 'duplicate merge receipt identity and authorization remain untrusted'

for malformed_contract in missing-authorization invalid-authorization missing-preparation invalid-preparation; do
  case "$malformed_contract" in
    missing-authorization) sed -i '/^authorization=/d' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" ;;
    invalid-authorization) printf '%s\n' 'authorization=manual' >> "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" ;;
    missing-preparation)
      sed -i 's/^authorization=manual$/authorization=live-meta/' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
      sed -i '/^prepared_epoch=/d' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
      ;;
    invalid-preparation) printf '%s\n' 'prepared_epoch=not-an-epoch' >> "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" ;;
  esac
  "$STORE" capture 911-receipt-outcome >/dev/null || fail "$malformed_contract merge receipt aborted capture"
  MALFORMED_CONTRACT=$(query "SELECT merged_at, outcome FROM task WHERE task_id = '911-receipt-outcome'")
  [ "$MALFORMED_CONTRACT" = 'NULL|NULL' ] \
    || fail "$malformed_contract merge receipt proved landing: $MALFORMED_CONTRACT"
done
sed -i 's/^prepared_epoch=not-an-epoch$/prepared_epoch=1780396200/' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
pass 'incomplete or unauthorized merge receipts remain untrusted'

sed -i 's/merged_epoch=1780398000/merged_epoch=9007199254740991/' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
"$STORE" capture 911-receipt-outcome >/dev/null || fail 'out-of-range merge receipt aborted capture'
MALFORMED_MERGE=$(query "SELECT merged_at, outcome FROM task WHERE task_id = '911-receipt-outcome'")
[ "$MALFORMED_MERGE" = 'NULL|NULL' ] || fail "out-of-range merge receipt was accepted: $MALFORMED_MERGE"
pass 'out-of-range merge receipt timestamps remain missing'
sed -i 's/merged_epoch=9007199254740991/merged_epoch=1780398000/' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"

for malformed_epoch in missing empty prelaunch; do
  case "$malformed_epoch" in
    missing) sed -i '/^merged_epoch=/d' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" ;;
    empty) printf '%s\n' 'merged_epoch=' >> "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" ;;
    prelaunch) sed -i 's/^merged_epoch=$/merged_epoch=1780307999/' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt" ;;
  esac
  "$STORE" capture 911-receipt-outcome >/dev/null || fail "$malformed_epoch merge receipt aborted capture"
  MALFORMED_MERGE=$(query "SELECT merged_at, outcome FROM task WHERE task_id = '911-receipt-outcome'")
  [ "$MALFORMED_MERGE" = 'NULL|NULL' ] \
    || fail "$malformed_epoch merge receipt proved landing: $MALFORMED_MERGE"
done
sed -i 's/merged_epoch=1780307999/merged_epoch=1780398000/' "$FM_HOME/data/pr-merges/911-receipt-outcome.receipt"
pass 'absent, empty, and pre-launch merge timestamps remain missing'

fm_write_meta "$FM_HOME/state/912-local-receipt.meta" \
  "worktree=$ROOTDIR/worktrees/local-receipt" \
  "project=$PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "mode=local-only" \
  "spawned_at=2026-06-03T10:00:00Z" \
  "teardown_at=2026-06-03T11:05:00Z"
mkdir -p "$FM_HOME/data/local-landings"
fm_write_meta "$FM_HOME/data/local-landings/912-local-receipt.receipt" \
  "schema=fm-local-landing.v1" \
  "task_id=912-local-receipt" \
  "spawned_at=2026-06-03T10:00:00Z" \
  "project=$PROJECT" \
  "branch=fm/912-local-receipt" \
  "default_branch=main" \
  "before_sha=1111111111111111111111111111111111111111" \
  "landed_sha=2222222222222222222222222222222222222222" \
  "phase=landed" \
  "event_at=2026-06-03T11:00:00Z"
"$STORE" capture 912-local-receipt >/dev/null \
  || fail 'local-receipt lifecycle capture failed'
LOCAL_RECEIPT_OUTCOME=$(query "SELECT local_landed_at, outcome FROM task WHERE task_id = '912-local-receipt'")
[ "$LOCAL_RECEIPT_OUTCOME" = '2026-06-03T11:00:00Z|local-landed' ] \
  || fail "a completed local receipt did not supply lifecycle proof: $LOCAL_RECEIPT_OUTCOME"
pass 'completed local receipt supplies local landing lifecycle proof'

mv "$FM_HOME/data/local-landings/912-local-receipt.receipt" "$FM_HOME/data/local-landings/912-local-receipt.target"
ln -s 912-local-receipt.target "$FM_HOME/data/local-landings/912-local-receipt.receipt"
"$STORE" capture 912-local-receipt >/dev/null || fail 'symlinked local receipt aborted capture'
SYMLINKED_LOCAL=$(query "SELECT local_landed_at, outcome FROM task WHERE task_id = '912-local-receipt'")
[ "$SYMLINKED_LOCAL" = 'NULL|NULL' ] \
  || fail "symlinked local receipt proved landing: $SYMLINKED_LOCAL"
rm "$FM_HOME/data/local-landings/912-local-receipt.receipt"
mv "$FM_HOME/data/local-landings/912-local-receipt.target" "$FM_HOME/data/local-landings/912-local-receipt.receipt"
pass 'symlinked local receipts remain untrusted'

for duplicate_field in task_id event_at; do
  case "$duplicate_field" in
    task_id) printf '%s\n' 'task_id=912-local-receipt' >> "$FM_HOME/data/local-landings/912-local-receipt.receipt" ;;
    event_at) printf '%s\n' 'event_at=2026-06-03T11:00:00Z' >> "$FM_HOME/data/local-landings/912-local-receipt.receipt" ;;
  esac
  "$STORE" capture 912-local-receipt >/dev/null || fail "duplicate $duplicate_field local receipt aborted capture"
  DUPLICATE_LOCAL=$(query "SELECT local_landed_at, outcome FROM task WHERE task_id = '912-local-receipt'")
  [ "$DUPLICATE_LOCAL" = 'NULL|NULL' ] \
    || fail "duplicate $duplicate_field local receipt proved landing: $DUPLICATE_LOCAL"
  sed -i '$d' "$FM_HOME/data/local-landings/912-local-receipt.receipt"
done
pass 'duplicate local receipt identity and event time remain untrusted'

for malformed_event_at in '2026-02-30T11:00:00Z' '2026-06-03T09:59:59Z' ''; do
  sed -i "s/^event_at=.*/event_at=$malformed_event_at/" "$FM_HOME/data/local-landings/912-local-receipt.receipt"
  "$STORE" capture 912-local-receipt >/dev/null || fail 'malformed local receipt aborted capture'
  MALFORMED_LOCAL=$(query "SELECT local_landed_at, outcome FROM task WHERE task_id = '912-local-receipt'")
  [ "$MALFORMED_LOCAL" = 'NULL|NULL' ] \
    || fail "malformed local receipt proved landing: $malformed_event_at: $MALFORMED_LOCAL"
done
sed -i 's/^event_at=$/event_at=2026-06-03T11:00:00Z/' "$FM_HOME/data/local-landings/912-local-receipt.receipt"
pass 'impossible, pre-launch, and empty local timestamps remain missing'

fm_write_meta "$FM_HOME/state/913-prepared-local.meta" \
  "worktree=$ROOTDIR/worktrees/prepared-local" \
  "project=$PROJECT" \
  "harness=codex" \
  "kind=ship" \
  "mode=local-only" \
  "spawned_at=2026-06-04T10:00:00Z" \
  "teardown_at=2026-06-04T11:05:00Z"
fm_write_meta "$FM_HOME/data/local-landings/913-prepared-local.receipt" \
  "schema=fm-local-landing.v1" \
  "task_id=913-prepared-local" \
  "spawned_at=2026-06-04T10:00:00Z" \
  "project=$PROJECT" \
  "branch=fm/913-prepared-local" \
  "default_branch=main" \
  "before_sha=1111111111111111111111111111111111111111" \
  "landed_sha=2222222222222222222222222222222222222222" \
  "phase=prepared" \
  "event_at=2026-06-04T11:00:00Z"
"$STORE" capture 913-prepared-local >/dev/null \
  || fail 'prepared local-receipt lifecycle capture failed'
PREPARED_LOCAL=$(query "SELECT local_landed_at, outcome FROM task WHERE task_id = '913-prepared-local'")
[ "$PREPARED_LOCAL" = 'NULL|NULL' ] \
  || fail "an incomplete local receipt falsely proved landing: $PREPARED_LOCAL"
pass 'prepared local receipt does not prove landing'

fm_write_meta "$FM_HOME/state/911-receipt-outcome.meta" \
  "worktree=$ROOTDIR/worktrees/receipt-outcome" \
  "project=$PROJECT" \
  "harness=codex" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawned_at=2026-07-02T10:00:00Z" \
  "teardown_at=2026-07-02T11:05:00Z"
"$STORE" capture 911-receipt-outcome >/dev/null || fail 'reused PR task capture failed'
REUSED_PR=$(query "SELECT merged_at, outcome FROM task WHERE task_id = '911-receipt-outcome'")
[ "$REUSED_PR" = 'NULL|NULL' ] \
  || fail "a reused task inherited an earlier PR receipt: $REUSED_PR"

fm_write_meta "$FM_HOME/state/912-local-receipt.meta" \
  "worktree=$ROOTDIR/worktrees/local-receipt" \
  "project=$PROJECT" \
  "harness=codex" \
  "kind=ship" \
  "mode=local-only" \
  "spawned_at=2026-07-03T10:00:00Z" \
  "teardown_at=2026-07-03T11:05:00Z"
"$STORE" capture 912-local-receipt >/dev/null || fail 'reused local task capture failed'
REUSED_LOCAL=$(query "SELECT local_landed_at, outcome FROM task WHERE task_id = '912-local-receipt'")
[ "$REUSED_LOCAL" = 'NULL|NULL' ] \
  || fail "a reused task inherited an earlier local receipt: $REUSED_LOCAL"
pass 'reused task IDs cannot inherit prior launch receipts'

fm_write_meta "$FM_HOME/state/902-extend-memory.meta" \
  "worktree=$WT_B" \
  "project=$PROJECT" \
  "harness=codex" \
  "kind=ship" \
  "spawned_at=2026-07-04T10:00:00Z"
"$STORE" capture 902-extend-memory >/dev/null || fail 'reused usage task capture failed'
REUSED_USAGE=$(query "SELECT tokens_in, tokens_out, notional_cost_usd, (SELECT group_concat(model) FROM task_model WHERE task_id = '902-extend-memory') FROM task WHERE task_id = '902-extend-memory'")
[ "$REUSED_USAGE" = 'NULL|NULL|NULL|NULL' ] \
  || fail "a reused task inherited an earlier usage snapshot: $REUSED_USAGE"
pass 'reused task IDs cannot inherit prior usage snapshots'

"$STORE" report --sync >/dev/null || fail "capture sync failed"
CAPTURE_FINGERPRINT=$("$STORE" fingerprint)
CAPTURE_RAW_SIZE=$(wc -c < "$RAW")
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'repeating an identical lifecycle capture failed'
"$STORE" report --sync >/dev/null || fail "capture sync failed"
[ "$("$STORE" fingerprint)" = "$CAPTURE_FINGERPRINT" ] \
  || fail 'an idempotent lifecycle retry changed the logical store'
[ "$(wc -c < "$RAW")" -eq "$CAPTURE_RAW_SIZE" ] \
  || fail 'an idempotent lifecycle retry appended a duplicate raw row'
rm -f "$DB"
"$STORE" rebuild >/dev/null || fail 'durable-record rebuild after lifecycle capture failed'
"$STORE" report --sync >/dev/null || fail "capture sync failed"
[ "$("$STORE" fingerprint)" = "$CAPTURE_FINGERPRINT" ] \
  || fail 'delete-and-rebuild lost lifecycle fields or usage'
pass 'lifecycle capture is idempotent and delete-and-rebuild reproduces it'

# --- bounded historical codeburn recovery ----------------------------------

BACKFILL_A="$ROOTDIR/worktrees/backfill-a"
BACKFILL_B="$ROOTDIR/worktrees/backfill-b"
BACKFILL_C="$ROOTDIR/worktrees/backfill-c"
BACKFILL_D="$ROOTDIR/worktrees/backfill-d"
fm_write_meta "$FM_HOME/state/920-backfill-a.meta" \
  "worktree=$BACKFILL_A" \
  "project=$PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "spawned_at=2026-07-01T10:00:00Z" \
  "teardown_at=2026-07-01T10:30:00Z" \
  "outcome=forced"
"$STORE" capture 920-backfill-a --outcome forced >/dev/null \
  || fail 'first historical backfill lifecycle capture failed'
fm_write_meta "$FM_HOME/state/921-backfill-b.meta" \
  "worktree=$BACKFILL_B" \
  "project=$PROJECT" \
  "harness=claude" \
  "model=configured-opus" \
  "effort=xhigh" \
  "kind=scout" \
  "spawned_at=2026-07-01T10:00:00Z" \
  "teardown_at=2026-07-01T10:45:00Z" \
  "outcome=scout-complete"
"$STORE" capture 921-backfill-b --outcome scout-complete >/dev/null \
  || fail 'second historical backfill lifecycle capture failed'
fm_write_meta "$FM_HOME/state/922-backfill-boundary.meta" \
  "worktree=$BACKFILL_C" \
  "project=$PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "spawned_at=2026-06-30T23:50:00Z" \
  "teardown_at=2026-07-01T10:20:00Z" \
  "outcome=forced"
"$STORE" capture 922-backfill-boundary --outcome forced >/dev/null \
  || fail 'boundary-crossing historical lifecycle capture failed'
fm_write_meta "$FM_HOME/state/923-backfill-exact-boundary.meta" \
  "worktree=$BACKFILL_D" \
  "project=$PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "spawned_at=2026-07-01T23:00:00Z" \
  "teardown_at=2026-07-02T00:00:00Z" \
  "outcome=forced"
"$STORE" capture 923-backfill-exact-boundary --outcome forced >/dev/null \
  || fail 'exact-boundary historical lifecycle capture failed'

BACKFILL_EXPORT="$ROOTDIR/codeburn-backfill.json"
cat > "$BACKFILL_EXPORT" <<JSON
{"schema":"codeburn.export.v2","generated":"2026-07-02T00:00:00.000Z","summary":[{"Period":"2026-07-01 to 2026-07-01","Cost (USD)":19,"API Calls":6}],"records":[
  {"project":"$BACKFILL_A","sessionId":"session-a","timestamp":"2026-07-01T10:05:00.000Z","provider":"openai","model":"gpt-5.6-sol","inputTokens":100,"outputTokens":20,"reasoningTokens":5,"cacheWriteTokens":7,"cacheReadTokens":900,"cost":1.25},
  {"project":"$BACKFILL_B","sessionId":"session-b","timestamp":"2026-07-01T10:10:00.000Z","provider":"claude","model":"claude-opus-5","inputTokens":200,"outputTokens":40,"reasoningTokens":0,"cacheWriteTokens":9,"cacheReadTokens":800,"cost":2.25},
  {"project":"$BACKFILL_A","sessionId":"outside-a","timestamp":"2026-07-01T11:00:00.000Z","provider":"openai","model":"gpt-5.6-sol","inputTokens":300,"outputTokens":60,"reasoningTokens":0,"cacheWriteTokens":0,"cacheReadTokens":700,"cost":4},
  {"project":"$BACKFILL_C","sessionId":"boundary-c","timestamp":"2026-07-01T10:15:00.000Z","provider":"openai","model":"gpt-5.6-sol","inputTokens":50,"outputTokens":10,"reasoningTokens":0,"cacheWriteTokens":0,"cacheReadTokens":100,"cost":3},
  {"project":"$BACKFILL_D","sessionId":"boundary-d","timestamp":"2026-07-01T23:30:00.000Z","provider":"openai","model":"gpt-5.6-sol","inputTokens":25,"outputTokens":5,"reasoningTokens":0,"cacheWriteTokens":0,"cacheReadTokens":50,"cost":0.5},
  {"project":"/unmanaged/project","sessionId":"unmanaged","timestamp":"2026-07-01T10:00:00.000Z","provider":"claude","model":"claude-opus-5","inputTokens":400,"outputTokens":80,"reasoningTokens":0,"cacheWriteTokens":0,"cacheReadTokens":600,"cost":8}
]}
JSON
BACKFILL_OUT=$("$STORE" backfill-codeburn "$BACKFILL_EXPORT" 2>&1) \
  || fail "bounded codeburn backfill failed: $BACKFILL_OUT"
# shellcheck disable=SC2016 # Literal currency amount, not shell expansion.
assert_contains "$BACKFILL_OUT" 'attributed 3 records / $4.0000 to 3 tasks' \
  'backfill did not report its exact attributed subtotal'
# shellcheck disable=SC2016 # Literal currency amount, not shell expansion.
assert_contains "$BACKFILL_OUT" 'per-record rounding delta $0.0000' \
  'backfill did not reconcile the export summary with its task-level record ledger'
# shellcheck disable=SC2016 # Literal currency amount, not shell expansion.
assert_contains "$BACKFILL_OUT" 'outside-task-window: 1 records / $4.0000' \
  'backfill did not classify known-worktree spend outside every task window'
# shellcheck disable=SC2016 # Literal currency amount, not shell expansion.
assert_contains "$BACKFILL_OUT" 'unmapped-worktree: 1 records / $8.0000' \
  'backfill did not classify spend whose worktree has no lifecycle mapping'
# shellcheck disable=SC2016 # Literal currency amount, not shell expansion.
assert_contains "$BACKFILL_OUT" 'incomplete-export-window: 1 records / $3.0000' \
  'backfill did not classify spend for a lifecycle crossing the export boundary'
assert_contains "$BACKFILL_OUT" 'missing coverage 922-backfill-boundary: [2026-06-30T23:50:00Z, 2026-07-01T00:00:00.000Z)' \
  'backfill did not report the missing lifecycle coverage bounds'
[ ! -e "$FM_HOME/data/922-backfill-boundary/usage.json" ] \
  || fail 'backfill wrote a partial snapshot for a boundary-crossing lifecycle'
EXACT_BOUNDARY_COST=$(query "SELECT notional_cost_usd FROM task WHERE task_id = '923-backfill-exact-boundary'")
[ "$EXACT_BOUNDARY_COST" = '0.5' ] \
  || fail "backfill did not attribute an exactly covered end-boundary lifecycle: $EXACT_BOUNDARY_COST"
BACKFILLED=$(query "SELECT task_id, project_path, tokens_in, tokens_out, tokens_reasoning, tokens_cached_read, tokens_cached_write, notional_cost_usd, api_calls, sessions FROM task WHERE task_id IN ('920-backfill-a','921-backfill-b') ORDER BY task_id")
[ "$BACKFILLED" = "920-backfill-a|$PROJECT|100|20|5|900|7|1.25|1|1
921-backfill-b|$PROJECT|200|40|0|800|9|2.25|1|1" ] \
  || fail "timestamp-window backfill did not populate exact per-task values: $BACKFILLED"
BACKFILL_CORRELATION=$(node - "$FM_HOME/data/920-backfill-a/usage.json" <<'NODE'
const fs = require('fs')
const usage = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
process.stdout.write([
  usage.correlation?.attribution,
  usage.correlation?.baseline,
  usage.correlation?.window?.start,
  usage.correlation?.window?.end,
  usage.correlation?.records,
  /^[0-9a-f]{64}$/.test(usage.correlation?.export_sha256 || ''),
].join('|'))
NODE
)
[ "$BACKFILL_CORRELATION" = 'timestamp-window|false|2026-07-01T10:00:00Z|2026-07-01T10:30:00Z|1|true' ] \
  || fail "backfill snapshot lacks auditable bounded provenance: $BACKFILL_CORRELATION"
pass 'codeburn export records backfill exact task windows and classify every unattributed dollar'

COLLISION_EXACT="$ROOTDIR/worktrees/collision-a-b"
COLLISION_OTHER="$ROOTDIR/worktrees/collision-a/b"
COLLISION_EXACT_JSON=${COLLISION_EXACT//\//\\\\}
fm_write_meta "$FM_HOME/state/924-backfill-collision-exact.meta" \
  "worktree=$COLLISION_EXACT" \
  "project=$PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "spawned_at=2026-07-01T12:00:00Z" \
  "teardown_at=2026-07-01T12:30:00Z" \
  "outcome=forced"
"$STORE" capture 924-backfill-collision-exact --outcome forced >/dev/null \
  || fail 'exact collision lifecycle capture failed'
fm_write_meta "$FM_HOME/state/925-backfill-collision-other.meta" \
  "worktree=$COLLISION_OTHER" \
  "project=$PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "spawned_at=2026-07-01T12:00:00Z" \
  "teardown_at=2026-07-01T12:30:00Z" \
  "outcome=forced"
"$STORE" capture 925-backfill-collision-other --outcome forced >/dev/null \
  || fail 'other collision lifecycle capture failed'
COLLISION_EXPORT="$ROOTDIR/codeburn-backfill-collision.json"
cat > "$COLLISION_EXPORT" <<JSON
{"schema":"codeburn.export.v2","generated":"2026-07-02T00:00:00.000Z","summary":[{"Period":"2026-07-01 to 2026-07-01","Cost (USD)":3,"API Calls":2}],"records":[
  {"project":"$COLLISION_EXACT_JSON","sessionId":"collision-exact","timestamp":"2026-07-01T12:05:00.000Z","provider":"openai","model":"gpt-5.6-sol","inputTokens":10,"outputTokens":2,"reasoningTokens":1,"cacheWriteTokens":0,"cacheReadTokens":20,"cost":1},
  {"project":"$ROOTDIR/worktrees/collision_a_b","sessionId":"collision-ambiguous","timestamp":"2026-07-01T12:10:00.000Z","provider":"openai","model":"gpt-5.6-sol","inputTokens":20,"outputTokens":4,"reasoningTokens":2,"cacheWriteTokens":0,"cacheReadTokens":40,"cost":2}
]}
JSON
COLLISION_OUT=$("$STORE" backfill-codeburn "$COLLISION_EXPORT" 2>&1) \
  || fail "collision backfill failed: $COLLISION_OUT"
assert_contains "$COLLISION_OUT" "attributed 1 records / \$1.0000 to 1 tasks" \
  'separator-normalized exact path did not win over a lossy collision'
assert_contains "$COLLISION_OUT" "ambiguous-worktree-key: 1 records / \$2.0000" \
  'lossy collision without an exact path did not refuse attribution'
COLLISION_COST=$(query "SELECT notional_cost_usd FROM task WHERE task_id = '924-backfill-collision-exact'")
[ "$COLLISION_COST" = '1' ] \
  || fail "exact collision task did not retain its exact cost: $COLLISION_COST"
[ ! -e "$FM_HOME/data/925-backfill-collision-other/usage.json" ] \
  || fail 'ambiguous lossy collision invented a task cost'
pass 'backfill prefers separator-normalized exact paths and refuses lossy ambiguity'

BACKFILL_BEFORE=$(cat "$FM_HOME/data/920-backfill-a/usage.json")
rm -f "$FM_HOME/data/920-backfill-a/usage.json"
printf '%s\n' '{"schema":"fm-task-usage.v2","id":"921-backfill-b","correlation":{"baseline":true}}' \
  > "$FM_HOME/data/921-backfill-b/usage.json"
if "$STORE" backfill-codeburn "$BACKFILL_EXPORT" >/dev/null 2>"$ROOTDIR/backfill-batch-refusal.err"; then
  fail 'backfill accepted a later conflicting usage snapshot'
fi
[ ! -e "$FM_HOME/data/920-backfill-a/usage.json" ] \
  || fail 'backfill wrote an earlier task before detecting a later conflict'
[ "$(cat "$FM_HOME/data/921-backfill-b/usage.json")" = '{"schema":"fm-task-usage.v2","id":"921-backfill-b","correlation":{"baseline":true}}' ] \
  || fail 'failed batch changed the conflicting usage snapshot'
"$STORE" backfill-codeburn --replace-existing "$BACKFILL_EXPORT" >/dev/null \
  || fail 'explicit batch restoration failed'
printf '%s\n' '{"schema":"fm-task-usage.v2","id":"920-backfill-a","correlation":{"baseline":true}}' \
  > "$FM_HOME/data/920-backfill-a/usage.json"
if "$STORE" backfill-codeburn "$BACKFILL_EXPORT" >/dev/null 2>"$ROOTDIR/backfill-refusal.err"; then
  fail 'backfill silently replaced a different existing usage snapshot'
fi
assert_contains "$(cat "$ROOTDIR/backfill-refusal.err")" '--replace-existing' \
  'backfill refusal did not identify the explicit replacement policy'
[ "$(cat "$FM_HOME/data/920-backfill-a/usage.json")" = '{"schema":"fm-task-usage.v2","id":"920-backfill-a","correlation":{"baseline":true}}' ] \
  || fail 'refused backfill modified the authoritative existing snapshot'
"$STORE" backfill-codeburn --replace-existing "$BACKFILL_EXPORT" >/dev/null \
  || fail 'explicit backfill replacement failed'
[ "$(cat "$FM_HOME/data/920-backfill-a/usage.json")" = "$BACKFILL_BEFORE" ] \
  || fail 'explicit replacement did not restore the exact backfill snapshot'
BACKUP_COUNT=$(find "$FM_HOME/data/920-backfill-a" -maxdepth 1 -type f -name 'usage.pre-backfill.*.json' | wc -l)
[ "$BACKUP_COUNT" -eq 1 ] || fail 'explicit replacement did not preserve exactly one prior usage artifact'
"$STORE" backfill-codeburn "$BACKFILL_EXPORT" >/dev/null \
  || fail 'byte-equivalent backfill rerun was not idempotent'
[ "$(find "$FM_HOME/data/920-backfill-a" -maxdepth 1 -type f -name 'usage.pre-backfill.*.json' | wc -l)" -eq 1 ] \
  || fail 'idempotent rerun created another preservation artifact'
pass 'backfill replacement is explicit, preserving, and byte-idempotent'

COMPLETE_PROJECT="$ROOTDIR/complete-project"
fm_write_meta "$FM_HOME/state/926-complete-project.meta" \
  "worktree=$ROOTDIR/worktrees/complete-project" \
  "project=$COMPLETE_PROJECT" \
  "harness=codex" \
  "model=configured-gpt" \
  "effort=xhigh" \
  "kind=ship" \
  "spawned_at=2026-07-03T12:00:00Z" \
  "teardown_at=2026-07-03T12:30:00Z" \
  "outcome=forced"
write_usage 926-complete-project 100 20 0.75 2 gpt-5.6-sol 2026-07-03T12:00:00Z
"$STORE" capture 926-complete-project --outcome forced >/dev/null \
  || fail 'complete known-row project capture failed'

REPORT=$("$STORE" report 910-lifecycle --sync) || fail 'single-task report failed'
assert_contains "$REPORT" '910-lifecycle' 'report should identify the task'
assert_contains "$REPORT" '15m 0s' 'report should surface launch-to-PR duration'
# shellcheck disable=SC2016 # Literal currency amount, not shell expansion.
assert_contains "$REPORT" '$1.2500' 'report should surface cost'
assert_contains "$REPORT" '321 in / 45 out' 'report should surface tokens'
assert_contains "$REPORT" 'gpt-5.6-sol' 'report should surface the actual model'
ALL_REPORT=$("$STORE" report) || fail 'cross-task report failed'
assert_contains "$ALL_REPORT" 'TOTAL' 'cross-task report should include aggregate totals'
assert_contains "$ALL_REPORT" "PROJECT $PROJECT" \
  'cross-task report should aggregate task spend by the recorded project rather than worktree'
assert_contains "$ALL_REPORT" "PROJECT $PROJECT | unavailable |" \
  'a project with incomplete task coverage should withhold its partial subtotal'
assert_contains "$ALL_REPORT" "PROJECT $COMPLETE_PROJECT | unavailable | 1/1 known tasks have cost evidence; historical population completeness is unproven" \
  'complete known-row coverage should not be presented as complete historical population coverage'
if printf '%s\n' "$ALL_REPORT" | grep '^PROJECT ' | grep -Fq '$'; then
  fail 'a project line quoted a dollar total without a durable population bound'
fi

USAGE=$("$STORE" --help)
assert_contains "$USAGE" 'report [<task-id>]' 'help should document the one reporting command'
assert_contains "$USAGE" 'backfill-codeburn [--replace-existing] <export.json>' \
  'help should document the explicit historical recovery command'
pass 'reporting exposes project coverage and the documented backfill command'

# --- context signal: peak context, compactions, and restarts at capture --------
# The three fields sit on the task row beside outcome so a later query can
# correlate rework with compaction and relaunch; they come from the task's own
# stamped session records at capture time and are never backfilled.

CTX_STAMP_A=33333333-3333-4333-8333-333333333333
CTX_STAMP_B=44444444-4444-4444-8444-444444444444
CTX_STORE="$ROOTDIR/ctx-store"
CTX_WT="$ROOTDIR/worktrees/ctx"
mkdir -p "$CTX_WT" "$FM_HOME/data/930-context/sessions"
printf '{"schema":"fm-task-sessions.v1","id":"930-context","spawned_at":"2026-08-01T10:00:00Z"}\n' \
  > "$FM_HOME/data/930-context/sessions/identity.json"
printf '{"stamp":"%s","harness":"claude","store":"%s","worktree":"%s"}\n{"stamp":"%s","harness":"claude","store":"%s","worktree":"%s"}\n' \
  "$CTX_STAMP_A" "$CTX_STORE" "$CTX_WT" "$CTX_STAMP_B" "$CTX_STORE" "$CTX_WT" \
  > "$FM_HOME/data/930-context/sessions/launches.jsonl"
CTX_DIR="$CTX_STORE/projects/$(printf '%s' "$CTX_WT" | tr -c 'A-Za-z0-9' '-')"
mkdir -p "$CTX_DIR"
write_ctx_record() {  # <stamp> <context-tokens>... (a "compact" token is a compaction)
  local stamp=$1 file n=0 value
  shift
  file="$CTX_DIR/$stamp.jsonl"
  printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"2026-08-01T10:00:01.000Z","uuid":"u-1","message":{"role":"user","content":"go"}}\n' "$CTX_WT" "$stamp" > "$file"
  for value in "$@"; do
    n=$((n + 1))
    if [ "$value" = compact ]; then
      printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"2026-08-01T10:%02d:00.000Z","uuid":"c-%s","isCompactSummary":true,"message":{"role":"user","content":"continued"}}\n' "$CTX_WT" "$stamp" "$n" "$n" >> "$file"
    else
      printf '{"type":"assistant","cwd":"%s","sessionId":"%s","timestamp":"2026-08-01T10:%02d:00.000Z","uuid":"a-%s","requestId":"r-%s","message":{"id":"m-%s","model":"claude-opus-5","role":"assistant","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":1},"content":[]}}\n' "$CTX_WT" "$stamp" "$n" "$n" "$n" "$n" "$value" >> "$file"
    fi
  done
}
write_ctx_record "$CTX_STAMP_A" 150000 240000 compact 40000 compact 90000
write_ctx_record "$CTX_STAMP_B" 70000
fm_write_meta "$FM_HOME/state/930-context.meta" \
  "worktree=$CTX_WT" \
  "project=$PROJECT" \
  "harness=claude" \
  "kind=ship" \
  "spawned_at=2026-08-01T10:00:00Z" \
  "teardown_at=2026-08-01T12:00:00Z" \
  "outcome=forced"
"$STORE" capture 930-context --outcome forced >/dev/null || fail 'context capture failed'
CONTEXT_ROW=$(query "SELECT peak_context_tokens, compactions, restarts, outcome FROM task WHERE task_id = '930-context'")
[ "$CONTEXT_ROW" = '240000|2|1|forced' ] \
  || fail "capture did not store the context signal beside the outcome: $CONTEXT_ROW"
UNBOUND_ROW=$(query "SELECT peak_context_tokens, compactions, restarts FROM task WHERE task_id = '910-lifecycle'")
[ "$UNBOUND_ROW" = 'NULL|NULL|NULL' ] \
  || fail "a task with no bound session record must keep the context fields missing, never zero: $UNBOUND_ROW"
pass 'capture stores peak context, compactions, and restarts on the task row and leaves unbound tasks missing'

CONTEXT_REPORT=$("$STORE" report --sync) || fail 'context report failed'
assert_contains "$CONTEXT_REPORT" 'COMPACTIONS' 'report should carry the compaction-bucket summary line'
CONTEXT_LINE=$(printf '%s\n' "$CONTEXT_REPORT" | grep '^COMPACTIONS')
assert_contains "$CONTEXT_LINE" '2+: 1 task (forced 1)' 'the 2+ bucket should group the compacted task by outcome'
assert_contains "$CONTEXT_LINE" '0: 0 tasks' 'the 0 bucket should be explicit even when empty'
assert_contains "$CONTEXT_LINE" 'unknown:' 'tasks captured before the signal existed should be reported as unknown, not zero'
TASK_REPORT=$("$STORE" report 930-context) || fail 'single context report failed'
assert_contains "$TASK_REPORT" '240000 peak / 2 compactions / 1 restarts' 'single-task report should expose the context signal'
pass 'report groups outcome by compaction bucket and exposes the per-task context signal'

# --- token attribution: where each task's tokens went ------------------------
# Every capture folds the task's bound session records into per-tool, per-class,
# largest-result, and per-turn rows plus five summary columns on the task row.
# The breakdown is written as a durable task snapshot at capture and is never
# derived at rebuild, so a task captured before the fold existed stays NULL and
# a bound record that yields no breakdown is an ingest issue, not a zero.

TOOLS_STAMP=55555555-5555-4555-8555-555555555555
mkdir -p "$FM_HOME/data/940-tools/sessions"
printf '{"schema":"fm-task-sessions.v1","id":"940-tools","spawned_at":"2026-08-02T10:00:00Z"}\n' \
  > "$FM_HOME/data/940-tools/sessions/identity.json"
printf '{"stamp":"%s","harness":"claude","store":"%s","worktree":"%s"}\n' \
  "$TOOLS_STAMP" "$CTX_STORE" "$CTX_WT" > "$FM_HOME/data/940-tools/sessions/launches.jsonl"
TOOLS_RECORD="$CTX_DIR/$TOOLS_STAMP.jsonl"
tools_row() { printf '%s\n' "$1" >> "$TOOLS_RECORD"; }
printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"2026-08-02T10:00:01.000Z","uuid":"u-1","message":{"role":"user","content":"go"}}\n' "$CTX_WT" "$TOOLS_STAMP" > "$TOOLS_RECORD"
tools_assistant() {  # <minute> <request> <context> <output> <content-json>
  printf '{"type":"assistant","cwd":"%s","sessionId":"%s","timestamp":"2026-08-02T10:%02d:00.000Z","uuid":"a-%s-%s","requestId":"r-%s","message":{"id":"m-%s","model":"claude-opus-5","role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":%s},"content":%s}}\n' \
    "$CTX_WT" "$TOOLS_STAMP" "$1" "$1" "$RANDOM" "$2" "$2" "$3" "$4" "$5" >> "$TOOLS_RECORD"
}
tools_result() {  # <minute> <second> <tool-id> <content>
  printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"2026-08-02T10:%02d:%02d.000Z","uuid":"r-%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s"}]}}\n' \
    "$CTX_WT" "$TOOLS_STAMP" "$1" "$2" "$3" "$3" "$4" >> "$TOOLS_RECORD"
}
tools_assistant 1 1 50000 30 '[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rg -n memory src"}}]'
tools_result 1 2 t1 'src/Memory.ts:1:remember'
tools_assistant 2 2 52000 70 '[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"src/Memory.ts"}}]'
tools_result 2 1 t2 "$(printf 'z%.0s' $(seq 1 800))"
tools_assistant 3 3 56000 90 '[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"git diff --stat"}}]'
tools_result 3 6 t3 "$(printf 'd%.0s' $(seq 1 200))"
tools_assistant 4 4 57000 40 '[{"type":"text","text":"done"}]'
fm_write_meta "$FM_HOME/state/940-tools.meta" \
  "worktree=$CTX_WT" "project=$PROJECT" "harness=claude" "kind=ship" \
  "spawned_at=2026-08-02T10:00:00Z" "teardown_at=2026-08-02T12:00:00Z" "outcome=forced"
"$STORE" capture 940-tools --outcome forced >/dev/null || fail 'tool usage capture failed'

TOOLS_TASK=$(query "SELECT turns, tool_calls, tool_result_tokens_est, assistant_output_tokens, base_prompt_tokens_est, peak_context_tokens FROM task WHERE task_id = '940-tools'")
[ "$TOOLS_TASK" = '4|3|256|230|50000|57000' ] \
  || fail "capture did not store the token attribution summary beside the context signal: $TOOLS_TASK"
[ "$(query "SELECT status FROM task_source WHERE task_id = '940-tools' AND source = 'tool-usage'")" = present ] \
  || fail 'a captured breakdown should record the tool-usage source as present'
TOOLS_ROWS=$(query "SELECT tool_name, tool_class, calls, result_bytes, result_tokens_est, wall_seconds_in_tool FROM task_tool_usage WHERE task_id = '940-tools' ORDER BY tool_name, tool_class")
[ "$TOOLS_ROWS" = 'Bash|differential|1|200|50|6
Bash|search|1|24|6|2
Read|read|1|800|200|1' ] || fail "per-tool rows wrong: $TOOLS_ROWS"
CLASS_ROWS=$(query "SELECT tool_class, calls, result_tokens_est, wall_seconds_in_tool FROM task_tool_class WHERE task_id = '940-tools' ORDER BY tool_class")
[ "$CLASS_ROWS" = 'differential|1|50|6
read|1|200|1
search|1|6|2' ] || fail "per-class roll-up wrong: $CLASS_ROWS"
LARGEST=$(query "SELECT rank, tool_name, tool_class, tokens_est, command_or_input_head FROM task_largest_results WHERE task_id = '940-tools' ORDER BY rank")
[ "$LARGEST" = '1|Read|read|200|src/Memory.ts
2|Bash|differential|50|git diff --stat
3|Bash|search|6|rg -n memory src' ] || fail "largest results wrong: $LARGEST"
TIMELINE=$(query "SELECT turn_index, ts, context_tokens, output_tokens, tool_name, tool_class, tool_result_tokens_est FROM task_turn_timeline WHERE task_id = '940-tools' ORDER BY turn_index")
[ "$TIMELINE" = '1|2026-08-02T10:01:00.000Z|50000|30|Bash|search|6
2|2026-08-02T10:02:00.000Z|52000|70|Read|read|200
3|2026-08-02T10:03:00.000Z|56000|90|Bash|differential|50
4|2026-08-02T10:04:00.000Z|57000|40|NULL|NULL|0' ] || fail "turn timeline wrong: $TIMELINE"
pass 'capture stores the per-tool, per-class, largest-result, and per-turn attribution beside the task summary columns'

# A bound record with usage rows but no tool call is a real zero; an unbound
# task stays NULL; a bound record that yields no request at all is an issue.
[ "$(query "SELECT tool_calls, turns FROM task WHERE task_id = '930-context'")" = '0|5' ] \
  || fail "a bound record without tool calls should read as a real zero with its turns counted: $(query "SELECT tool_calls, turns FROM task WHERE task_id = '930-context'")"
[ "$(query "SELECT turns, tool_calls, tool_result_tokens_est, assistant_output_tokens, base_prompt_tokens_est FROM task WHERE task_id = '910-lifecycle'")" = 'NULL|NULL|NULL|NULL|NULL' ] \
  || fail 'a task with no bound session record must keep the attribution columns NULL'
[ "$(query "SELECT COUNT(*) FROM ingest_issue WHERE task_id = '910-lifecycle' AND source = 'tool-usage'")" = 0 ] \
  || fail 'an unbound task is missing, not an ingest issue'
EMPTY_STAMP=66666666-6666-4666-8666-666666666666
mkdir -p "$FM_HOME/data/941-empty/sessions"
printf '{"schema":"fm-task-sessions.v1","id":"941-empty","spawned_at":"2026-08-03T10:00:00Z"}\n' \
  > "$FM_HOME/data/941-empty/sessions/identity.json"
printf '{"stamp":"%s","harness":"claude","store":"%s","worktree":"%s"}\n' \
  "$EMPTY_STAMP" "$CTX_STORE" "$CTX_WT" > "$FM_HOME/data/941-empty/sessions/launches.jsonl"
printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"2026-08-03T10:00:01.000Z","uuid":"u-1","message":{"role":"user","content":"go"}}\n' \
  "$CTX_WT" "$EMPTY_STAMP" > "$CTX_DIR/$EMPTY_STAMP.jsonl"
fm_write_meta "$FM_HOME/state/941-empty.meta" \
  "worktree=$CTX_WT" "project=$PROJECT" "harness=claude" "kind=ship" \
  "spawned_at=2026-08-03T10:00:00Z" "teardown_at=2026-08-03T12:00:00Z" "outcome=forced"
"$STORE" capture 941-empty --outcome forced >/dev/null || fail 'empty-record capture failed'
[ "$(query "SELECT kind FROM ingest_issue WHERE task_id = '941-empty' AND source = 'tool-usage'")" = 'tool-usage-unavailable' ] \
  || fail "a bound record that yields no breakdown must be flagged: $(query "SELECT source, kind, detail FROM ingest_issue WHERE task_id = '941-empty'")"
[ "$(query "SELECT status FROM task_source WHERE task_id = '941-empty' AND source = 'tool-usage'")" = missing ] \
  || fail 'an unavailable breakdown records the tool-usage source as missing'
[ "$(query "SELECT turns, tool_calls FROM task WHERE task_id = '941-empty'")" = 'NULL|NULL' ] \
  || fail 'an unavailable breakdown must leave the summary columns NULL, never zero'
pass 'missing attribution is missing, an empty bound record is a flagged issue, and a request without tool calls is a real zero'

# The codex capture path folds the same way from a rollout.
CODEX_TOOLS_STAMP=77777777-7777-4777-8777-777777777777
mkdir -p "$FM_HOME/data/942-codex/sessions" "$CTX_STORE/sessions/2026/08/04"
printf '{"schema":"fm-task-sessions.v1","id":"942-codex","spawned_at":"2026-08-04T10:00:00Z"}\n' \
  > "$FM_HOME/data/942-codex/sessions/identity.json"
printf '{"stamp":"%s","harness":"codex","store":"%s","worktree":"%s"}\n' \
  "$CODEX_TOOLS_STAMP" "$CTX_STORE" "$CTX_WT" > "$FM_HOME/data/942-codex/sessions/launches.jsonl"
CODEX_RECORD="$CTX_STORE/sessions/2026/08/04/rollout-2026-08-04T10-00-00-942.jsonl"
{
  printf '{"timestamp":"2026-08-04T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"942-session","id":"942-session","timestamp":"2026-08-04T10:00:00.000Z","cwd":"%s","originator":"%s","cli_version":"0.153.4","source":"cli"}}\n' "$CTX_WT" "$CODEX_TOOLS_STAMP"
  printf '{"timestamp":"2026-08-04T10:01:00.000Z","ordinal":1,"type":"response_item","payload":{"type":"function_call","call_id":"c1","name":"shell","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"npm run build\\"]}"}}\n'
  printf '{"timestamp":"2026-08-04T10:01:08.000Z","ordinal":2,"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"built in 8s"}}\n'
  printf '{"timestamp":"2026-08-04T10:01:09.000Z","ordinal":3,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":700,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":60,"reasoning_output_tokens":0,"total_tokens":760},"last_token_usage":{"input_tokens":700,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":60,"reasoning_output_tokens":0,"total_tokens":760},"model_context_window":258400},"rate_limits":null}}\n'
} > "$CODEX_RECORD"
fm_write_meta "$FM_HOME/state/942-codex.meta" \
  "worktree=$CTX_WT" "project=$PROJECT" "harness=codex" "kind=ship" \
  "spawned_at=2026-08-04T10:00:00Z" "teardown_at=2026-08-04T12:00:00Z" "outcome=forced"
"$STORE" capture 942-codex --outcome forced >/dev/null || fail 'codex tool usage capture failed'
CODEX_ROWS=$(query "SELECT tool_name, tool_class, calls, result_bytes, result_tokens_est, wall_seconds_in_tool FROM task_tool_usage WHERE task_id = '942-codex'")
[ "$CODEX_ROWS" = 'shell|build|1|11|3|8' ] || fail "codex per-tool row wrong: $CODEX_ROWS"
[ "$(query "SELECT turns, tool_calls, assistant_output_tokens, base_prompt_tokens_est FROM task WHERE task_id = '942-codex'")" = '1|1|60|700' ] \
  || fail 'codex summary columns wrong'
pass 'a codex rollout captures through the same attribution path'

# --- reports: the class split per task and the timeline summary per task ------

USAGE_REPORT=$("$STORE" report --sync) || fail 'usage report failed'
assert_contains "$USAGE_REPORT" 'CONTEXT | USAGE | CLASSES (tok est)' 'the cross-task header should label class-split token estimates'
USAGE_LINE=$(printf '%s\n' "$USAGE_REPORT" | grep '^940-tools ')
assert_contains "$USAGE_LINE" '| 4 turns / 3 calls / 256 result tok est / 230 out tok / 57000 peak ctx |' \
  'the cross-task row should show turns, calls, estimated result tokens, output tokens, and peak context'
assert_contains "$USAGE_LINE" '| read 200, search 6, differential 50' \
  'the cross-task row should show the class split in taxonomy order with estimated result tokens'
UNBOUND_LINE=$(printf '%s\n' "$USAGE_REPORT" | grep '^910-lifecycle ')
assert_contains "$UNBOUND_LINE" '| - | - |' 'a task without attribution should print dashes, never zeros'
TOOLS_REPORT=$("$STORE" report 940-tools) || fail 'single tool report failed'
assert_contains "$TOOLS_REPORT" 'BASE PROMPT 50000 tok est' 'the per-task report should show the base prompt estimate'
assert_contains "$TOOLS_REPORT" 'Read | read | 1 | 800 | 200 | 1' 'the per-task report should list each tool with bytes, estimated tokens, and wall seconds'
assert_contains "$TOOLS_REPORT" 'differential | 1 | 50 | 6' 'the per-task report should roll tokens and wall seconds up by class'
assert_contains "$TOOLS_REPORT" '1 | Read | read | 200 tok est | src/Memory.ts' 'the per-task report should rank the largest results with their input head'
assert_contains "$TOOLS_REPORT" 'TIMELINE 4 turns | ctx@1 50000 | @25% (turn 1) 50000 | @50% (turn 2) 52000 | @75% (turn 3) 56000 | @100% (turn 4) 57000' \
  'the per-task report should sample context at turn 1 and at each quarter of the turns'
assert_contains "$TOOLS_REPORT" '+4000 | turn 2 -> 3 | Read (read)' 'the largest single-turn jump should name the tool class of the turn whose results landed'
assert_contains "$TOOLS_REPORT" '+2000 | turn 1 -> 2 | Bash (search)' 'the second largest jump should follow'
assert_contains "$TOOLS_REPORT" 'tok est' 'every estimated token figure must be labelled as an estimate'
EMPTY_REPORT=$("$STORE" report 941-empty) || fail 'empty tool report failed'
assert_contains "$EMPTY_REPORT" 'TOOL USAGE unavailable' 'an unavailable breakdown should say so in the per-task report'
pass 'reports show the class split per task and the per-task timeline summary with the largest jumps'

# --- forward-only and rebuildable ----------------------------------------------
# The breakdown survives the session record going away because capture wrote it
# durably, and a rebuild reproduces it without consulting any record.

TOOLS_FINGERPRINT=$("$STORE" fingerprint) || fail 'fingerprint after attribution failed'
rm -f "$TOOLS_RECORD" "$CODEX_RECORD"
rm -f "$DB"
"$STORE" rebuild >/dev/null || fail 'rebuild after removing session records failed'
[ "$("$STORE" fingerprint)" = "$TOOLS_FINGERPRINT" ] \
  || fail 'rebuild must reproduce the attribution tables from the durable snapshot alone'
[ "$(query "SELECT COUNT(*) FROM task_turn_timeline WHERE task_id = '940-tools'")" = 4 ] \
  || fail 'the turn timeline must survive a rebuild without the session record'
pass 'the attribution is forward-only durable evidence and the rebuild contract covers every new table'

# --- CI ledger per landed PR ---------------------------------------------------
# The forge is a stub: every `gh api` call answers from JSON fixtures and is
# logged, so no test here can reach GitHub. Runs and jobs are recorded by the
# forge at the time; the store derives counts and minutes from them.

FORGE="$ROOTDIR/forge"
mkdir -p "$FORGE" "$FM_HOME/data/pr-merges"
export FM_TEST_FORGE_JSON="$FORGE"
FAKEBIN=$(fm_fakebin "$ROOTDIR")
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = api ] || { echo "unexpected gh invocation: $*" >&2; exit 1; }
printf '%s\n' "$*" >> "$FM_TEST_FORGE_JSON/calls.log"
path=${2%%\?*}
query=${2#"$path"}
case "$path" in
  */issues/*/comments) n=${path#*/issues/}; n=${n%%/*}; f="$FM_TEST_FORGE_JSON/comments-$n.json" ;;
  */pulls/*) f="$FM_TEST_FORGE_JSON/pull-${path##*/}.json" ;;
  */actions/runs/*/jobs) id=${path#*/actions/runs/}; id=${id%%/*}; f="$FM_TEST_FORGE_JSON/jobs-$id.json" ;;
  */actions/runs) branch=$(printf '%s' "$query" | sed -n 's/.*branch=\([^&]*\).*/\1/p'); f="$FM_TEST_FORGE_JSON/runs-${branch//%2F/__}.json" ;;
  *) echo "gh: unstubbed path $path" >&2; exit 1 ;;
esac
[ -f "$f" ] || { echo "gh: HTTP 404: Not Found ($path)" >&2; exit 1; }
cat "$f"
SH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

node - "$FORGE" <<'NODE'
const fs = require('fs')
const path = require('path')
const dir = process.argv[2]
const write = (name, value) => fs.writeFileSync(path.join(dir, name), `${JSON.stringify(value)}\n`)
const pr = (number, ref, extra) => ({
  number, title: `PR ${number}`, body: '', state: 'closed', merged: true,
  created_at: '2026-06-01T10:15:00Z', closed_at: '2026-06-01T11:00:00Z', merged_at: '2026-06-01T11:00:00Z',
  head: {ref, sha: 'a'.repeat(40)}, base: {ref: 'main'}, ...extra,
})
const run = (id, conclusion, created, started, updated, extra) => ({
  id, name: 'CI', event: 'pull_request', status: 'completed', conclusion, run_attempt: 1,
  created_at: created, run_started_at: started, updated_at: updated, head_sha: 'b'.repeat(40), ...extra,
})
const runsOn = (ref, runs) => [{total_count: runs.length, workflow_runs: runs.map(item => ({...item, head_branch: ref}))}]
const job = (id, started, completed, conclusion = 'success') => ({
  id, name: `job ${id}`, status: 'completed', conclusion, started_at: started, completed_at: completed,
})
// A directly merged PR: one cancelled run, one successful re-run, and a run
// created after the PR closed that must never be fetched.
write('pull-42.json', pr(42, 'fm/950-direct', {title: 'Introduce memory', body: '## Measurement\n- **23 moved**, 0 lost\n'}))
write('runs-fm__950-direct.json', runsOn('fm/950-direct', [
  run(1001, 'cancelled', '2026-06-01T10:16:00Z', '2026-06-01T10:16:00Z', '2026-06-01T10:20:00Z'),
  run(1002, 'success', '2026-06-01T10:30:00Z', '2026-06-01T10:31:00Z', '2026-06-01T10:50:00Z', {run_attempt: 2}),
  run(1003, 'success', '2026-06-01T11:30:00Z', '2026-06-01T11:30:00Z', '2026-06-01T11:40:00Z', {event: 'push'}),
]))
write('jobs-1001.json', [{total_count: 1, jobs: [job(1, '2026-06-01T10:18:00Z', '2026-06-01T10:20:00Z', 'cancelled')]}])
write('jobs-1002.json', [{total_count: 3, jobs: [
  job(2, '2026-06-01T10:33:00Z', '2026-06-01T10:45:00Z'),
  job(3, '2026-06-01T10:34:00Z', '2026-06-01T10:50:00Z'),
  {id: 4, name: 'never started', status: 'completed', conclusion: 'cancelled', started_at: null, completed_at: null},
]}])
// A merge train with two members, no ejections, and two fix rounds.
write('pull-60.json', pr(60, 'fm/960-train', {
  title: 'train: memory (2 items)',
  created_at: '2026-06-02T10:00:00Z', closed_at: '2026-06-02T12:00:00Z', merged_at: '2026-06-02T12:00:00Z',
  body: [
    'Merge train "memory".', '',
    '## Manifest (2 members, 0 ejected)', '',
    '- #51 fm/951-member-a 1111111 clean',
    '- #52 fm/952-member-b 2222222 keep-both: AGENTS.md index', '',
    '## Ejected', '', 'None.', '',
    '## Fix round 1 (CI red on shard 1)', '', 'text', '',
    '## Fix round 2', '', 'text', '',
  ].join('\n'),
}))
write('runs-fm__960-train.json', runsOn('fm/960-train', [
  run(2001, 'failure', '2026-06-02T10:05:00Z', '2026-06-02T10:05:00Z', '2026-06-02T10:16:00Z'),
  run(2002, 'success', '2026-06-02T11:00:00Z', '2026-06-02T11:00:00Z', '2026-06-02T11:30:00Z'),
]))
write('jobs-2001.json', [{total_count: 1, jobs: [job(5, '2026-06-02T10:06:00Z', '2026-06-02T10:16:00Z', 'failure')]}])
write('jobs-2002.json', [{total_count: 1, jobs: [job(6, '2026-06-02T11:02:00Z', '2026-06-02T11:30:00Z')]}])
write('pull-51.json', pr(51, 'fm/951-member-a', {state: 'open', merged: false, closed_at: null, merged_at: null, body: '**10 moved**, 0 lost'}))
write('runs-fm__951-member-a.json', runsOn('fm/951-member-a', [
  run(3001, 'success', '2026-06-01T12:00:00Z', '2026-06-01T12:00:00Z', '2026-06-01T12:11:00Z'),
]))
write('jobs-3001.json', [{total_count: 1, jobs: [job(7, '2026-06-01T12:01:00Z', '2026-06-01T12:11:00Z')]}])
write('pull-52.json', pr(52, 'fm/952-member-b', {state: 'open', merged: false, closed_at: null, merged_at: null, body: '- **Strict floor 9: 8 moved**\n'}))
write('runs-fm__952-member-b.json', runsOn('fm/952-member-b', [
  run(3002, 'timed_out', '2026-06-01T13:00:00Z', '2026-06-01T13:00:00Z', '2026-06-01T13:31:00Z'),
]))
write('jobs-3002.json', [{total_count: 1, jobs: [job(8, '2026-06-01T13:01:00Z', '2026-06-01T13:31:00Z', 'timed_out')]}])
// Member PRs closed after a train landed: one names the train in its closing
// comment, one only in its Done row, one has no train evidence at all.
for (const [number, ref] of [[70, 'fm/970-closed'], [71, 'fm/971-done-row'], [72, 'fm/972-orphan']]) {
  write(`pull-${number}.json`, pr(number, ref, {merged: false, merged_at: null, closed_at: '2026-06-02T13:00:00Z'}))
  write(`runs-${ref.replace('/', '__')}.json`, runsOn(ref, [
    run(4000 + number, 'success', '2026-06-01T14:00:00Z', '2026-06-01T14:00:00Z', '2026-06-01T14:05:00Z'),
  ]))
  write(`jobs-${4000 + number}.json`, [{total_count: 1, jobs: [job(9, '2026-06-01T14:01:00Z', '2026-06-01T14:05:00Z')]}])
}
write('comments-70.json', [[{id: 1, created_at: '2026-06-02T13:00:00Z', body: 'Superseded: landed through train #60; closing.'}]])
write('comments-71.json', [[]])
write('comments-72.json', [[]])
// Closed member PRs whose train evidence names the PR itself: a closing
// comment that mentions the PR before the word train, a comment that names
// the PR and then the train, and Done rows whose titles carry the word train
// ahead of the row's own PR URL.
for (const [number, ref] of [[73, 'fm/973-self-comment'], [74, 'fm/974-own-then-train'], [75, 'fm/975-self-row'], [76, 'fm/976-self-only-row']]) {
  write(`pull-${number}.json`, pr(number, ref, {merged: false, merged_at: null, closed_at: '2026-06-02T13:00:00Z'}))
  write(`runs-${ref.replace('/', '__')}.json`, runsOn(ref, []))
}
write('comments-73.json', [[{id: 1, created_at: '2026-06-02T13:00:00Z', body: 'Closing #73: landed with the train.'}]])
write('comments-74.json', [[{id: 1, created_at: '2026-06-02T13:00:00Z', body: 'Retry train for #74 rolled into train #60; closing.'}]])
write('comments-75.json', [[]])
write('comments-76.json', [[]])
// A train abandoned without merging: its manifest names members that landed
// through nothing.
write('pull-61.json', pr(61, 'fm/961-dead-train', {
  title: 'train: memory retry (2 items)', merged: false, merged_at: null,
  created_at: '2026-06-03T10:00:00Z', closed_at: '2026-06-03T11:00:00Z',
  body: ['## Manifest (2 members, 0 ejected)', '', '- #56 fm/956-ghost-a 5555555 clean', '- #57 fm/957-ghost-b 5757575 clean'].join('\n'),
}))
write('runs-fm__961-dead-train.json', runsOn('fm/961-dead-train', []))
write('comments-61.json', [[]])
for (const [number, ref] of [[56, 'fm/956-ghost-a'], [57, 'fm/957-ghost-b']]) {
  write(`pull-${number}.json`, pr(number, ref, {state: 'open', merged: false, closed_at: null, merged_at: null}))
  write(`runs-${ref.replace('/', '__')}.json`, runsOn(ref, []))
}
// A relaunched card: its first PR closed unmerged, its second PR merged.
write('pull-77.json', pr(77, 'fm/977-relaunched', {merged: false, merged_at: null, closed_at: '2026-06-02T13:00:00Z'}))
write('runs-fm__977-relaunched.json', runsOn('fm/977-relaunched', []))
write('comments-77.json', [[]])
write('pull-91.json', pr(91, 'fm/977-relaunched', {
  body: '**6 moved**', created_at: '2026-06-04T10:00:00Z', closed_at: '2026-06-04T11:00:00Z', merged_at: '2026-06-04T11:00:00Z',
}))
// A branch whose run listing spans two pages, with a run created between the
// page reads so the second page repeats the first page's last run.
write('pull-92.json', pr(92, 'fm/978-paged', {}))
const paged = id => ({...run(id, 'success', '2026-06-01T10:20:00Z', '2026-06-01T10:20:00Z', '2026-06-01T10:30:00Z'), head_branch: 'fm/978-paged'})
write('runs-fm__978-paged.json', [
  {total_count: 3, workflow_runs: [paged(5001), paged(5002)]},
  {total_count: 3, workflow_runs: [paged(5002), paged(5003)]},
])
for (const id of [5001, 5002, 5003]) {
  write(`jobs-${id}.json`, [{total_count: 1, jobs: [job(id, '2026-06-01T10:21:00Z', '2026-06-01T10:30:00Z')]}])
}
// A second merged train whose member card was relaunched: its first PR closed
// unmerged, its second PR is the manifest member.
write('pull-62.json', pr(62, 'fm/962-train-two', {
  title: 'train: relaunch (1 item)', body: '## Manifest (1 member, 0 ejected)\n\n- #58 fm/958-relaunched-member 5858585 clean\n',
  created_at: '2026-06-05T10:00:00Z', closed_at: '2026-06-05T12:00:00Z', merged_at: '2026-06-05T12:00:00Z',
}))
write('runs-fm__962-train-two.json', runsOn('fm/962-train-two', []))
write('pull-58.json', pr(58, 'fm/958-relaunched-member', {state: 'open', merged: false, closed_at: null, merged_at: null, body: '**2 moved**'}))
write('pull-78.json', pr(78, 'fm/958-relaunched-member', {merged: false, merged_at: null, closed_at: '2026-06-02T13:00:00Z'}))
write('runs-fm__958-relaunched-member.json', runsOn('fm/958-relaunched-member', []))
write('comments-78.json', [[]])
// Still open: the ledger records landed PRs only.
write('pull-80.json', pr(80, 'fm/980-open', {state: 'open', merged: false, closed_at: null, merged_at: null}))
// A landed PR whose only record is its merge receipt, for the backfill.
write('pull-53.json', pr(53, 'fm/953-backfill', {body: '**4 moved**'}))
write('runs-fm__953-backfill.json', runsOn('fm/953-backfill', []))
NODE

cat > "$FM_HOME/data/backlog.md" <<'MD'
# Backlog

## Done
- [x] 971-done-row - Member b https://github.com/example/repo/pull/71 (repo: example) (kind: ship) (landed via train #60)
- [x] 975-self-row - Merge train retries https://github.com/example/repo/pull/75 (repo: example) (kind: ship) (landed via train #60)
- [x] 976-self-only-row - Merge train retries https://github.com/example/repo/pull/76 (repo: example) (kind: ship)
MD

fm_write_meta "$FM_HOME/state/950-direct.meta" \
  "worktree=$ROOTDIR/worktrees/direct" \
  "project=$PROJECT" \
  "kind=ship" \
  "spawned_at=2026-06-01T10:00:00Z" \
  "pr=https://github.com/example/repo/pull/42"
: > "$FORGE/calls.log"
CI_OUT=$("$STORE" capture-ci 950-direct 2>&1) || fail "CI capture failed: $CI_OUT"
assert_present "$FM_HOME/data/pr-ci/950-direct.json" 'CI capture should write a durable ledger under data/pr-ci/'
assert_no_grep 'runs/1003/jobs' "$FORGE/calls.log" 'a run created after the PR closed must not be fetched'
CI_ROW=$(query "SELECT pr_url, pr_number, landing, is_train, runs, runs_cancelled, runs_failed, runs_succeeded, runner_seconds, queue_seconds, first_run_created_at, last_run_completed_at, captured_from FROM task_ci WHERE task_id = '950-direct'")
[ "$CI_ROW" = 'https://github.com/example/repo/pull/42|42|direct|0|2|1|0|1|1800|300|2026-06-01T10:16:00Z|2026-06-01T10:50:00Z|manual' ] \
  || fail "direct CI ledger was not derived from the recorded runs and jobs: $CI_ROW"
[ "$(query "SELECT cards_moved_claimed FROM task WHERE task_id = '950-direct'")" = 23 ] \
  || fail 'the **N moved** figure was not parsed into task.cards_moved_claimed'
[ "$(query "SELECT run_attempt, jobs, runner_seconds, queue_seconds FROM task_ci_run WHERE task_id = '950-direct' AND run_id = 1002")" = '2|3|1680|180' ] \
  || fail 'per-run rows should carry the attempt, job count, runner seconds, and queue seconds'
[ "$(query "SELECT status FROM task_source WHERE task_id = '950-direct' AND source = 'ci'")" = present ] \
  || fail 'a captured ledger should mark the ci source present'
pass 'CI capture records the forge run ledger for a directly merged PR'

if "$STORE" capture-ci 950-direct https://github.com/example/repo/pull/43 >/dev/null 2>&1; then
  fail 'CI capture accepted a PR that conflicts with the task record'
fi
if "$STORE" capture-ci 980-open https://github.com/example/repo/pull/80 >/dev/null 2>&1; then
  fail 'CI capture accepted a PR that has not landed'
fi
assert_absent "$FM_HOME/data/pr-ci/980-open.json" 'an open PR must not produce a ledger'
pass 'CI capture refuses a conflicting PR and an open PR'

"$STORE" capture-ci 960-train https://github.com/example/repo/pull/60 >/dev/null 2>&1 || fail 'train CI capture failed'
TRAIN_ROW=$(query "SELECT landing, is_train, member_count, ejected_count, fix_round_count, runs, runs_failed, runs_succeeded, runner_seconds, queue_seconds FROM task_ci WHERE task_id = '960-train'")
[ "$TRAIN_ROW" = 'direct|1|2|0|2|2|1|1|2280|180' ] \
  || fail "train ledger did not record its members and fix rounds: $TRAIN_ROW"
MEMBER_ROWS=$(query "SELECT task_id, landing, train_pr_number, runs_failed, runner_seconds, captured_from FROM task_ci WHERE landing = 'train:60' ORDER BY task_id")
[ "$MEMBER_ROWS" = '951-member-a|train:60|60|0|600|train-manifest
952-member-b|train:60|60|1|1800|train-manifest' ] \
  || fail "manifest members were not captured as landed through the train: $MEMBER_ROWS"
[ "$(query "SELECT group_concat(cards_moved_claimed, ',') FROM (SELECT cards_moved_claimed FROM task WHERE task_id IN ('951-member-a', '952-member-b') ORDER BY task_id)")" = '10,8' ] \
  || fail 'member card claims were not parsed from their PR bodies'
pass 'a train merge captures its own ledger and every manifest member as landed through it'

"$STORE" capture-ci 970-closed https://github.com/example/repo/pull/70 >/dev/null 2>&1 || fail 'closed-by-comment capture failed'
"$STORE" capture-ci 971-done-row https://github.com/example/repo/pull/71 >/dev/null 2>&1 || fail 'closed-by-done-row capture failed'
"$STORE" capture-ci 972-orphan https://github.com/example/repo/pull/72 >/dev/null 2>&1 || fail 'closed-orphan capture failed'
CLOSED_ROWS=$(query "SELECT task_id, landing, train_pr_number FROM task_ci WHERE task_id IN ('970-closed', '971-done-row', '972-orphan') ORDER BY task_id")
[ "$CLOSED_ROWS" = '970-closed|train:60|60
971-done-row|train:60|60
972-orphan|closed|NULL' ] \
  || fail "closed member PRs did not resolve their train from the closing comment or Done row: $CLOSED_ROWS"
pass 'a member PR closed by a train names the train from its closing comment or its Done row'

CI_REPORT=$("$STORE" report --sync) || fail 'CI report failed'
assert_contains "$CI_REPORT" '| CI' 'the cross-task header should carry the CI column'
CI_LINE=$(printf '%s\n' "$CI_REPORT" | grep '^950-direct ')
assert_contains "$CI_LINE" '| 30.0 runner min / 5.0 queue min / 2 runs (1 cancelled, 0 failed) / direct / 1.30 min per card' \
  'the cross-task row should show CI minutes, queue minutes, runs, landing, and minutes per landed card'
NO_CI_LINE=$(printf '%s\n' "$CI_REPORT" | grep '^940-tools ')
[ "${NO_CI_LINE##* | }" = '-' ] || fail "a task without a ledger should print a dash in the CI column: $NO_CI_LINE"
assert_contains "$CI_REPORT" 'CI direct 1 PRs | 30.0 runner min | 5.0 queue min | 23 cards claimed | 1.30 min per card' \
  'the report should total directly landed PRs per landed card'
assert_contains "$CI_REPORT" 'CI train 1 trains / 4 members | 86.0 runner min (trains 38.0 + members 48.0) | 7.0 queue min | 18 cards claimed | 4.78 min per card' \
  'the report should total train-landed PRs per landed card'
assert_contains "$CI_REPORT" 'TRAIN #60 960-train | 2 members (0 ejected) | 2 fix rounds | train 38.0 runner min | members 48.0 runner min (4 ledgers) | 18 cards claimed | 4.78 min per card' \
  'each train should report its members, fix rounds, and minutes per landed card'
TRAIN_REPORT=$("$STORE" report 960-train) || fail 'train task report failed'
assert_contains "$TRAIN_REPORT" 'CI runs 2 | cancelled 0 | failed 1 | succeeded 1 | runner 38.0 min | queue 3.0 min | first run 2026-06-02T10:05:00Z | last completed 2026-06-02T11:30:00Z | landing direct | cards claimed -' \
  'the per-task report should list the CI ledger'
assert_contains "$TRAIN_REPORT" 'TRAIN members 2 | ejected 0 | fix rounds 2' 'the per-task report should list the train shape'
NO_CI_REPORT=$("$STORE" report 940-tools) || fail 'no-ledger task report failed'
assert_contains "$NO_CI_REPORT" 'CI unavailable' 'a task without a ledger should say so in the per-task report'
pass 'reports expose CI minutes and queue minutes per task and per landed card'

for self_task in 973-self-comment:73 974-own-then-train:74 975-self-row:75 976-self-only-row:76; do
  "$STORE" capture-ci "${self_task%%:*}" "https://github.com/example/repo/pull/${self_task##*:}" >/dev/null 2>&1 \
    || fail "self-mentioning closed capture failed for ${self_task%%:*}"
done
SELF_ROWS=$(query "SELECT task_id, landing, train_pr_number FROM task_ci WHERE task_id LIKE '97_-self%' OR task_id = '974-own-then-train' ORDER BY task_id")
[ "$SELF_ROWS" = '973-self-comment|closed|NULL
974-own-then-train|train:60|60
975-self-row|train:60|60
976-self-only-row|closed|NULL' ] \
  || fail "a closed PR resolved its own number as its train: $SELF_ROWS"
[ "$(query "SELECT count(*) FROM task_ci WHERE train_pr_number = pr_number")" = 0 ] \
  || fail 'no ledger may name its own PR as its train'
pass 'train resolution skips the PR itself in closing comments and Done rows'

: > "$FORGE/calls.log"
DEAD_OUT=$("$STORE" capture-ci 961-dead-train https://github.com/example/repo/pull/61 2>&1) || fail "unmerged train capture failed: $DEAD_OUT"
assert_contains "$DEAD_OUT" 'member not captured 956-ghost-a: train #61 did not merge' 'an unmerged train should report each member as not captured'
assert_contains "$DEAD_OUT" 'member not captured 957-ghost-b: train #61 did not merge' 'an unmerged train should report every member'
assert_absent "$FM_HOME/data/pr-ci/956-ghost-a.json" 'an unmerged train must not write a member ledger'
assert_absent "$FM_HOME/data/pr-ci/957-ghost-b.json" 'an unmerged train must not write any member ledger'
assert_no_grep 'pulls/56' "$FORGE/calls.log" 'an unmerged train must not read its members from the forge'
[ "$(query "SELECT landing, is_train, member_count FROM task_ci WHERE task_id = '961-dead-train'")" = 'closed|1|2' ] \
  || fail 'an unmerged train still records its own ledger as closed'
[ "$(query "SELECT count(*) FROM task_ci WHERE landing = 'train:61'")" = 0 ] \
  || fail 'no ledger may land through a train that did not merge'
pass 'an unmerged train records its own ledger and lands no member through it'

"$STORE" capture-ci 977-relaunched https://github.com/example/repo/pull/77 >/dev/null 2>&1 || fail 'first-PR capture failed'
[ "$(query "SELECT pr_number, landing FROM task_ci WHERE task_id = '977-relaunched'")" = '77|closed' ] \
  || fail 'the relaunched card should first carry its closed PR'
RELAUNCH_OUT=$("$STORE" capture-ci 977-relaunched https://github.com/example/repo/pull/91 --from merge 2>&1) || fail "relaunched capture failed: $RELAUNCH_OUT"
assert_contains "$RELAUNCH_OUT" 'captured run ledger for 977-relaunched' 'a ledger for an earlier PR must be rebuilt, not kept'
assert_not_contains "$RELAUNCH_OUT" 'kept existing' 'a ledger for an earlier PR is not this landing record'
[ "$(query "SELECT pr_number, landing, captured_from FROM task_ci WHERE task_id = '977-relaunched'")" = '91|direct|merge' ] \
  || fail 'the merged PR of a relaunched card must replace the ledger of its closed predecessor'
[ "$(query "SELECT status FROM task_source WHERE task_id = '977-relaunched' AND source = 'ci'")" = present ] \
  || fail 'the rebuilt ledger should join the task'
[ "$(query "SELECT count(*) FROM ingest_issue WHERE task_id = '977-relaunched' AND kind = 'ci-pr-identity'")" = 0 ] \
  || fail 'a rebuilt ledger must not leave a stale identity issue'
pass 'an existing ledger is kept only for the same task and PR'

: > "$FORGE/calls.log"
"$STORE" capture-ci 978-paged https://github.com/example/repo/pull/92 >/dev/null 2>&1 || fail 'paged capture failed'
[ "$(query "SELECT runs, runner_seconds FROM task_ci WHERE task_id = '978-paged'")" = '3|1620' ] \
  || fail 'a run repeated across listing pages must count once'
[ "$(query "SELECT count(*) FROM task_ci_run WHERE task_id = '978-paged'")" = 3 ] \
  || fail 'a run repeated across listing pages must be recorded once'
[ "$(grep -c 'runs/5002/jobs' "$FORGE/calls.log")" = 1 ] || fail 'a repeated run must have its jobs read once'
node - "$FM_HOME/data/pr-ci" <<'NODE'
const fs = require('fs')
const path = require('path')
const dir = process.argv[2]
const ledger = JSON.parse(fs.readFileSync(path.join(dir, '978-paged.json'), 'utf8'))
const repeated = {...ledger, task_id: '979-repeated', pr_url: 'https://github.com/example/repo/pull/93', pr_number: 93, runs: [ledger.runs[0], ledger.runs[0]]}
fs.writeFileSync(path.join(dir, '979-repeated.json'), `${JSON.stringify(repeated)}\n`)
NODE
"$STORE" rebuild >/dev/null 2>&1 || fail 'a ledger that repeats a run id must not stop the rebuild'
[ "$(query "SELECT status FROM task_source WHERE task_id = '979-repeated' AND source = 'ci'")" = missing ] \
  || fail 'a ledger that repeats a run id must leave the ci source missing'
[ "$(query "SELECT kind FROM ingest_issue WHERE task_id = '979-repeated'")" = ci-ledger-invalid ] \
  || fail 'a ledger that repeats a run id must be surfaced as an invalid ledger'
[ "$(query "SELECT count(*) FROM task_ci_run WHERE task_id = '979-repeated'")" = 0 ] \
  || fail 'an invalid ledger must record no runs'
rm -f "$FM_HOME/data/pr-ci/979-repeated.json"
pass 'a repeated run id is recorded once from the forge and invalidates a stored ledger without breaking rebuild'

"$STORE" capture-ci 958-relaunched-member https://github.com/example/repo/pull/78 >/dev/null 2>&1 || fail 'closed first-PR member capture failed'
[ "$(query "SELECT pr_number, landing FROM task_ci WHERE task_id = '958-relaunched-member'")" = '78|closed' ] \
  || fail 'the relaunched member should first carry its closed PR'
TRAIN_TWO_OUT=$("$STORE" capture-ci 962-train-two https://github.com/example/repo/pull/62 2>&1) || fail "second train capture failed: $TRAIN_TWO_OUT"
assert_contains "$TRAIN_TWO_OUT" 'captured run ledger for 962-train-two, 958-relaunched-member' \
  'a member ledger for an earlier PR must be rebuilt for the manifest PR'
[ "$(query "SELECT pr_number, landing, captured_from FROM task_ci WHERE task_id = '958-relaunched-member'")" = '58|train:62|train-manifest' ] \
  || fail 'the manifest path must replace a member ledger that records a different PR'
REPEAT_TRAIN_OUT=$("$STORE" capture-ci 962-train-two https://github.com/example/repo/pull/62 2>&1) || fail "repeated second train capture failed: $REPEAT_TRAIN_OUT"
assert_contains "$REPEAT_TRAIN_OUT" 'kept existing member ledgers: 958-relaunched-member' \
  'a member ledger for the manifest PR is kept on a repeated capture'
pass 'the manifest path keeps a member ledger only for the same task and PR'

CI_FINGERPRINT=$("$STORE" fingerprint) || fail 'fingerprint after CI capture failed'
rm -f "$DB"
: > "$FORGE/calls.log"
"$STORE" rebuild >/dev/null || fail 'rebuild after CI capture failed'
[ "$("$STORE" fingerprint)" = "$CI_FINGERPRINT" ] || fail 'rebuild must reproduce the CI tables from the durable ledgers alone'
[ ! -s "$FORGE/calls.log" ] || fail 'rebuild must never consult the forge'
pass 'the CI ledger is durable evidence and rebuild never reaches the forge'

"$STORE" annotate 950-direct --pr-url https://github.com/example/repo/pull/44 >/dev/null \
  || fail 'annotating a different PR failed'
"$STORE" rebuild >/dev/null || fail 'rebuild with a mismatched ledger failed'
[ "$(query "SELECT status FROM task_source WHERE task_id = '950-direct' AND source = 'ci'")" = missing ] \
  || fail 'a ledger for another PR must not be joined to the task'
[ "$(query "SELECT kind FROM ingest_issue WHERE task_id = '950-direct' AND kind = 'ci-pr-identity'")" = ci-pr-identity ] \
  || fail 'a mismatched ledger should be surfaced as an ingest issue'
"$STORE" annotate 950-direct --pr-url https://github.com/example/repo/pull/42 >/dev/null \
  || fail 'restoring the PR annotation failed'
pass 'a ledger bound to a different PR is missing, never silently joined'

write_receipt() {  # <task-id> <pr-number> <phase>
  printf '%s\n' 'schema=fm-pr-merge.v4' "task_id=$1" "pr=https://github.com/example/repo/pull/$2" \
    'repository=example/repo' "project=$PROJECT" 'default_branch=main' \
    "merge_commit=$(printf 'c%.0s' $(seq 1 40))" 'spawned_at=2026-06-01T10:00:00Z' "phase=$3" \
    'authorization=live-meta' 'prepared_epoch=1780000000' 'merged_at=2026-06-01T11:00:00Z' \
    > "$FM_HOME/data/pr-merges/$1.receipt"
}
write_receipt 950-direct 42 merged
write_receipt 953-backfill 53 merged
write_receipt 954-prepared 54 prepared
write_receipt 955-vanished 55 merged
BACKFILL_OUT=$("$STORE" backfill-ci 2>&1) || fail "CI backfill failed: $BACKFILL_OUT"
assert_contains "$BACKFILL_OUT" 'captured 1 | skipped 1 existing | skipped 1 not landed | failed 3' \
  'the backfill should report what it captured, skipped, and could not read (two earlier receipts have no stubbed PR)'
assert_contains "$BACKFILL_OUT" '955-vanished' 'a receipt whose PR the forge cannot serve should be named'
[ "$(query "SELECT landing, runs, captured_from FROM task_ci WHERE task_id = '953-backfill'")" = 'direct|0|backfill' ] \
  || fail 'the backfill should capture a landed receipt with no ledger'
[ "$(query "SELECT cards_moved_claimed FROM task WHERE task_id = '953-backfill'")" = 4 ] \
  || fail 'a ledger-only task should still surface its card claim'
[ "$(query "SELECT captured_from FROM task_ci WHERE task_id = '950-direct'")" = manual ] \
  || fail 'the backfill must not replace an existing ledger by default'
REPEAT_OUT=$("$STORE" backfill-ci 2>&1) || fail "repeated CI backfill failed: $REPEAT_OUT"
assert_contains "$REPEAT_OUT" 'captured 0 | skipped 2 existing' 'a repeated backfill should be a no-op for captured ledgers'
"$STORE" backfill-ci --replace-existing >/dev/null 2>&1 || fail 'replacing CI backfill failed'
[ "$(query "SELECT captured_from FROM task_ci WHERE task_id = '950-direct'")" = backfill ] \
  || fail '--replace-existing should recapture an existing ledger'
pass 'the one-time backfill captures landed receipts idempotently and names what it could not read'

# The train has landed member a, whose PR the forge now shows closed with the
# train named in its closing comment.
node - "$FORGE" <<'NODE'
const fs = require('fs')
const path = require('path')
const dir = process.argv[2]
const file = path.join(dir, 'pull-51.json')
const pr = JSON.parse(fs.readFileSync(file, 'utf8'))
fs.writeFileSync(file, `${JSON.stringify({...pr, state: 'closed', closed_at: '2026-06-02T12:00:00Z'})}\n`)
fs.writeFileSync(path.join(dir, 'comments-51.json'), `${JSON.stringify([[{id: 1, body: 'Superseded: landed through train #60; closing.'}]])}\n`)
NODE
KEPT_OUT=$("$STORE" capture-ci 951-member-a https://github.com/example/repo/pull/51 2>&1) || fail "repeated member capture failed: $KEPT_OUT"
assert_contains "$KEPT_OUT" 'kept existing run ledger for 951-member-a' 'capture-ci should say it kept the existing ledger'
[ "$(query "SELECT captured_from FROM task_ci WHERE task_id = '951-member-a'")" = train-manifest ] \
  || fail 'capture-ci must keep an existing ledger without --replace-existing'
"$STORE" capture-ci 951-member-a https://github.com/example/repo/pull/51 --replace-existing >/dev/null 2>&1 \
  || fail 'replacing member capture failed'
[ "$(query "SELECT landing, captured_from FROM task_ci WHERE task_id = '951-member-a'")" = 'train:60|manual' ] \
  || fail 'capture-ci --replace-existing should recapture the named task from its own PR'
write_receipt 960-train 60 merged
"$STORE" backfill-ci --replace-existing >/dev/null 2>&1 || fail 'replacing train backfill failed'
[ "$(query "SELECT captured_from FROM task_ci WHERE task_id = '960-train'")" = backfill ] \
  || fail '--replace-existing should recapture the train receipt itself'
MEMBER_SOURCES=$(query "SELECT task_id, captured_from FROM task_ci WHERE task_id IN ('951-member-a', '952-member-b') ORDER BY task_id")
[ "$MEMBER_SOURCES" = '951-member-a|manual
952-member-b|train-manifest' ] \
  || fail "the train's manifest replaced an existing member ledger under --replace-existing: $MEMBER_SOURCES"
"$STORE" capture-ci 960-train https://github.com/example/repo/pull/60 --replace-existing >/dev/null 2>&1 \
  || fail 'replacing train capture failed'
[ "$(query "SELECT task_id, captured_from FROM task_ci WHERE task_id IN ('951-member-a', '952-member-b') ORDER BY task_id")" = "$MEMBER_SOURCES" ] \
  || fail 'capture-ci --replace-existing on a train must leave member ledgers alone'
pass '--replace-existing recaptures the named ledger and never a manifest member'
