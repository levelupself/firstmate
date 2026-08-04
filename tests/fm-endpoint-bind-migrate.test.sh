#!/usr/bin/env bash
# Behavior tests for the explicit legacy Herdr endpoint-binding migration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGRATE="$ROOT/bin/fm-endpoint-bind-migrate.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-bind-migrate)
TASK_ID=061-linear-refresh-path

make_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data/$TASK_ID" "$dir/fakebin" \
    "$dir/worktree" "$dir/project"
  fm_write_meta "$dir/home/state/$TASK_ID.meta" \
    "window=default:w5:p3" \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    "backend=herdr" \
    "herdr_session=default" \
    "herdr_workspace_id=w5" \
    "herdr_tab_id=w5:t3" \
    "herdr_pane_id=w5:p3" \
    "kind=ship"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "agent list")
    [ "${FM_FAKE_HERDR_INVENTORY_STATUS:-0}" -eq 0 ] || exit "$FM_FAKE_HERDR_INVENTORY_STATUS"
    printf '%s\n' "${FM_FAKE_HERDR_INVENTORY:-not-json}"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  printf '%s\n' "$dir"
}

inventory_for() {  # <worktree> [<pane>] [<workspace>] [<tab>]
  jq -cn --arg worktree "$1" --arg pane "${2:-w5:p3}" \
    --arg workspace "${3:-w5}" --arg tab "${4:-w5:t3}" '
    {result:{agents:[{
      agent:"codex",
      agent_status:"done",
      foreground_cwd:$worktree,
      pane_id:$pane,
      workspace_id:$workspace,
      tab_id:$tab
    }]}}
  '
}

run_migrate() {  # <case> <inventory>
  local dir=$1 inventory=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_HERDR_INVENTORY="$inventory" PATH="$dir/fakebin:$PATH" \
    "$MIGRATE" "$TASK_ID"
}

assert_unbound() {  # <case> <description>
  local dir=$1 description=$2
  ! grep -q '^endpoint_task_id=' "$dir/home/state/$TASK_ID.meta" \
    || fail "$description: refusal added endpoint_task_id"
  assert_absent "$dir/home/data/$TASK_ID/endpoint-binding-migration.json" \
    "$description: refusal published an audit"
}

test_unique_live_worktree_match_migrates_with_audit() {
  local dir inventory output audit
  dir=$(make_case success)
  inventory=$(inventory_for "$dir/worktree")
  output=$(run_migrate "$dir" "$inventory") \
    || fail "unique-match migration failed"

  assert_contains "$(cat "$dir/home/state/$TASK_ID.meta")" \
    "endpoint_task_id=$TASK_ID" \
    "unique-match migration did not add the binding"
  assert_contains "$(cat "$dir/home/state/$TASK_ID.meta")" \
    'endpoint_binding_migration=herdr-agent-list-foreground-cwd-v1' \
    "unique-match migration did not record provenance"
  audit="$dir/home/data/$TASK_ID/endpoint-binding-migration.json"
  assert_present "$audit" "unique-match migration did not retain an audit"
  jq -e --arg worktree "$dir/worktree" '
    .version == 1
    and .task_id == "061-linear-refresh-path"
    and .verification == "herdr-agent-list-foreground-cwd-v1"
    and .inventory_match_count == 1
    and .recorded.worktree == $worktree
    and .live_match.foreground_cwd == $worktree
    and .live_match.pane_id == "w5:p3"
  ' "$audit" >/dev/null || fail "unique-match audit does not contain the verified live evidence"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_validate_task_endpoint "$2/home/state/061-linear-refresh-path.meta" 061-linear-refresh-path
  ' _ "$ROOT" "$dir" || fail "migrated metadata does not pass ordinary cleanup authorization"
  assert_contains "$output" "one exact Herdr foreground_cwd match" \
    "successful migration did not explain its proof"
  pass "endpoint binding migration: one exact live worktree match records auditable evidence and unlocks ordinary cleanup authorization"
}

test_zero_live_worktree_matches_refuses() {
  local dir inventory rc=0
  dir=$(make_case zero)
  inventory=$(inventory_for "$dir/not-the-worktree")
  run_migrate "$dir" "$inventory" > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "zero-match migration unexpectedly succeeded"
  assert_unbound "$dir" "zero-match migration"
  assert_contains "$(cat "$dir/stderr")" "zero exact foreground_cwd matches" \
    "zero-match refusal did not name the failed condition"
  pass "endpoint binding migration: zero live worktree matches refuse without authorization"
}

test_ambiguous_live_worktree_matches_refuses() {
  local dir one inventory rc=0
  dir=$(make_case ambiguous)
  one=$(inventory_for "$dir/worktree")
  inventory=$(printf '%s\n' "$one" | jq -c \
    '.result.agents += [(.result.agents[0] | .pane_id = "w5:p9" | .tab_id = "w5:t9")]')
  run_migrate "$dir" "$inventory" > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "ambiguous migration unexpectedly succeeded"
  assert_unbound "$dir" "ambiguous migration"
  assert_contains "$(cat "$dir/stderr")" "2 exact foreground_cwd matches" \
    "ambiguous refusal did not report the match count"
  assert_contains "$(cat "$dir/stderr")" "binding is ambiguous" \
    "ambiguous refusal did not name the failed condition"
  pass "endpoint binding migration: multiple live worktree matches refuse as ambiguous"
}

