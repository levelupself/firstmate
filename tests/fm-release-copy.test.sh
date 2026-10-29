#!/usr/bin/env bash
# Guarded copy release preserves branch-backed work until local landing.
set -eu
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
trap 'for task_tmp in "${TASK_TMPS[@]:-}"; do [ -z "$task_tmp" ] || rm -rf "$task_tmp"; done; fm_test_cleanup' EXIT
successor="successor-copy-release-$$"

# Create records directly for cheap guard cases; the success case uses spawn.
setup_case() {
  dir=$(new_case release)
  wt="$dir/pool/1/proj"
  meta="$dir/home/state/member.meta"
  git -C "$wt" checkout -qb fm/member
  printf 'change\n' > "$wt/change"
  git -C "$wt" add change
  git -C "$wt" commit -qm change
  fm_write_meta "$meta" "backend=tmux" "window=firstmate:fm-member" \
    "endpoint_task_id=member" "worktree=$wt" "project=$dir/proj" \
    'kind=ship' 'mode=local-only' 'harness=codex' 'pool_lease_id=member-lease'
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
setup_case
# RED first: a finished branch must be releasable even though it is not landed.
cp "$dir/home/data/backlog.md" "$dir/prior.backlog"
out=$(run_teardown "$dir" member --release-copy) || fail "finished branch release failed: $out"
assert_contains "$out" 'released-awaiting-landing' 'release did not report retained work'
cmp "$dir/home/data/backlog.md" "$dir/prior.backlog" || fail 'release changed backlog'
[ -f "$meta" ] && [ -f "$dir/home/state/member.brief" ] || fail 'release removed task records'
assert_grep 'done:' "$dir/home/state/member.status" 'release changed status history'
head=$(git -C "$dir/proj" rev-parse refs/heads/fm/member)
[ "$(meta_value "$meta" copy_release_head)" = "$head" ] || fail 'release lost branch identity'
[ -z "$(fm_fake_pool_field "$dir/fake/status.json" "$wt" lease_id)" ] || fail 'lease still held'
[ -z "$(FM_HOME="$dir/home" "$ROOT/bin/fm-worktree-allocation.sh" holder "$dir/proj" "$wt")" ] || fail 'allocation still held'
out=$(FM_HOME="$dir/home" "$ROOT/bin/fm-crew-state.sh" member)
assert_contains "$out" 'released-awaiting-landing' 'crew state treated released task as dead'
# Ordinary cleanup must still refuse before landing, even with the copy gone.
if out=$(run_teardown "$dir" member); then fail 'unlanded released task retired'; fi
assert_contains "$out" 'not landed' 'cleanup lost landed-work refusal'
# Reuse the only free slot through the real spawn interface.
prepare_task "$dir" "$successor"
sed -i s/mode=no-mistakes/mode=local-only/ "$dir/home/data/$successor/brief.md"
out=$(run_spawn "$dir" "$dir/fake" "$successor" "$dir/proj" --mode local-only --yolo off) || fail "$out"
assert_leased_to "$dir" "$successor"
[ "$(meta_value "$dir/home/state/$successor.meta" worktree)" = "$wt" ] || fail 'spawn did not reuse freed copy'
# A landing lead merges the member by branch name, from a separate copy.
lead="$dir/pool/2/proj"
git -C "$lead" checkout -qb fm/lead main
git -C "$lead" merge -q --no-ff fm/member -m batch
fm_write_meta "$dir/home/state/lead.meta" "backend=tmux" 'window=firstmate:fm-lead' \
  'endpoint_task_id=lead' "project=$dir/proj" "worktree=$lead" 'kind=ship' 'mode=local-only' 'spawned_at=2026-10-01T00:00:00Z'
fm_test_backlog_ensure_queue "$dir/home" lead
out=$(FM_HOME="$dir/home" PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-merge-local.sh" lead 2>&1) || fail "$out"
git -C "$dir/proj" merge-base --is-ancestor "$head" main || fail 'batch omitted released member'
cp "$dir/fake/status.json" "$dir/after-spawn.pool"
cp "$dir/home/state/$successor.meta" "$dir/successor.meta"
out=$(run_teardown "$dir" member) || fail "post-landing cleanup failed: $out"
assert_contains "$out" 'copy already returned' 'cleanup did not reuse records-only path'
[ ! -f "$meta" ] || fail 'post-landing records survived'
cmp "$dir/fake/status.json" "$dir/after-spawn.pool" || fail 'cleanup returned successor copy'
cmp "$dir/home/state/$successor.meta" "$dir/successor.meta" || fail 'cleanup changed successor'
pass 'release, re-lease by spawn, batch landing, and post-landing cleanup'

for spec in 'kind=scout' 'mode=no-mistakes' 'backend=orca' 'endpoint_task_id=foreign'; do
  setup_case
  key=${spec%%=*}
  sed -i "s/^$key=.*/$spec/" "$meta"
  case "$key" in endpoint_task_id) reason='endpoint' ;; *) reason='release-copy requires' ;; esac
  refuses "$reason"
