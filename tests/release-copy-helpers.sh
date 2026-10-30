#!/usr/bin/env bash
# Shared isolated fixtures for copy-release behavior tests.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/pool-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pool-helpers.sh"
# shellcheck source=tests/pool-lease-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pool-lease-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-release-copy)
TASK_TMPS=()
cleanup() {
  local task_tmp queue home
  for task_tmp in "${TASK_TMPS[@]:-}"; do
    [ -z "$task_tmp" ] || rm -rf "$task_tmp"
  done
  for queue in "$TMP_ROOT"/*/home/state/.effort-queue-*; do
    [ -d "$queue" ] || continue
    home=${queue%/state/*}
    FM_HOME="$home" "$ROOT/bin/fm-effort-store.sh" report --sync >/dev/null || return 1
  done
  fm_test_cleanup
}
trap cleanup EXIT
case_number=0

# Create records directly for cheap guard cases; the success case uses spawn.
setup_case() {
  case_number=$((case_number + 1))
  dir=$(new_case "release-$case_number")
  wt="$dir/pool/1/proj"
  meta="$dir/home/state/member.meta"
  git -C "$wt" checkout -qb fm/member
  printf 'change\n' > "$wt/change"
  git -C "$wt" add change
  git -C "$wt" commit -qm change
  fm_write_meta "$meta" "backend=tmux" "window=firstmate:fm-member" \
    "endpoint_task_id=member" "worktree=$wt" "project=$dir/proj" \
    'kind=ship' 'mode=local-only' 'harness=codex' 'pool_lease_id=member-lease' 'spawned_at=2026-10-01T00:00:00Z'
  fm_test_backlog_ensure_queue "$dir/home" member
  printf 'done: ready in branch\n' > "$dir/home/state/member.status"
  printf 'instructions\n' > "$dir/home/state/member.brief"
  printf 'fm-member\n' > "$dir/fake/windows"
  fm_fake_pool_inventory "$(fm_fake_pool_entry 1 "$wt" leased '[]' member-lease member)" \
    > "$dir/fake/status.json"
}
refuses() {
  local reason=$1 before after out
  before=$(git -C "$wt" rev-parse HEAD)
  cp "$meta" "$dir/prior.meta"
  cp "$dir/fake/status.json" "$dir/prior.pool"
  cp "$dir/fake/tmux.log" "$dir/prior.tmux"
  if out=$(run_teardown "$dir" member --release-copy); then fail "release accepted $reason"; fi
  assert_contains "$out" "$reason" 'refusal did not explain the guard'
  cmp "$meta" "$dir/prior.meta" || fail 'refusal changed task metadata'
  cmp "$dir/fake/status.json" "$dir/prior.pool" || fail 'refusal returned the copy'
  cmp "$dir/fake/tmux.log" "$dir/prior.tmux" || fail 'refusal touched the endpoint'
  after=$(git -C "$wt" rev-parse HEAD)
  [ "$before" = "$after" ] || fail 'refusal reset the copy'
  pass "release refuses $reason without changing task, endpoint, or copy"
}
