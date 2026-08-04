#!/usr/bin/env bash
# Behavior tests for the standalone Hunk review flow and one-word shell entry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
mkdir -p "$STATE" "$DATA"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf 'diff --git a/a b/a\n'
printf '%s\n' "$*" > "$FM_TEST_CURL_ARGS"
SH
cat > "$FAKEBIN/hunkdiff" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PATCH"
printf '%s\n' "$*" > "$FM_TEST_HUNK_ARGS"
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/hunkdiff"

run_review() {
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_TEST_CURL_ARGS="$TMP_ROOT/curl.args" FM_TEST_HUNK_ARGS="$TMP_ROOT/hunk.args" \
    FM_TEST_PATCH="$TMP_ROOT/patch" "$ROOT/bin/fm-review.sh" "$@"
}

assert_fails_with() {
  local expected=$1
  shift
  if out=$(run_review "$@" 2>&1); then
    fail "expected review failure for $*"
  fi
  assert_contains "$out" "$expected" "failure should explain $expected"
}

assert_fails_with "task does not exist: absent-task" absent-task
fm_write_meta "$STATE/no-pr.meta" "window=fm-no-pr"
assert_fails_with "task no-pr has no pr=" no-pr

fm_write_meta "$STATE/plain.meta" "pr=https://github.com/example/project/pull/17"
out=$(run_review plain)
assert_contains "$out" "GitHub" "review output should name the system of record"
assert_contains "$(cat "$TMP_ROOT/hunk.args")" "patch --agent-notes" "missing sidecar should still enable agent notes"
assert_not_contains "$(cat "$TMP_ROOT/hunk.args")" "--agent-context" "missing sidecar should render a plain diff"
assert_contains "$(cat "$TMP_ROOT/curl.args")" "https://github.com/example/project/pull/17.diff" "review should download the recorded PR diff"

mkdir -p "$DATA/plain"
printf '{"version":1,"summary":"x","files":[]}\n' > "$DATA/plain/review-notes.json"
run_review plain >/dev/null
assert_contains "$(cat "$TMP_ROOT/hunk.args")" "--agent-context $DATA/plain/review-notes.json --agent-notes" \
  "present sidecar should be passed with visible notes"

RC="$TMP_ROOT/bashrc"
printf '. %q\n' "$ROOT/bin/fm-review-shell.sh" > "$RC"
fresh=$(PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" \
  FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_TEST_CURL_ARGS="$TMP_ROOT/fresh-curl.args" \
  FM_TEST_HUNK_ARGS="$TMP_ROOT/fresh-hunk.args" FM_TEST_PATCH="$TMP_ROOT/fresh-patch" \
  bash --noprofile --rcfile "$RC" -ic 'review plain' 2>/dev/null)
assert_contains "$fresh" "Reviewing task plain" "fresh Bash shell should expose one-word review"

NOTES="$TMP_ROOT/generated.json"
printf 'bin/fm-review.sh\t12\t15\tCheck URL normalization\tMerged PR URLs retain their diff endpoint.\n' |
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$DATA" \
    "$ROOT/bin/fm-review-notes.sh" example --summary "Curated uncertainty" --output "$NOTES" >/dev/null
jq -e '.version == 1 and .files[0].annotations[0].confidence == "low" and (.files | length) == 1' \
  "$NOTES" >/dev/null || fail "generator did not emit the curated low-confidence schema"

TWELVE="$TMP_ROOT/twelve.json"
for n in $(seq 1 12); do
  printf 'bin/fm-review.sh\t%s\t%s\tUncertainty %s\n' "$n" "$n" "$n"
done | FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$DATA" \
  "$ROOT/bin/fm-review-notes.sh" example --summary "Twelve notes" --output "$TWELVE" >/dev/null
[ "$(jq '[.files[].annotations[]] | length' "$TWELVE")" -eq 12 ] \
  || fail "generator did not accept exactly twelve annotations"

THIRTEEN="$TMP_ROOT/thirteen.json"
if out=$(for n in $(seq 1 13); do
    printf 'bin/fm-review.sh\t%s\t%s\tUncertainty %s\n' "$n" "$n" "$n"
  done | FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$DATA" \
    "$ROOT/bin/fm-review-notes.sh" example --summary "Thirteen notes" --output "$THIRTEEN" 2>&1); then
  fail "generator accepted thirteen annotations"
fi
assert_contains "$out" "at most 12 curated uncertainty notes" \
  "generator should clearly reject thirteen annotations"
[ ! -e "$THIRTEEN" ] || fail "rejected annotations left an output sidecar"

READY_ROOT="$TMP_ROOT/ready-root"
mkdir -p "$READY_ROOT/bin"
cp "$ROOT/bin/fm-review.sh" "$READY_ROOT/bin/fm-review.sh"
cat > "$READY_ROOT/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"tasks":[
 {"id":"blocked-green","pr":{"url":"https://github.com/example/project/pull/20"},"current_state":{"state":"done","detail":"checks green"},"hints":{"open_decisions":[]},"backlog":{"order":1}},
 {"id":"stale-impact","pr":{"url":"https://github.com/example/project/pull/21"},"current_state":{"state":"done","detail":"checks green"},"hints":{"open_decisions":[]},"backlog":{"order":2}},
 {"id":"real-impact","pr":{"url":"https://github.com/example/project/pull/22"},"current_state":{"state":"done","detail":"checks green"},"hints":{"open_decisions":[]},"backlog":{"order":3}}],
 "backlog":{"records":[
  {"id":"captain-call","state":"queued","structured":true,"kind":"captain","hold_kind":"captain","hold_reason":"choose rollout","blocked_by_ids":["blocked-green"],"unresolved_blocker_ids":[]},
  {"id":"finished","state":"done","unresolved_blocker_ids":["stale-impact"]},
  {"id":"duplicate-live","state":"queued","unresolved_blocker_ids":["stale-impact","stale-impact"]},
  {"id":"live-one","state":"queued","unresolved_blocker_ids":["real-impact"]},
  {"id":"live-two","state":"in_flight","unresolved_blocker_ids":["real-impact"]}]}}
JSON
SH
chmod +x "$READY_ROOT/bin/fm-fleet-snapshot.sh"
fm_write_meta "$STATE/real-impact.meta" "pr=https://github.com/example/project/pull/22"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$READY_ROOT" FM_HOME="$TMP_ROOT" \
  FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_TEST_CURL_ARGS="$TMP_ROOT/ready-curl.args" \
  FM_TEST_HUNK_ARGS="$TMP_ROOT/ready-hunk.args" FM_TEST_PATCH="$TMP_ROOT/ready-patch" \
  "$READY_ROOT/bin/fm-review.sh" >/dev/null
assert_contains "$(cat "$TMP_ROOT/ready-curl.args")" "/pull/22.diff" \
  "bare review should ignore done and duplicate blocker references when selecting the task that unblocks most work"
pass "fm-review handles readiness, metadata, optional sidecars, fresh-shell invocation, and curated notes"
