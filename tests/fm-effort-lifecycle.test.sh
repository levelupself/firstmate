#!/usr/bin/env bash
# Behavior tests for deterministic effort timestamps at sanctioned lifecycle edges.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
LOCAL_MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-effort-lifecycle)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_ROOT="$TMP_ROOT/root"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$TMP_ROOT/wt" "$FAKE_ROOT/bin"
for helper in "$ROOT"/bin/*; do
  ln -s "$helper" "$FAKE_ROOT/bin/${helper##*/}"
done
rm -f "$FAKE_ROOT/bin/fm-guard.sh"
cat > "$FAKE_ROOT/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_ROOT/bin/fm-guard.sh"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '%s\n' 0123456789abcdef0123456789abcdef01234567 ;;
  *" createdAt "*) printf '%s\n' 2026-08-29T10:15:00Z ;;
esac
SH
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  printf '%s\n' \
    'merged: true' \
    'merged_at: "2026-08-29T10:20:00Z"'
fi
exit 0
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/gh-axi"

NM_DB="$TMP_ROOT/no-mistakes.sqlite"
node --no-warnings - "$NM_DB" "$TMP_ROOT/project" <<'NODE'
const {DatabaseSync} = require('node:sqlite')
const db = new DatabaseSync(process.argv[2])
const project = process.argv[3]
db.exec(`
  CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL);
  CREATE TABLE runs (
    id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
    pr_url TEXT, status TEXT NOT NULL, created_at INTEGER NOT NULL
  );
  CREATE TABLE step_results (
    id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
    status TEXT NOT NULL
  );
  CREATE TABLE step_rounds (
    id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL,
    trigger_type TEXT NOT NULL, findings_json TEXT
  );
`)
db.prepare('INSERT INTO repos VALUES (?, ?)').run('repo-1', project)
db.prepare('INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)').run(
  'run-1', 'repo-1', 'fm/pr-task', 'https://github.com/example/repo/pull/9', 'running', 1,
)
const step = db.prepare('INSERT INTO step_results VALUES (?, ?, ?, ?)')
for (const [id, name, status] of [
  ['rebase', 'rebase', 'completed'],
  ['review', 'review', 'completed'],
  ['test', 'test', 'completed'],
  ['document', 'document', 'completed'],
  ['lint', 'lint', 'completed'],
  ['ci', 'ci', 'running'],
]) step.run(id, 'run-1', name, status)
const round = db.prepare('INSERT INTO step_rounds VALUES (?, ?, ?, ?, ?)')
round.run('review-1', 'review', 1, 'initial', JSON.stringify({findings: [
  {id: 'r1', action: 'ask-user'},
  {id: 'r2', action: 'auto-fix'},
]}))
round.run('review-2', 'review', 2, 'auto_fix', JSON.stringify({findings: []}))
round.run('test-1', 'test', 1, 'initial', JSON.stringify({findings: [
  {id: 't1', action: 'auto-fix'},
]}))
round.run('test-2', 'test', 2, 'auto_fix', JSON.stringify({findings: []}))
db.close()
NODE

fm_write_meta "$HOME_DIR/state/pr-task.meta" \
  'window=fm-pr-task' \
  'endpoint_task_id=pr-task' \
  "worktree=$TMP_ROOT/wt" \
  "project=$TMP_ROOT/project" \
  'harness=codex' \
  'model=configured-gpt' \
  'effort=xhigh' \
  'kind=ship' \
  'mode=no-mistakes' \
  'spawned_at=2026-08-29T10:00:00Z'

run_pr_check() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
    "$PR_CHECK" pr-task https://github.com/example/repo/pull/9
}

run_pr_check >"$TMP_ROOT/pr-check.out" 2>"$TMP_ROOT/pr-check.err" \
  || fail "PR check failed: $(tr '\n' ' ' < "$TMP_ROOT/pr-check.err")"
