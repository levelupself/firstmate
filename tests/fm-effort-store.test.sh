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
mkdir -p "$FM_HOME/data"

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

# --- rebuild ----------------------------------------------------------------

REBUILD_OUT=$("$STORE" rebuild 2>&1) || fail "rebuild failed: $REBUILD_OUT"
assert_contains "$REBUILD_OUT" 'rebuilt 8 tasks' 'rebuild should report every task it ingested'
assert_present "$DB" 'rebuild should create the store'
pass 'rebuild builds the store from the raw capture, codeburn, and git'

# --- the join ---------------------------------------------------------------

ROW=$(query "SELECT harness, effort, kind, files_changed, prod_src_files, distinct_areas, tokens_in, notional_cost_usd, wall_clock_seconds FROM task WHERE task_id = '901-introduce-memory'")
[ "$ROW" = 'claude|xhigh|ship|2|2|1|110|0.75|7200' ] \
  || fail "the three sources should join on one task row, got: $ROW"
pass 'ingestion joins raw dispatch, git structure, and codeburn effort on one task'

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
pass 'codeburn spend is windowed per task, so a pooled worktree is not double-counted'

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

# --- no reporting surface ---------------------------------------------------

USAGE=$("$STORE" --help)
assert_contains "$USAGE" 'rebuild' 'help should document rebuild'
assert_contains "$USAGE" 'annotate' 'help should document annotate'
for forbidden in report summary chart dashboard; do
  assert_not_contains "$USAGE" "  fm-effort-store.sh $forbidden" "the store must not grow a $forbidden command"
done
pass 'the store exposes ingestion and verification only, with no reporting surface'
