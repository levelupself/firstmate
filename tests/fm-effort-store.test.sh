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
  node "$QUERY" "$DB" "$1"
}

# --- annotations ------------------------------------------------------------

"$STORE" annotate 901-introduce-memory \
  --failure-mode quietly \
  --round 1:discovery \
  --round '2:churn:the acceptance list changed' \
  --findings 5 --review-rounds 2 --ask-user 1 --gate-failures 0 \
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
printf '%s\n' '{"task":"905-modify-memory","pr_opened_at":"2026-03-01T00:30:00Z"}' \
  >> "$FM_HOME/data/effort-annotations.jsonl"

# --- rebuild ----------------------------------------------------------------

REBUILD_OUT=$("$STORE" rebuild 2>&1) || fail "rebuild failed: $REBUILD_OUT"
assert_contains "$REBUILD_OUT" 'rebuilt 9 tasks' 'rebuild should report every task it discovered'
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

# --- nothing is silently dropped -------------------------------------------

LEGACY=$(query "SELECT kind, detail FROM ingest_issue WHERE source = 'raw' ORDER BY ordinal")
assert_contains "$LEGACY" 'unparsed-legacy-line' 'raw lines outside the v2 section must be recorded, not dropped'
assert_contains "$LEGACY" 'hand-written-row' 'the hand-written row itself must be recoverable from the store'
COUNT=$(query "SELECT COUNT(*) FROM task WHERE task_id = 'hand-written-row'")
[ "$COUNT" = '0' ] || fail 'a row whose schema is unknown must not be guessed into a task record'
pass 'raw lines with an unknown schema are surfaced as issues rather than dropped or guessed'

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
assert_present "$DB" 'a lifecycle capture should create the store automatically'
LIFECYCLE=$(query "SELECT launch_to_pr_seconds, tokens_in, tokens_out, notional_cost_usd, pr_opened_at, merged_at, teardown_at, outcome FROM task WHERE task_id = '910-lifecycle'")
[ "$LIFECYCLE" = '900|321|45|1.25|2026-06-01T10:15:00Z|2026-06-01T11:00:00Z|2026-06-01T11:05:00Z|pr-merged' ] \
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
[ "$RECEIPT_OUTCOME" = '1|pr-merged' ] \
  || fail "a durable sanctioned merge receipt did not supply merge lifecycle proof: $RECEIPT_OUTCOME"
pass 'durable merge receipt supplies missing merge lifecycle proof'

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

CAPTURE_FINGERPRINT=$("$STORE" fingerprint)
CAPTURE_RAW_SIZE=$(wc -c < "$RAW")
"$STORE" capture 910-lifecycle --outcome pr-merged >/dev/null \
  || fail 'repeating an identical lifecycle capture failed'
[ "$("$STORE" fingerprint)" = "$CAPTURE_FINGERPRINT" ] \
  || fail 'an idempotent lifecycle retry changed the logical store'
[ "$(wc -c < "$RAW")" -eq "$CAPTURE_RAW_SIZE" ] \
  || fail 'an idempotent lifecycle retry appended a duplicate raw row'
rm -f "$DB"
"$STORE" rebuild >/dev/null || fail 'durable-record rebuild after lifecycle capture failed'
[ "$("$STORE" fingerprint)" = "$CAPTURE_FINGERPRINT" ] \
  || fail 'delete-and-rebuild lost lifecycle fields or usage'
pass 'lifecycle capture is idempotent and delete-and-rebuild reproduces it'

REPORT=$("$STORE" report 910-lifecycle) || fail 'single-task report failed'
assert_contains "$REPORT" '910-lifecycle' 'report should identify the task'
assert_contains "$REPORT" '15m 0s' 'report should surface launch-to-PR duration'
# shellcheck disable=SC2016 # Literal currency amount, not shell expansion.
assert_contains "$REPORT" '$1.2500' 'report should surface cost'
assert_contains "$REPORT" '321 in / 45 out' 'report should surface tokens'
assert_contains "$REPORT" 'gpt-5.6-sol' 'report should surface the actual model'
ALL_REPORT=$("$STORE" report) || fail 'cross-task report failed'
assert_contains "$ALL_REPORT" 'TOTAL' 'cross-task report should include aggregate totals'

USAGE=$("$STORE" --help)
assert_contains "$USAGE" 'report [<task-id>]' 'help should document the one reporting command'
pass 'one documented report command answers per-task and cross-task effort'