OPENED_AT=$(sed -n 's/^pr_opened_at=//p' "$HOME_DIR/state/pr-task.meta")
[ "$OPENED_AT" = 2026-08-29T10:15:00Z ] || fail 'PR check did not preserve forge pr_opened_at'
DB="$HOME_DIR/data/effort-store.sqlite"
ACTIVE_ROW=$(node - "$DB" <<'NODE'
process.emitWarning = () => {}
const {DatabaseSync} = require("node:sqlite")
const row = new DatabaseSync(process.argv[2], {readOnly:true}).prepare("SELECT launch_to_pr_seconds, teardown_at FROM task WHERE task_id = ?").get("pr-task")
process.stdout.write(`${row?.launch_to_pr_seconds}|${row?.teardown_at ?? "NULL"}\n`)
NODE
)
[ "$ACTIVE_ROW" = '900|NULL' ] || fail "active PR task did not populate a partial effort row: $ACTIVE_ROW"
pass 'active PR lifecycle populates the effort store before teardown'
run_pr_check >"$TMP_ROOT/pr-check-repeat.out" 2>"$TMP_ROOT/pr-check-repeat.err" \
  || fail "repeated PR check failed: $(tr '\n' ' ' < "$TMP_ROOT/pr-check-repeat.err")"
[ "$(sed -n 's/^pr_opened_at=//p' "$HOME_DIR/state/pr-task.meta")" = "$OPENED_AT" ] \
  || fail 'repeated PR check changed the original pr_opened_at stamp'
pass 'PR check stamps PR-open time once and preserves it on retry'

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  FM_NO_MISTAKES_STATE_DB_OVERRIDE="$NM_DB" \
  "$PR_MERGE" pr-task https://github.com/example/repo/pull/9 >/dev/null \
  || fail 'PR merge failed'
grep -qx 'merged_at=2026-08-29T10:20:00Z' "$HOME_DIR/state/pr-task.meta" \
  || fail 'PR merge did not stamp the forge merge time'
grep -qx 'outcome=pr-merged' "$HOME_DIR/state/pr-task.meta" \
  || fail 'PR merge did not stamp its lifecycle outcome'
MERGED_ROW=$(node - "$DB" <<'NODE'
process.emitWarning = () => {}
const {DatabaseSync} = require('node:sqlite')
const row = new DatabaseSync(process.argv[2], {readOnly:true}).prepare(`
  SELECT merged_at, outcome, findings, review_rounds, ask_user_count, gate_failures
  FROM task WHERE task_id = ?
`).get('pr-task')
process.stdout.write(Object.values(row || {}).map(value => value ?? 'NULL').join('|') + '\n')
NODE
)
[ "$MERGED_ROW" = '2026-08-29T10:20:00Z|merged|NULL|NULL|NULL|NULL' ] \
  || fail "unsettled pipeline produced process counts: $MERGED_ROW"
pass 'sanctioned PR merge preserves missing process cost for an unsettled run'

node --no-warnings - "$NM_DB" <<'NODE'
const {DatabaseSync} = require('node:sqlite')
const db = new DatabaseSync(process.argv[2])
db.prepare("UPDATE step_results SET status = 'completed' WHERE id = 'ci'").run()
db.prepare("UPDATE step_rounds SET findings_json = NULL WHERE id = 'review-2'").run()
db.close()
NODE
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  FM_NO_MISTAKES_STATE_DB_OVERRIDE="$NM_DB" \
  "$PR_MERGE" pr-task https://github.com/example/repo/pull/9 >/dev/null \
  || fail 'repeated PR merge with incomplete findings failed'
INCOMPLETE_ROW=$(node - "$DB" <<'NODE'
process.emitWarning = () => {}
const {DatabaseSync} = require('node:sqlite')
const row = new DatabaseSync(process.argv[2], {readOnly:true}).prepare(`
  SELECT findings, review_rounds, ask_user_count, gate_failures
  FROM task WHERE task_id = ?
`).get('pr-task')
process.stdout.write(Object.values(row || {}).map(value => value ?? 'NULL').join('|') + '\n')
NODE
)
[ "$INCOMPLETE_ROW" = 'NULL|NULL|NULL|NULL' ] \
  || fail "incomplete findings record produced process counts: $INCOMPLETE_ROW"
pass 'sanctioned PR merge preserves missing process cost for incomplete findings'

