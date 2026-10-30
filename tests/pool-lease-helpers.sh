#!/usr/bin/env bash
# Shared fixture builders for pooled lifecycle behavior tests.
# The teardown steps that reach outside the pool: no PR, no active pipeline
# run, so a forced cleanup exercises only the copy return.
write_teardown_stubs() {  # <fakebin>
  local fb=$1
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2
exit 1
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/gh-axi" "$fb/gh" "$fb/no-mistakes"
}

# new_case <name> -> echoes the case dir. A project with an origin and a pool
# of two free detached copies, 1 and 2, both available and unleased.
new_case() {  # <name>
  local name=$1 dir home proj one two
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"
  proj="$dir/proj"
  one="$dir/pool/1/proj"
  two="$dir/pool/2/proj"
  mkdir -p "$home/state" "$home/data" "$home/config" "$dir/fake" "$dir/fakebin"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/tmux.log"
  : > "$dir/fake/treehouse.log"
  : > "$dir/fake/windows"
  fm_fake_pool_write_treehouse "$dir/fakebin"
  fm_fake_pool_write_tmux "$dir/fakebin"
  write_teardown_stubs "$dir/fakebin"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$proj"
  printf 'base\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$proj" "$dir/origin.git"
  git -C "$proj" remote add origin "file://$dir/origin.git"
  git -C "$proj" fetch --quiet origin
  git -C "$proj" worktree add --quiet --detach "$one"
  git -C "$proj" worktree add --quiet --detach "$two"
  fm_fake_pool_inventory "$(fm_fake_pool_entry 1 "$one" available)" "$(fm_fake_pool_entry 2 "$two" available)" \
    > "$dir/fake/status.json"
  printf '%s\n' "$dir"
}

prepare_task() {  # <case-dir> <id>
  local dir=$1 id=$2
  mkdir -p "$dir/home/data/$id"
  printf '# brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$id" > "$dir/home/data/$id/brief.md"
  fm_test_backlog_ensure_queue "$dir/home" "$id"
  TASK_TMPS+=("/tmp/fm-$id")
}

# run_spawn <case-dir> <fake-dir> <args...>: the stubbed tmux backend is
# selected explicitly so runtime auto-detection cannot reach a real terminal.
run_spawn() {  # <case-dir> <fake-dir> <args...>
  local dir=$1 fake=$2; shift 2
  env -u HERDR_ENV -u TMUX PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$fake" \
    FM_FAKE_POOL_STATE="$dir/fake/status.json" \
    FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FM_SPAWN_CWD_PROOF_POLLS=1 \
    "$SPAWN" "$@" 2>&1
}

run_teardown() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u HERDR_ENV -u TMUX PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_POOL_STATE="$dir/fake/status.json" \
    "$TEARDOWN" "$@" 2>&1
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# assert_leased_to <case-dir> <id>: the copy the task's record names is leased
# to that task in the pool's own inventory, under the lease the record carries.
assert_leased_to() {  # <case-dir> <id>
  local dir=$1 id=$2 meta wt lease pool_lease holder status
  meta="$dir/home/state/$id.meta"
  wt=$(meta_value "$meta" worktree)
  [ -n "$wt" ] || fail "$id: the record names no copy"
  lease=$(meta_value "$meta" pool_lease_id)
  [ -n "$lease" ] || fail "$id: the record carries no pool lease for '$wt'"
  status=$(fm_fake_pool_field "$dir/fake/status.json" "$wt" status)
  holder=$(fm_fake_pool_field "$dir/fake/status.json" "$wt" lease_holder)
  pool_lease=$(fm_fake_pool_field "$dir/fake/status.json" "$wt" lease_id)
  [ "$status" = leased ] || fail "$id: the pool reports '$wt' as '$status', not leased"
  [ "$holder" = "$id" ] || fail "$id: the pool leases '$wt' to '$holder', not to the task"
  [ "$pool_lease" = "$lease" ] || fail "$id: the record's lease '$lease' is not the pool's lease '$pool_lease' for '$wt'"
}