test_unreadable_live_inventory_refuses() {
  local dir rc=0
  dir=$(make_case unreadable)
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_HERDR_INVENTORY_STATUS=7 \
    PATH="$dir/fakebin:$PATH" "$MIGRATE" "$TASK_ID" \
    > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable-inventory migration unexpectedly succeeded"
  assert_unbound "$dir" "unreadable-inventory migration"
  assert_contains "$(cat "$dir/stderr")" "inventory for session default is unreadable" \
    "unreadable-inventory refusal did not name the failed condition"
  pass "endpoint binding migration: unreadable live inventory refuses without authorization"
}

test_unique_worktree_match_with_other_endpoint_refuses() {
  local dir inventory rc=0
  dir=$(make_case endpoint-mismatch)
  inventory=$(inventory_for "$dir/worktree" "w5:p9" "w5" "w5:t9")
  run_migrate "$dir" "$inventory" > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "endpoint-mismatch migration unexpectedly succeeded"
  assert_unbound "$dir" "endpoint-mismatch migration"
  assert_contains "$(cat "$dir/stderr")" "not task $TASK_ID's recorded endpoint" \
    "endpoint-mismatch refusal did not explain the contradiction"
  pass "endpoint binding migration: a unique worktree hit cannot authorize a different recorded endpoint"
}

test_normally_bound_task_is_unchanged() {
  local dir audit rc=0
  dir=$(make_case normally-bound)
  printf 'endpoint_task_id=%s\n' "$TASK_ID" >> "$dir/home/state/$TASK_ID.meta"
  cp "$dir/home/state/$TASK_ID.meta" "$dir/meta.before"
  run_migrate "$dir" "$(inventory_for "$dir/worktree")" \
    > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "normally-bound task unexpectedly entered legacy migration"
  cmp -s "$dir/meta.before" "$dir/home/state/$TASK_ID.meta" \
    || fail "normally-bound task metadata changed"
  audit="$dir/home/data/$TASK_ID/endpoint-binding-migration.json"
  assert_absent "$audit" \
    "normally-bound task should not gain migration evidence"
  assert_contains "$(cat "$dir/stderr")" "does not have legacy unbound endpoint metadata" \
    "normally-bound refusal did not explain that migration is inapplicable"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_validate_task_endpoint "$2/home/state/061-linear-refresh-path.meta" 061-linear-refresh-path
  ' _ "$ROOT" "$dir" || fail "normally-bound task lost ordinary cleanup authorization"
  pass "endpoint binding migration: normally spawned task metadata and cleanup authorization stay unchanged"
}

test_concurrent_migrations_publish_one_consistent_result() {
  local dir inventory first_rc second_rc successes audit_marker meta_verified audit_verified
  dir=$(make_case concurrent)
  inventory=$(inventory_for "$dir/worktree")
  first_rc="$dir/first.rc"
  second_rc="$dir/second.rc"
  (
    run_migrate "$dir" "$(printf '%s\n' "$inventory" | jq '.result.agents[0].evidence_marker = "first"')" \
      > "$dir/first.stdout" 2> "$dir/first.stderr"
    printf '%s\n' "$?" > "$first_rc"
  ) &
  (
    run_migrate "$dir" "$(printf '%s\n' "$inventory" | jq '.result.agents[0].evidence_marker = "second"')" \
      > "$dir/second.stdout" 2> "$dir/second.stderr"
    printf '%s\n' "$?" > "$second_rc"
  ) &
  wait
  successes=$(( (1 - $(cat "$first_rc")) + (1 - $(cat "$second_rc")) ))
  [ "$successes" -eq 1 ] || fail "concurrent migrations did not serialize to exactly one successful publication"
  audit_marker=$(jq -r '.live_match.evidence_marker' "$dir/home/data/$TASK_ID/endpoint-binding-migration.json")
  meta_verified=$(sed -n 's/^endpoint_binding_verified_at=//p' "$dir/home/state/$TASK_ID.meta")
  audit_verified=$(jq -r '.verified_at' "$dir/home/data/$TASK_ID/endpoint-binding-migration.json")
  [ "$audit_marker" = first ] || [ "$audit_marker" = second ] \
    || fail "concurrent migration audit lost the winning live evidence"
  [ "$meta_verified" = "$audit_verified" ] \
    || fail "concurrent migration metadata and audit have different verification timestamps"
  pass "endpoint binding migration: concurrent public invocations publish one consistent binding and audit"
}

test_unique_live_worktree_match_migrates_with_audit
test_zero_live_worktree_matches_refuses
test_ambiguous_live_worktree_matches_refuses
test_unreadable_live_inventory_refuses
test_unique_worktree_match_with_other_endpoint_refuses
test_normally_bound_task_is_unchanged
test_concurrent_migrations_publish_one_consistent_result