node --no-warnings - "$NM_DB" <<'NODE'
const {DatabaseSync} = require('node:sqlite')
const db = new DatabaseSync(process.argv[2])
db.prepare('UPDATE step_rounds SET findings_json = ? WHERE id = ?').run(
  JSON.stringify({findings: []}), 'review-2',
)
db.close()
NODE
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  FM_NO_MISTAKES_STATE_DB_OVERRIDE="$NM_DB" \
  "$PR_MERGE" pr-task https://github.com/example/repo/pull/9 >/dev/null \
  || fail 'repeated PR merge with settled pipeline failed'
MERGED_ROW=$(node - "$DB" <<'NODE'
process.emitWarning = () => {}
const {DatabaseSync} = require('node:sqlite')
const row = new DatabaseSync(process.argv[2], {readOnly:true}).prepare(`
  SELECT merged_at, outcome, findings, review_rounds, ask_user_count, gate_failures
  FROM task WHERE task_id = ?
`).get('pr-task')
process.stdout.write(Object.values(row || {}).map(value => value ?? 'NULL').join('|') + '\n')
NODE
)
[ "$MERGED_ROW" = '2026-08-29T10:20:00Z|merged|3|2|1|1' ] \
  || fail "PR merge did not capture forge and pipeline facts: $MERGED_ROW"
pass 'sanctioned PR merge stamps forge time, merged outcome, and structured pipeline cost'
grep -qx 'schema=fm-pr-merge.v2' "$HOME_DIR/data/pr-merges/pr-task.receipt" \
  || fail 'PR merge did not write the forge-timestamp receipt schema'
grep -qx 'merged_at=2026-08-29T10:20:00Z' "$HOME_DIR/data/pr-merges/pr-task.receipt" \
  || fail 'PR merge receipt did not preserve the forge timestamp'

fm_write_meta "$HOME_DIR/state/torn-task.meta" \
  'window=fm-torn-task' \
  'endpoint_task_id=torn-task' \
  "worktree=$TMP_ROOT/torn-wt" \
  "project=$TMP_ROOT/project" \
  'harness=codex' \
  'kind=ship' \
  'mode=no-mistakes' \
  'spawned_at=2026-08-29T10:00:00Z'
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  "$PR_CHECK" torn-task https://github.com/example/repo/pull/10 >/dev/null \
  || fail 'torn task PR check failed'
fm_write_meta "$HOME_DIR/data/pr-merges/torn-task.receipt" \
  'schema=fm-pr-merge.v2' \
  'task_id=torn-task' \
  'pr=https://github.com/example/repo/pull/10' \
  'spawned_at=2026-08-29T10:00:00Z' \
  'phase=prepared' \
  'authorization=live-meta' \
  'prepared_epoch=1788040000' \
  'merged_at='
rm "$HOME_DIR/state/torn-task.meta"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  FM_NO_MISTAKES_STATE_DB_OVERRIDE="$NM_DB" \
  "$PR_MERGE" torn-task https://github.com/example/repo/pull/10 >/dev/null \
  || fail 'torn task PR merge failed'
TORN_ROW=$(node - "$DB" <<'NODE'
process.emitWarning = () => {}
const {DatabaseSync} = require('node:sqlite')
const row = new DatabaseSync(process.argv[2], {readOnly:true}).prepare(`
  SELECT merged_at, outcome FROM task WHERE task_id = ?
`).get('torn-task')
process.stdout.write(Object.values(row || {}).map(value => value ?? 'NULL').join('|') + '\n')
NODE
)
[ "$TORN_ROW" = '2026-08-29T10:20:00Z|merged' ] \
  || fail "merge after metadata teardown did not enrich the prior row: $TORN_ROW"
pass 'sanctioned merge enriches a prior raw row after volatile task metadata is gone'

MERGED_FINGERPRINT=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-effort-store.sh" fingerprint)
rm -f "$NM_DB" "$DB"
FM_HOME="$HOME_DIR" FM_NO_MISTAKES_STATE_DB_OVERRIDE="$NM_DB" \
  "$ROOT/bin/fm-effort-store.sh" rebuild >/dev/null || fail 'merged effort replay failed'
[ "$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-effort-store.sh" fingerprint)" = "$MERGED_FINGERPRINT" ] \
  || fail 'merged effort replay changed after the pipeline database disappeared'
