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
exit 0
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/gh-axi"

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
ACTIVE_ROW=$(node -e '
process.emitWarning = () => {}
const {DatabaseSync} = require("node:sqlite")
const row = new DatabaseSync(process.argv[1], {readOnly:true}).prepare("SELECT launch_to_pr_seconds, teardown_at FROM task WHERE task_id = ?").get("pr-task")
process.stdout.write(`${row?.launch_to_pr_seconds}|${row?.teardown_at ?? "NULL"}\n`)
' "$DB")
[ "$ACTIVE_ROW" = '900|NULL' ] || fail "active PR task did not populate a partial effort row: $ACTIVE_ROW"
pass 'active PR lifecycle populates the effort store before teardown'
run_pr_check >"$TMP_ROOT/pr-check-repeat.out" 2>"$TMP_ROOT/pr-check-repeat.err" \
  || fail "repeated PR check failed: $(tr '\n' ' ' < "$TMP_ROOT/pr-check-repeat.err")"
[ "$(sed -n 's/^pr_opened_at=//p' "$HOME_DIR/state/pr-task.meta")" = "$OPENED_AT" ] \
  || fail 'repeated PR check changed the original pr_opened_at stamp'
pass 'PR check stamps PR-open time once and preserves it on retry'

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  "$PR_MERGE" pr-task https://github.com/example/repo/pull/9 >/dev/null \
  || fail 'PR merge failed'
grep -Eq '^merged_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  "$HOME_DIR/state/pr-task.meta" || fail 'PR merge did not stamp merged_at'
pass 'sanctioned PR merge stamps merge time after success'

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
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  "$LOCAL_MERGE" local-task >/dev/null || fail 'local merge failed'
grep -Eq '^local_landed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  "$HOME_DIR/state/local-task.meta" || fail 'local merge did not stamp local_landed_at'
pass 'sanctioned local landing stamps its completion time'

RECEIPT="$HOME_DIR/data/local-landings/local-task.receipt"
grep -qx 'phase=landed' "$RECEIPT" || fail 'local merge did not complete its durable receipt'
RECEIPT_TIME=$(sed -n 's/^event_at=//p' "$RECEIPT")
[ "$(sed -n 's/^local_landed_at=//p' "$HOME_DIR/state/local-task.meta")" = "$RECEIPT_TIME" ] \
  || fail 'local metadata did not use the receipt event time'
sed -i '/^local_landed_at=/d' "$HOME_DIR/state/local-task.meta"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$FAKEBIN:$PATH" \
  "$LOCAL_MERGE" local-task >/dev/null || fail 'local merge retry failed'
[ "$(sed -n 's/^local_landed_at=//p' "$HOME_DIR/state/local-task.meta")" = "$RECEIPT_TIME" ] \
  || fail 'local merge retry changed the completed receipt event time'
pass 'local landing retry preserves completed receipt time'

printf '# all fm-effort-lifecycle tests passed\n'
