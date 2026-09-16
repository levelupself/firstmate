#!/usr/bin/env bash
# Deferred ingestion must coalesce requests and keep pending tasks visible.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-effort-async)
export FM_HOME="$TMP_ROOT/home"
STATE="$FM_HOME/state"
mkdir -p "$STATE" "$FM_HOME/data"
STORE="$ROOT/bin/fm-effort-store.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REAL_NODE=$(command -v node)
export REAL_NODE
export REBUILD_LOG="$TMP_ROOT/rebuilds"
cat > "$FAKEBIN/node" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" = */fm-effort-store.mjs ]] && [ "${2:-}" = ingest ]; then
  printf 'ingest\n' >> "$REBUILD_LOG"
fi
exec "$REAL_NODE" "$@"
MOCK
chmod +x "$FAKEBIN/node"
export PATH="$FAKEBIN:$PATH"
fm_lock_try_acquire "$STATE/.effort-store.lock" || fail 'cannot stall ingestion'
for task in one two three; do
  fm_write_meta "$STATE/$task.meta" "spawned_at=2026-09-14T10:00:00Z" "kind=ship"
  timeout 5 "$STORE" capture "$task" >/dev/null || {
    fm_lock_release "$STATE/.effort-store.lock"
    fail 'capture waited on derived ingestion'
  }
done
report=$(timeout 5 "$STORE" report three) || fail 'pending report blocked or hid the task'
assert_contains "$report" 'three' 'pending task was absent'
assert_contains "$report" 'pending ingestion' 'pending task appeared measured'
fm_lock_release "$STATE/.effort-store.lock"
"$STORE" report --sync >/dev/null || fail 'sync did not drain requests'
[ "$(wc -l < "$REBUILD_LOG" | tr -d ' ')" = 1 ] || fail 'three requests did not coalesce into one ingest'
pass 'three captures coalesce into one ingest and pending tasks remain visible'

# Warm ingestion must not walk unchanged file history again. A cache deletion
# must remain recoverable without changing the rename-aware logical result.
fm_git_identity
PROJECT="$TMP_ROOT/project"
git init -q -b main "$PROJECT"
printf 'one\n' > "$PROJECT/file.txt"
git -C "$PROJECT" add file.txt
git -C "$PROJECT" commit -qm 'introduce [one]'
printf 'two\n' >> "$PROJECT/file.txt"
git -C "$PROJECT" add file.txt
git -C "$PROJECT" commit -qm 'extend [two]'
REAL_GIT=$(command -v git)
export REAL_GIT
export HISTORY_LOG="$TMP_ROOT/history"
cat > "$FAKEBIN/git" <<'MOCK'
#!/usr/bin/env bash
case " $* " in
  *' --follow '*) printf 'follow\n' >> "$HISTORY_LOG" ;;
esac
exec "$REAL_GIT" "$@"
MOCK
chmod +x "$FAKEBIN/git"
for task in one two; do
  printf 'project=%s\n' "$PROJECT" >> "$STATE/$task.meta"
  "$STORE" capture "$task" >/dev/null || fail 'history fixture capture failed'
done
"$STORE" report --sync >/dev/null || fail 'history fixture ingestion failed'
first=$("$STORE" fingerprint)
walks=$(wc -l < "$HISTORY_LOG")
[ "$walks" -gt 0 ] || fail 'history fixture did not exercise rename-following history'
"$STORE" enqueue || fail 'warm enqueue failed'
"$STORE" report --sync >/dev/null || fail 'warm ingestion failed'
[ "$(wc -l < "$HISTORY_LOG")" = "$walks" ] || fail 'warm ingestion walked unchanged file history'
[ "$("$STORE" fingerprint)" = "$first" ] || fail 'cached ingestion changed logical content'
rm -rf "$STATE/effort-git-cache"
"$STORE" enqueue || fail 'cold enqueue failed'
"$STORE" report --sync >/dev/null || fail 'cache recreation failed'
[ "$(wc -l < "$HISTORY_LOG")" -gt "$walks" ] || fail 'absent inventory cache was not rebuilt'
[ "$("$STORE" fingerprint)" = "$first" ] || fail 'cache deletion changed logical content'
pass 'commit inventory cache avoids repeated history walks and is safe to delete'