REPLAYED_PROCESS=$(node - "$DB" <<'NODE'
process.emitWarning = () => {}
const {DatabaseSync} = require('node:sqlite')
const row = new DatabaseSync(process.argv[2], {readOnly:true}).prepare(`
  SELECT findings, review_rounds, ask_user_count, gate_failures
  FROM task WHERE task_id = ?
`).get('pr-task')
process.stdout.write(Object.values(row || {}).join('|') + '\n')
NODE
)
[ "$REPLAYED_PROCESS" = '3|2|1|1' ] \
  || fail "merged effort replay lost process counts: $REPLAYED_PROCESS"
pass 'delete-and-rebuild replays process cost without the mutable pipeline database'

LOCAL_PROJECT="$TMP_ROOT/local-project"
git init -q -b main "$LOCAL_PROJECT"
git -C "$LOCAL_PROJECT" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m baseline
git -C "$LOCAL_PROJECT" branch fm/local-task
git -C "$LOCAL_PROJECT" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m local-work
git -C "$LOCAL_PROJECT" branch -f fm/local-task HEAD
git -C "$LOCAL_PROJECT" reset -q --hard HEAD^
fm_write_meta "$HOME_DIR/state/local-task.meta" \
  "worktree=$TMP_ROOT/local-wt" \
  "project=$LOCAL_PROJECT" \
  'kind=ship' \
  'mode=local-only' \
  'spawned_at=2026-08-29T10:00:00Z'
FAILBIN="$TMP_ROOT/failbin"
mkdir -p "$FAILBIN"
REAL_GIT=$(command -v git)
cat > "$FAILBIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${3:-}" = merge ] && [ "\${4:-}" = --ff-only ]; then
  exit 1
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$FAILBIN/git"
if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAILBIN:$FAKEBIN:$PATH" \
  "$LOCAL_MERGE" local-task >/dev/null 2>&1; then
  fail 'local merge unexpectedly succeeded through the failing merge boundary'
fi
PREPARED_TIME=$(sed -n 's/^event_at=//p' "$HOME_DIR/data/local-landings/local-task.receipt")
sleep 1
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  "$LOCAL_MERGE" local-task >/dev/null || fail 'local merge failed'
grep -Eq '^local_landed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  "$HOME_DIR/state/local-task.meta" || fail 'local merge did not stamp local_landed_at'
pass 'sanctioned local landing stamps its completion time'

RECEIPT="$HOME_DIR/data/local-landings/local-task.receipt"
grep -qx 'phase=landed' "$RECEIPT" || fail 'local merge did not complete its durable receipt'
RECEIPT_TIME=$(sed -n 's/^event_at=//p' "$RECEIPT")
[ "$RECEIPT_TIME" != "$PREPARED_TIME" ] \
  || fail 'successful local landing reused the failed preparation time'
[ "$(sed -n 's/^local_landed_at=//p' "$HOME_DIR/state/local-task.meta")" = "$RECEIPT_TIME" ] \
  || fail 'local metadata did not use the receipt event time'
sed -i '/^local_landed_at=/d' "$HOME_DIR/state/local-task.meta"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  "$LOCAL_MERGE" local-task >/dev/null || fail 'local merge retry failed'
[ "$(sed -n 's/^local_landed_at=//p' "$HOME_DIR/state/local-task.meta")" = "$RECEIPT_TIME" ] \
  || fail 'local merge retry changed the completed receipt event time'
pass 'local landing retry preserves completed receipt time'

fm_write_meta "$HOME_DIR/state/local-task.meta" \
  "worktree=$TMP_ROOT/local-wt" \
  "project=$LOCAL_PROJECT" \
  'kind=ship' \
  'mode=local-only' \
  'spawned_at=2026-08-30T10:00:00Z'
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  "$LOCAL_MERGE" local-task >/dev/null || fail 'reused local task merge failed'
[ -f "$HOME_DIR/data/local-landings/history/local-task.2026-08-29T10-00-00Z.receipt" ] \
  || fail 'reused local task did not retain its completed prior receipt'
[ "$(sed -n 's/^spawned_at=//p' "$RECEIPT")" = '2026-08-30T10:00:00Z' ] \
  || fail 'reused local task did not create current launch provenance'
pass 'reused local task rotates completed receipt history'

printf '# all fm-effort-lifecycle tests passed\n'