done
for verb in working paused needs-decision; do
  setup_case
  printf '%s: still active\n' "$verb" >> "$dir/home/state/member.status"
  refuses 'latest status must be done:'
done
for dirty in unstaged staged untracked hook-untracked; do
  setup_case
  case "$dirty" in
    unstaged) echo dirty >> "$wt/change" ;;
    staged) echo dirty >> "$wt/change"; git -C "$wt" add change ;;
    untracked) echo dirty > "$wt/extra" ;;
    hook-untracked) mkdir "$wt/.claude"; echo dirty > "$wt/.claude/extra" ;;
  esac
  refuses 'uncommitted'
done
# Inject the git public index-inspection response, without setting hidden flags.
for flag in S h; do
  setup_case
  real_git=$(command -v git)
  cat > "$dir/fakebin/git" <<EOF
#!/usr/bin/env bash
if [ "\${3:-} \${4:-}" = 'ls-files -v' ]; then printf '$flag change\n'; exit 0; fi
exec '$real_git' "\$@"
EOF
  chmod +x "$dir/fakebin/git"
  refuses 'hidden from ordinary dirty checks'
done
setup_case
git -C "$wt" checkout -q --detach
git -C "$dir/proj" branch -D fm/member >/dev/null
refuses 'shared branch'
setup_case
git -C "$wt" checkout -q --detach
git -C "$wt" commit --allow-empty -qm extra
refuses 'shared branch'
setup_case
cp "$meta" "$dir/home/state/landing.meta"
sed -i 's/endpoint_task_id=member/endpoint_task_id=landing/' "$dir/home/state/landing.meta"
refuses 'task landing'
setup_case
FM_HOME="$dir/home" "$ROOT/bin/fm-worktree-allocation.sh" acquire other "$dir/proj" "$wt" 2026-10-01T00:00:00Z >/dev/null
refuses 'holder'
setup_case
node -e 'const fs=require("fs"),p=process.argv[1],s=JSON.parse(fs.readFileSync(p));s[0].lease_id="foreign";s[0].lease_holder="other";fs.writeFileSync(p,JSON.stringify(s))' "$dir/fake/status.json"
refuses 'leased by the pool'
setup_case
printf '[]\n' > "$dir/fake/status.json"
refuses 'pool inventory'
setup_case
# The pool may refuse its compare-and-return after the journal was written.
if out=$(FM_FAKE_RETURN_FAIL=1 run_teardown "$dir" member --release-copy); then fail 'failed return reported success'; fi
[ -z "$(meta_value "$meta" copy_released_at)" ] || fail 'failed return marked released'
[ "$(fm_fake_pool_field "$dir/fake/status.json" "$wt" lease_id)" = member-lease ] || fail 'failed return lost lease'
out=$(run_teardown "$dir" member --release-copy) || fail "retry failed: $out"
assert_contains "$out" 'released-awaiting-landing' 'retry did not finish'
pass 'failed pool return retains the lease and can be retried'
