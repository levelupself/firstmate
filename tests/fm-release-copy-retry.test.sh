#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/pool-helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/pool-lease-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-release-copy-retry)
trap fm_test_cleanup EXIT

for journal in partial complete; do
  dir=$(new_case "$journal")
  wt="$dir/pool/1/proj"
  meta="$dir/home/state/member.meta"
  git -C "$wt" checkout -qb fm/member
  printf 'change\n' > "$wt/change"
  git -C "$wt" add change
  git -C "$wt" commit -qm change
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$meta" 'backend=tmux' 'window=firstmate:fm-member' \
    'endpoint_task_id=member' "worktree=$wt" "project=$dir/proj" \
    'kind=ship' 'mode=local-only' 'harness=codex' 'pool_lease_id=member-lease' \
    'spawned_at=2026-10-01T00:00:00Z'
  fm_test_backlog_ensure_queue "$dir/home" member
  printf 'done: ready in branch\n' > "$dir/home/state/member.status"
  printf 'fm-member\n' > "$dir/fake/windows"
  fm_fake_pool_inventory "$(fm_fake_pool_entry 1 "$wt" leased '[]' member-lease member)" \
    > "$dir/fake/status.json"

  if out=$(FM_FAKE_RETURN_FAIL=1 run_teardown "$dir" member --release-copy); then
    fail 'failed release return reported success'
  fi
  [ "$(meta_value "$meta" copy_release_head)" = "$head" ] || fail 'release journal missing'
  [ "$(git -C "$dir/proj" rev-parse refs/heads/fm/member)" = "$head" ] || fail 'release changed shared branch'
  if git -C "$wt" symbolic-ref -q HEAD; then fail 'pool return received an attached branch'; fi
  if [ "$journal" = partial ]; then
    sed -i '/^copy_release_pending_at=/d; /^teardown_at=/d' "$meta"
  fi
  git -C "$wt" checkout -q fm/member
  if out=$(run_teardown "$dir" member); then fail 'unlanded journal allowed cleanup'; fi
  assert_contains "$out" 'not landed' 'journal bypassed landing guard'
  git -C "$dir/proj" merge -q --ff-only fm/member
  cp "$dir/fake/status.json" "$dir/prior.pool"
  if out=$(FM_FAKE_RETURN_FAIL=1 run_teardown "$dir" member); then
    fail 'failed cleanup return reported success'
  fi
  assert_contains "$out" 'treehouse return failed' 'cleanup failed before reaching pool return'
  [ -f "$meta" ] || fail 'failed cleanup removed records'
  [ "$(git -C "$dir/proj" rev-parse refs/heads/fm/member)" = "$head" ] || fail 'failed cleanup deleted shared branch'
  cmp "$dir/fake/status.json" "$dir/prior.pool" || fail 'failed cleanup released lease'

  extra=$(printf 'extra\n' | git -C "$dir/proj" commit-tree "$head^{tree}" -p "$head")
  git -C "$dir/proj" update-ref refs/heads/fm/member "$extra"
  if out=$(run_teardown "$dir" member); then fail 'unlanded shared branch allowed retry'; fi
  assert_contains "$out" 'not landed' 'retry checked only the saved commit'
  git -C "$dir/proj" update-ref refs/heads/fm/member "$head"
  out=$(run_teardown "$dir" member) || fail "cleanup retry failed: $out"
  [ ! -f "$meta" ] || fail 'successful cleanup retained records'
  [ -z "$(fm_fake_pool_field "$dir/fake/status.json" "$wt" lease_id)" ] || fail 'successful cleanup retained lease'
  [ "$(git -C "$dir/proj" rev-parse refs/heads/fm/member)" = "$head" ] || fail 'cleanup lost shared branch'
  pass "$journal release journal preserves branch through failed cleanup and retry"
done
