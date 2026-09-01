#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

# shellcheck disable=SC2153  # ROOT is assigned by tests/lib.sh.
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_idle() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
- [ ] decision-one - First decision request (repo: alpha) (kind: captain) (hold: choose API A or B) (hold-kind: captain)
- [ ] decision-two - Second decision request (repo: alpha) (kind: captain) (hold: approve the narrow rollout) (hold-kind: captain)
- [ ] decision-three - Third decision request (repo: alpha) (kind: captain) (hold: choose the storage boundary) (hold-kind: captain)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  # A working ship task proves it through its own semantic busy-state record
  # (bin/fm-busy-lib.sh), which is what the snapshot's current-state read
  # consults; rendered pane text is no longer a state source.
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$fixture_gen" \
    --source claude-hook --event user-prompt-submit
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'needs-decision [key=api]: choose the public API shape\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  mkdir -p "$home/state/usage-cache"
  cat > "$home/state/usage-cache/ship-task.json" <<'JSON'
{"schema":"fm-task-usage.v2","id":"ship-task","harness":"claude","actual_models":["Opus 5"],"tokens":{"input":1,"output":2,"cache_read":3,"cache_write":4},"cost_usd":0.5,"calls":6,"sessions":1,"duration_seconds":60}
JSON
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "IN FLIGHT (0)" "empty fleet view should report no active tasks"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
      and .usage.schema == "fm-task-usage.v2"
      and .usage.stale == true
      and .usage.actual_models == ["Opus 5"]
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 5
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "decision-one")
    | .title == "First decision request"
      and .kind == "captain"
      and .hold == "choose API A or B"
      and .hold_kind == "captain"
  ' >/dev/null || fail "hold metadata did not parse into a clean decision row"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: visible\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-ship"])
      and ([.tasks[].id] == ["visible-ship"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: orphan now live\n' > "$home/state/orphan-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-ship", "visible-ship"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: ship)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: ship)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/worker.meta" \
    "window=firstmate:fm-worker" "worktree=$home/projects/worker" "project=alpha" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "captain-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .captain_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .captain_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "completed blockers did not make the captain hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "snapshot disagreed with tasks-axi missing-blocker semantics: $out"
  pass "backlog normalization takes readiness, holds, and blockers from tasks-axi"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out hint_gen
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-decision
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-blocked
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-decision)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-decision busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-blocked)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-blocked busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma
- [ ] mixed-blockers - Mixed Blockers blocked-by: missing blocked-by: done-comma (repo: beta) (kind: ship)
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: captain route choice pending) (hold-kind: captain)

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" bold-task
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "captain"
      and .hold_reason == "captain route choice pending"
      and .hold_kind == "captain"
  ' >/dev/null || fail "tasks-axi captain-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" COLUMNS=100 FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_not_contains "$view" "bold-task" \
    "finished work should not crowd the default utilization view"
  # Every queued row here records a title and no body, so tasks-axi calls all
  # three dependency-ready while none can be handed to a worker as written.
  assert_contains "$view" "READY (0 clear, 3 need a check)" \
    "view should classify dispatchable tasks through tasks-axi"
  assert_contains "$view" "BLOCKED (1)" \
    "view should count only genuinely open blockers"
  assert_contains "$view" "• blocked-reason ← queued-comma · waits on queued-comma" \
    "view should render a blocked reason without title metadata"
  assert_not_contains "$view" "mixed-blockers ←" \
    "a stale or missing dependency edge must not render as an open blocker"
  assert_contains "$view" "? mixed-blockers · needs instructions; needs missing, not on the backlog" \
    "a missing dependency edge must surface in ready rather than vanish entirely"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_ready_set_agrees_with_tasks_axi() {
  local home authoritative snapshot_ids view view_ids
  home=$(make_home ready-agreement)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] running - Running task (repo: firstmate) (kind: ship)

## Queued
- [ ] ready-a - Ready task (repo: firstmate) (kind: ship)
  Instructions the worker can act on.
- [ ] blocked-open - Blocked task (repo: firstmate) (kind: ship) blocked-by: running - waits for running
- [ ] stale-edge - Stale edge task (repo: firstmate) (kind: ship) blocked-by: closed - historical edge
- [ ] captain-choice - Choose a route (repo: firstmate) (kind: captain) (hold: choose blue or green) (hold-kind: captain)
- [ ] do-not-build - Do not build yet (repo: firstmate) (kind: ship) (hold: specification is not approved) (hold-kind: external)

## Done
- [x] closed - Closed task (repo: firstmate) (kind: ship) (done 2026-08-05)
EOF
  authoritative=$(tasks-axi ready --file "$home/data/backlog.md" | awk '
    /^ready\[[0-9]+\]\{/ { rows=1; next }
    rows && /^  / { sub(/^  /, ""); sub(/,.*/, ""); print; next }
    rows { exit }
  ' | LC_ALL=C sort)
  snapshot_ids=$(FM_HOME="$home" "$SNAPSHOT" --json \
    | jq -r '.backlog.records[] | select(.dispatchable == true) | .id' | LC_ALL=C sort)
  [ "$snapshot_ids" = "$authoritative" ] \
    || fail "snapshot ready set disagreed with tasks-axi: snapshot=$snapshot_ids tasks-axi=$authoritative"
  view=$(FM_HOME="$home" "$VIEW" --section ready)
  # Separating dispatchable work from work the backlog cannot confirm must not
  # drop a row: the two markers together still carry the whole tasks-axi set.
  view_ids=$(printf '%s\n' "$view" | sed -n -e 's/^• \([^ ]*\).*/\1/p' -e 's/^? \([^ ]*\).*/\1/p' \
    | LC_ALL=C sort)
  [ "$view_ids" = "$authoritative" ] \
    || fail "panel ready set disagreed with tasks-axi: panel=$view_ids tasks-axi=$authoritative"
  assert_contains "$view" "READY (1 clear, 1 need a check)" \
    "ready heading count must describe the rendered tasks-axi set"
  assert_contains "$view" "• ready-a · Ready task" \
    "a queued row with instructions must render as dispatchable"
  assert_contains "$view" "? stale-edge · needs instructions" \
    "a queued row with no instructions must render its reason"
  view=$(FM_HOME="$home" "$VIEW" --section blocked)
  assert_contains "$view" "BLOCKED (1)" "only one dependency is genuinely open"
  assert_contains "$view" "blocked-open ← running" "open dependency missing from blocked panel"
  assert_not_contains "$view" "stale-edge" "closed dependency edge rendered as a blocker"
  assert_not_contains "$view" "do-not-build" "held work rendered as a dependency blocker"
  view=$(FM_HOME="$home" "$VIEW" --section waiting)
  assert_contains "$view" "YOUR DECISIONS (1)" "captain-held queue must contain exactly the actionable hold"
  assert_contains "$view" "choose blue or green" "captain-held row omitted the answerable question"
  assert_not_contains "$view" "do-not-build" "an external hold leaked into the captain decision queue"
  pass "fleet snapshot and panel ready sets agree exactly with tasks-axi"
}

# The captain's 2026-08-29 acceptance criterion: every decision renders exactly
# once at several terminal widths. Sibling captain decisions filed for one
# origin share a long id prefix by construction - fm-decision-hold.sh names them
# <origin>-decision-<key> - so a left-anchored clip collapses them into
# identical rows, which is what "! 050-model-compati... three times" was. They
# are distinct decisions and must stay distinguishable at every width the
# cockpit can give a fleet pane.
test_sibling_decisions_stay_distinct_at_every_width() {
  local home width view rows unique widest
  home=$(make_home decision-width)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] compatibility-matrix-decision-vendor-list - Choose the vendor list (repo: alpha) (kind: captain) (hold: needs the captain to choose the vendor list) (hold-kind: captain)
  Origin: compatibility-matrix
  Decision key: vendor-list
- [ ] compatibility-matrix-decision-fallback-policy - Choose the fallback policy (repo: alpha) (kind: captain) (hold: needs the captain to choose the fallback policy) (hold-kind: captain)
  Origin: compatibility-matrix
  Decision key: fallback-policy
- [ ] compatibility-matrix-decision-adapter-scope - Choose the adapter scope (repo: alpha) (kind: captain) (hold: needs the captain to choose the adapter scope) (hold-kind: captain)
  Origin: compatibility-matrix
  Decision key: adapter-scope

## Done
EOF
  for width in 100 60 40 30 24 20; do
    view=$(COLUMNS="$width" LINES=40 FM_HOME="$home" "$VIEW" --section waiting)
    assert_contains "$view" "YOUR DECISIONS (3)" \
      "width $width lost a decision from the heading count"
    rows=$(printf '%s\n' "$view" | grep -c '^! ') || true
    [ "$rows" = 3 ] \
      || fail "width $width rendered $rows decision rows for 3 decisions: $view"
    unique=$(printf '%s\n' "$view" | grep '^! ' | LC_ALL=C sort -u | wc -l | tr -d ' ')
    [ "$unique" = 3 ] \
      || fail "width $width collapsed sibling decisions into $unique distinguishable rows: $view"
    # No row may exceed the width it was rendered for, or the terminal wraps it
    # into extra physical rows and the frame stops fitting its pane. Measured in
    # characters, like the renderer's own clip: the rows carry multi-byte
    # separators, so a byte count would report a false overflow.
    widest=$(printf '%s\n' "$view" | jq -Rrs 'split("\n") | map(length) | max')
    [ "$widest" -le "$width" ] \
      || fail "width $width emitted a $widest-character row: $view"
  done
  pass "sibling captain decisions render exactly once and stay distinct at every width"
}

test_ready_separates_dispatchable_from_unconfirmed() {
  local home out view ready_section
  home=$(make_home ready-dispatch-truth)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] clear-one - Straightforward queued work (repo: firstmate) (kind: ship)
  Implement the thing, with acceptance criteria.
- [ ] clear-dep-landed - Queued behind a dependency the backlog still lists blocked-by: landed (repo: firstmate) (kind: ship)
  Implement the follow-up once the dependency is in.
- [ ] no-body - Queued with no instructions recorded (repo: firstmate) (kind: ship)
- [ ] dep-unlisted - Queued behind a dependency the backlog no longer lists blocked-by: vanished (repo: firstmate) (kind: ship)
  Implement the follow-up.
- [ ] both-reasons - Queued with neither instructions nor a listed dependency blocked-by: vanished (repo: firstmate) (kind: ship)

## Done
- [x] landed - Landed dependency (repo: firstmate) (kind: ship) (done 2026-08-09)
EOF
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  # tasks-axi still owns dependency readiness: every one of these is unblocked
  # and unheld, so the producer's own answer must not change.
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.dispatchable == true) | .id] | sort
    == ["both-reasons","clear-dep-landed","clear-one","dep-unlisted","no-body"]
  ' >/dev/null || fail "tasks-axi dependency readiness changed: $out"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.dispatch_clear == true) | .id] | sort
    == ["clear-dep-landed","clear-one"]
  ' >/dev/null || fail "snapshot did not separate dispatchable work from unconfirmed work: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "no-body")
    | [.dispatch_review[].reason] == ["no_instructions"]
  ' >/dev/null || fail "a queued row with no instructions carried no dispatch reason: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "dep-unlisted")
    | .dispatch_review == [{reason:"unlisted_dependency",ids:["vanished"]}]
  ' >/dev/null || fail "an unlisted dependency carried no dispatch reason: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "both-reasons")
    | [.dispatch_review[].reason] == ["no_instructions","unlisted_dependency"]
  ' >/dev/null || fail "a row failing both checks lost one reason: $out"

  view=$(COLUMNS=100 FM_HOME="$home" "$VIEW" --section ready)
  assert_contains "$view" "READY (2 clear, 3 need a check)" \
    "the ready heading must count dispatchable work apart from unconfirmed work"
  assert_contains "$view" "• clear-one · Straightforward queued work" \
    "dispatchable work must render unmarked"
  assert_contains "$view" "? no-body · needs instructions" \
    "a row with no instructions must render its reason"
  assert_contains "$view" "? dep-unlisted · needs vanished, not on the backlog" \
    "a row with an unlisted dependency must render its reason"
  assert_not_contains "$view" "• no-body" \
    "unconfirmed work must not render as plain dispatchable work"
  ready_section=$(printf '%s\n' "$view" | sed -n '/^READY/,$p')
  [ "$(printf '%s\n' "$ready_section" | grep -cE '^(• |\? )')" -eq 5 ] \
    || fail "ready section lost a dependency-ready row: $view"
  pass "ready separates dispatchable work from work the backlog cannot confirm"
}

test_ready_counts_stay_plain_without_unconfirmed_work() {
  local home view
  home=$(make_home ready-all-clear)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] clear-one - Straightforward queued work (repo: firstmate) (kind: ship)
  Implement the thing.
EOF
  view=$(COLUMNS=100 FM_HOME="$home" "$VIEW" --section ready)
  assert_contains "$view" "READY (1)" \
    "a fully dispatchable queue must keep the plain ready count"
  assert_not_contains "$view" "need a check" \
    "a fully dispatchable queue must not mention unconfirmed work"
  pass "ready keeps its plain count when every queued row is dispatchable"
}

test_backlog_projection_uses_one_source_image() {
  local home fakebin real_tasks_axi out
  home=$(make_home coherent-backlog)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] held-task - Held task (repo: firstmate) (kind: ship) (hold: approval pending) (hold-kind: external)
EOF
  fakebin=$(make_fakebin "$home")
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
"${REAL_TASKS_AXI:?}" "$@"
rc=$?
if [ "${1:-}" = list ]; then
  cat > "${RACE_BACKLOG:?}" <<'EOF'
## Queued
- [ ] held-task - Held task (repo: firstmate) (kind: ship)
EOF
fi
exit "$rc"
SH
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" REAL_TASKS_AXI="$real_tasks_axi" RACE_BACKLOG="$home/data/backlog.md" \
    FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "held-task")
    | .hold_active == true and .dispatchable == false
  ' >/dev/null || fail "backlog changed between tasks-axi projections: $out"
  pass "snapshot derives all backlog projections from one source image"
}

test_view_respects_terminal_height() {
  local home view lines i
  home=$(make_home height-aware)
  printf '## Queued\n' > "$home/data/backlog.md"
  i=1
  while [ "$i" -le 20 ]; do
    printf -- '- [ ] ready-%02d - Ready task %02d (repo: firstmate) (kind: ship)\n  Instructions %02d.\n' \
      "$i" "$i" "$i" >> "$home/data/backlog.md"
    i=$((i + 1))
  done
  view=$(LINES=12 COLUMNS=60 FM_HOME="$home" "$VIEW")
  lines=$(printf '%s\n' "$view" | awk 'END {print NR}')
  [ "$lines" -le 12 ] || fail "fleet view emitted $lines rows into a 12-row pane"
  assert_contains "$view" "READY (20)" "height-aware render lost the authoritative ready count"
  assert_contains "$view" "more rows not shown" "truncated panel did not disclose hidden rows"
  pass "fleet view fits the terminal height and discloses truncation"
}

test_view_renders_snapshot() {
  local home fakebin view decisions_line ready_line inflight_line blocked_line inflight_section
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  decisions_line=$(printf '%s\n' "$view" | grep -n '^YOUR DECISIONS' | cut -d: -f1)
  ready_line=$(printf '%s\n' "$view" | grep -n '^READY' | cut -d: -f1)
  inflight_line=$(printf '%s\n' "$view" | grep -n '^IN FLIGHT' | cut -d: -f1)
  blocked_line=$(printf '%s\n' "$view" | grep -n '^BLOCKED' | cut -d: -f1)
  [ "$decisions_line" -lt "$ready_line" ] && [ "$ready_line" -lt "$inflight_line" ] && [ "$inflight_line" -lt "$blocked_line" ] \
    || fail "fleet view priority order is wrong: $view"
  assert_contains "$view" "IN FLIGHT (3)" \
    "dispatched work should include working and unreadable runtime state"
  assert_contains "$view" "• ship-task · Ship Task" \
    "view should render the active task"
  inflight_section=$(printf '%s\n' "$view" | sed -n '/^IN FLIGHT/,/^BLOCKED/p')
  assert_not_contains "$inflight_section" "secondmate-task" \
    "a parked task must never appear under IN FLIGHT"
  assert_contains "$view" "YOUR DECISIONS (4)" \
    "decisions should have a prominent dedicated section"
  assert_contains "$view" "! secondmate-task" \
    "live decisions should appear in the decision section"
  assert_contains "$view" "choose the public API shape" \
    "live decisions should show their one-line reason"
  assert_contains "$view" "! decision-one" \
    "queued decision holds should move out of the queue"
  assert_contains "$view" "choose API A or B" \
    "queued decision holds should show their one-line reason"
  assert_not_contains "$view" "FINISHED" \
    "history must not crowd the default utilization view"
  assert_not_contains "$view" "UNKNOWN" \
    "unreadable dispatched work must fold into IN FLIGHT"
  assert_contains "$view" "READY (0)" \
    "ready count should match the rendered ready list"
  assert_contains "$view" "BLOCKED (1)" \
    "queue summary should distinguish dispatchable from blocked"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  test_view_renders_each_section_alone
  test_view_renders_several_sections_in_priority_order
  test_view_rejects_unknown_section
  test_default_view_output_is_prioritized
  pass "fleet view renders the prioritized default, section groups, and each standalone section"
}

test_view_renders_each_section_alone() {
  local home fakebin section view heading
  home=$(make_home view-sections)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")

  for section in in-flight waiting ready blocked finished failed; do
    view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --section "$section")
    case "$section" in
      in-flight) heading='IN FLIGHT (3)' ;;
      waiting) heading='YOUR DECISIONS (4)' ;;
      ready) heading='READY (0)' ;;
      blocked) heading='BLOCKED (1)' ;;
      finished) heading='FINISHED (showing 1 of 1)' ;;
      failed) heading='FAILED (0)' ;;
    esac
    assert_contains "$view" "$heading" "$section section omitted its counted heading"
    [ "$(printf '%s\n' "$view" | grep -Ec '^(IN FLIGHT|YOUR DECISIONS|FINISHED|FAILED|READY|BLOCKED)')" -eq 1 ] \
      || fail "$section section rendered another section: $view"
  done
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --section in-flight)
  assert_contains "$view" "state unavailable" \
    "in-flight section should quietly qualify dispatched tasks with unreadable runtime state"
  assert_not_contains "$view" "UNKNOWN" \
    "in-flight section should not present unreadable runtime state as a separate category"
}

test_view_rejects_unknown_section() {
  local output rc section name
  for section in typo all; do
    set +e
    output=$($VIEW --section "$section" 2>&1)
    rc=$?
    set -e
    expect_code 2 "$rc" "an unsupported section should be a usage error"
    assert_contains "$output" "unknown section: $section" "unknown section error omitted the rejected value"
    for name in waiting ready in-flight blocked finished failed; do
      assert_contains "$output" "$name" "unknown section usage omitted the $name section"
    done
  done
  # A rejected name inside a list is rejected as itself, and nothing renders.
  set +e
  output=$($VIEW --section ready,typo 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "an unsupported section inside a list should be a usage error"
  assert_contains "$output" "unknown section: typo" \
    "a bad name inside a section list was not named on its own"
  assert_not_contains "$output" "READY (" "a rejected section list still rendered part of the fleet"
}

test_view_renders_several_sections_in_priority_order() {
  local home fakebin view expected
  home=$(make_home view-multi-section)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")

  # One pane of a cockpit region holds a group of sections, so the group has to
  # render as one panel rather than as a concatenation the caller controls.
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --section in-flight,blocked)
  assert_contains "$view" 'IN FLIGHT (3)' "a section group omitted its first section"
  assert_contains "$view" 'BLOCKED (1)' "a section group omitted its second section"
  assert_not_contains "$view" 'YOUR DECISIONS' "a section group rendered a section it was not asked for"
  assert_not_contains "$view" 'FLEET STATUS' "a section group printed the whole-panel heading"

  # Whatever order the sections are asked for, the panel reads in its own
  # priority order: decisions can never be pushed below running work.
  expected=$view
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --section blocked --section in-flight)
  [ "$view" = "$expected" ] \
    || fail "the same sections rendered differently when asked for in another order"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --section blocked,in-flight,blocked)
  [ "$view" = "$expected" ] || fail "a repeated section rendered twice"

  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --section 'in-flight, blocked')
  [ "$view" = "$expected" ] || fail "a section list written with a space was not accepted"
}

test_default_view_output_is_prioritized() {
  local home view_bin
  home=$(make_home default-view-bytes)
  view_bin="$home/bin"
  mkdir -p "$view_bin"
  ln -s "$VIEW" "$view_bin/fm-fleet-view.sh"
  ln -s "$ROOT/bin/fm-terminal-frame-lib.sh" "$view_bin/fm-terminal-frame-lib.sh"
  cat > "$view_bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"tasks":[],"backlog":{"records":[]},"secondmate_landed":{"records":[]}}'
SH
  chmod +x "$view_bin/fm-fleet-snapshot.sh"
  COLUMNS=45 "$view_bin/fm-fleet-view.sh" > "$home/actual"
  cat > "$home/expected" <<'EOF'
=============================================
FLEET STATUS
=============================================

YOUR DECISIONS (0)
  None.

READY (0)
  None.

IN FLIGHT (0)
  None.

BLOCKED (0)
  None.
EOF
  cmp -s "$home/expected" "$home/actual" \
    || fail "default panel output did not match the prioritized live-work contract"
}

test_view_buckets_reconciled_states() {
  local home fakebin view id fixture_gen working_section waiting_section finished_section failed_section
  home=$(make_home state-buckets)
  mkdir -p "$home/projects/working-ship-task" "$home/projects/parked-task" \
    "$home/projects/done-task" "$home/projects/failed-task" "$home/projects/merge-ready"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] working-ship-task - Working Task (repo: alpha) (kind: ship)
- [ ] parked-task - Parked Task (repo: alpha) (kind: ship)
- [ ] done-task - Done Task (repo: alpha) (kind: ship)
- [ ] failed-task - Failed Task (repo: alpha) (kind: ship)
- [ ] merge-ready - Merge Ready Task https://github.com/acme/alpha/pull/42 (repo: alpha) (kind: ship)
- [ ] unknown-task - Unknown Task (repo: alpha) (kind: ship)
EOF
  for id in working-ship-task parked-task done-task failed-task merge-ready unknown-task; do
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id" \
      "project=alpha" \
      "harness=claude" \
      "kind=ship" \
      "mode=ship"
    record_claude_idle "$home/state" "$id"
  done
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" working-ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" working-ship-task busy --gen "$fixture_gen" \
    --source claude-hook --event start
  printf 'needs-decision [key=gate]: choose the gate resolution\n' > "$home/state/parked-task.status"
  printf 'done: implementation complete\n' > "$home/state/done-task.status"
  printf 'failed: validation failed\n' > "$home/state/failed-task.status"
  printf 'done: implementation complete\n' > "$home/state/merge-ready.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")

  assert_contains "$view" "IN FLIGHT (2)" "working and unreadable dispatched work belong in IN FLIGHT"
  assert_contains "$view" "YOUR DECISIONS (2)" "parked decisions and merge-ready work belong in YOUR DECISIONS"
  assert_not_contains "$view" "FINISHED" "successful history should be absent from the default view"
  assert_not_contains "$view" "FAILED" "failed history should be absent from the default view"
  assert_not_contains "$view" "UNKNOWN" "indeterminate dispatched work should fold into IN FLIGHT"
  working_section=$(printf '%s\n' "$view" | sed -n '/^IN FLIGHT/,/^BLOCKED/p')
  waiting_section=$(printf '%s\n' "$view" | sed -n '/^YOUR DECISIONS/,/^READY/p')
  assert_contains "$working_section" "working-ship-task" "working task missing from IN FLIGHT"
  assert_contains "$working_section" "unknown-task" "unreadable dispatched task missing from IN FLIGHT"
  assert_not_contains "$working_section" "parked-task" "parked task leaked into IN FLIGHT"
  assert_not_contains "$working_section" "done-task" "done task leaked into IN FLIGHT"
  assert_not_contains "$working_section" "failed-task" "failed task leaked into IN FLIGHT"
  assert_contains "$waiting_section" "parked-task" "parked task missing from YOUR DECISIONS"
  assert_contains "$waiting_section" "choose the gate resolution" "parked task reason missing"
  assert_contains "$waiting_section" "merge-ready" "merge-ready task missing from YOUR DECISIONS"
  assert_contains "$waiting_section" "merge approval pending" "merge-ready action missing"
  finished_section=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --section finished)
  failed_section=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --section failed)
  assert_contains "$finished_section" "done-task" "done task missing from opt-in FINISHED"
  assert_contains "$failed_section" "failed-task" "failed task missing from opt-in FAILED"
  pass "fleet view buckets every task by reconciled state"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "• dead-secondmate ·" \
    "view should retain a degraded task row when current state is unknown"
  assert_contains "$view" "IN FLIGHT (1)" \
    "view should fold unavailable runtime state into dispatched work"
  assert_contains "$view" "state unavailable" \
    "view should quietly qualify unavailable runtime state"
  pass "fleet view degrades an unreadable task row to unknown"
}

test_oversized_backlog_and_status_stream() {
  local home fakebin json view bearings i bytes
  home=$(make_home oversized)
  printf '## Queued\n' > "$home/data/backlog.md"
  i=1
  while [ "$i" -le 2200 ]; do
    printf -- '- [ ] big-%04d - Synthetic task %04d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx (repo: firstmate) (kind: ship)\n' \
      "$i" "$i" >> "$home/data/backlog.md"
    i=$((i + 1))
  done
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/large-status.meta" \
    "window=firstmate:fm-large-status" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home"
  printf 'project=' >> "$home/state/large-status.meta"
  i=1
  while [ "$i" -le 2200 ]; do
    printf 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' >> "$home/state/large-status.meta"
    i=$((i + 1))
  done
  printf '\n' >> "$home/state/large-status.meta"
  printf 'window=' >> "$home/state/large-status.meta"
  i=1
  while [ "$i" -le 2200 ]; do
    printf 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz' >> "$home/state/large-status.meta"
    i=$((i + 1))
  done
  printf '\n' >> "$home/state/large-status.meta"
  printf 'needs-decision [key=large]: ' > "$home/state/large-status.status"
  i=1
  while [ "$i" -le 2200 ]; do
    printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >> "$home/state/large-status.status"
    i=$((i + 1))
  done
  printf '\n' >> "$home/state/large-status.status"
  fakebin=$(make_fakebin "$home")

  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json 2> "$home/oversized.err")
  assert_contains "$(cat "$home/oversized.err")" "endpoint target metadata exceeds 4096 bytes" \
    "oversized endpoint metadata should emit an explicit diagnostic"
  bytes=$(printf '%s' "$json" | wc -c | tr -d ' ')
  [ "$bytes" -gt 131072 ] || fail "synthetic snapshot did not cross the single-argument ceiling: $bytes bytes"
  printf '%s' "$json" | jq -e '(.backlog.records | length) == 2200 and (.tasks | length) == 1 and (.tasks[0].project | length) > 131072' >/dev/null \
    || fail "oversized snapshot lost backlog or task data"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" COLUMNS=60 "$VIEW")
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json)
  assert_contains "$view" "YOUR DECISIONS (1)" "oversized fleet view should still render"
  printf '%s' "$bearings" | jq -e '.schema == "fm-bearings.v1" and (.gates | length) == 20' >/dev/null \
    || fail "oversized bearings snapshot did not render its bounded projection"
  pass "oversized backlog and status payloads stream through snapshot, fleet view, and bearings"
}

tree_manifest() {  # <home>
  local home=$1 root
  for root in "$home/data" "$home/state"; do
    perl -MFile::Find -MDigest::SHA -e '
      find({no_chdir => 1, wanted => sub {
        my @s = lstat($_);
        my $digest = "-";
        if (-f _) {
          open my $fh, "<", $_ or die "$!: $_\n";
          binmode $fh;
          $digest = Digest::SHA->new(256)->addfile($fh)->hexdigest;
        }
        print join("|", $_, @s[2, 4, 5, 7, 9], $digest), "\n";
      }}, @ARGV)
    ' "$root"
  done | LC_ALL=C sort
}

test_read_paths_do_not_mutate_fleet_state() {
  local home fakebin before after
  home=$(make_home read-only)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  before=$(tree_manifest "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json >/dev/null
  PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" >/dev/null
  PATH="$fakebin:$PATH" FM_HOME="$home" "$BEARINGS" >/dev/null
  after=$(tree_manifest "$home")
  [ "$before" = "$after" ] || fail "snapshot, fleet view, or bearings modified data/ or state/"
  pass "snapshot, fleet view, and bearings leave data/ and state/ byte-for-byte and metadata-identical"
}

test_watch_redraws_and_exits_cleanly() {
  local home fakebin watch_bin output rc redraws
  home=$(make_home watch)
  fakebin=$(make_fakebin "$home")
  watch_bin="$home/bin"
  mkdir -p "$watch_bin"
  ln -s "$VIEW" "$watch_bin/fm-fleet-view.sh"
  ln -s "$ROOT/bin/fm-terminal-frame-lib.sh" "$watch_bin/fm-terminal-frame-lib.sh"
  cat > "$watch_bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"tasks":[],"backlog":{"records":[]},"secondmates":[]}'
SH
  chmod +x "$watch_bin/fm-fleet-snapshot.sh"
  output="$home/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" COLUMNS=45 \
    perl -e '
      my $pid = fork();
      defined $pid or die "fork: $!\n";
      exec @ARGV unless $pid;
      select undef, undef, undef, 0.35;
      kill "INT", $pid;
      waitpid $pid, 0;
      exit($? >> 8);
    ' "$watch_bin/fm-fleet-view.sh" --watch 0.1 > "$output"
  rc=$?
  expect_code 0 "$rc" "watch mode should exit cleanly on Ctrl-C"
  redraws=$(LC_ALL=C grep -ao $'\033\[?2026h\033\[H' "$output" | wc -l | tr -d ' ')
  [ "$redraws" -ge 2 ] || fail "watch mode did not redraw: $redraws renders"
  LC_ALL=C grep -aF $'\033[H\033[2J' "$output" >/dev/null \
    && fail "watch mode still used a full-screen erase"
  LC_ALL=C grep -aF $'\033[?2026l\033[0m' "$output" >/dev/null \
    || fail "watch mode did not close synchronized output and restore terminal attributes on exit"
  pass "watch mode redraws in a narrow pane and exits cleanly on Ctrl-C"
}

test_watch_computes_before_paint_and_erases_shorter_frames() {
  local home fakebin watch_bin output rc
  home=$(make_home watch-order)
  fakebin=$(fm_fakebin "$home")
  watch_bin="$home/bin"
  mkdir -p "$watch_bin"
  ln -s "$VIEW" "$watch_bin/fm-fleet-view.sh"
  ln -s "$ROOT/bin/fm-terminal-frame-lib.sh" "$watch_bin/fm-terminal-frame-lib.sh"
  cat > "$watch_bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{}'
SH
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
count_file=${FM_TEST_JQ_COUNT:?}
count=0
[ ! -f "$count_file" ] || read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "$count" -eq 1 ]; then
  printf 'long one\nlong two\nlong three\n'
else
  printf 'short\n'
fi
printf 'RENDERED\n' >&3
SH
  chmod +x "$watch_bin/fm-fleet-snapshot.sh" "$fakebin/jq"
  output="$home/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_JQ_COUNT="$home/jq-count" \
    perl -e '
      my $pid = fork();
      defined $pid or die "fork: $!\n";
      exec @ARGV unless $pid;
      select undef, undef, undef, 0.25;
      kill "INT", $pid;
      waitpid $pid, 0;
      exit($? >> 8);
    ' "$watch_bin/fm-fleet-view.sh" --section ready --watch 0.05 > "$output" 3>&1
  rc=$?
  expect_code 0 "$rc" "ordered watch fixture should exit cleanly"
  perl -0777 -e '
    my $s = <>;
    my $computed = index($s, "RENDERED\n");
    my $paint = index($s, "\e[?2026h\e[H");
    exit !(0 <= $computed && $computed < $paint);
  ' "$output" || fail "watch mode painted an erase sequence before frame computation completed"
  perl -0777 -e '
    my $s = <>;
    $s =~ s/RENDERED\n//g;
    my @screen;
    my $row = 0;
    my $text = "";
    while (length $s) {
      if ($s =~ s/^\e\[\?2026[hl]// || $s =~ s/^\e\[0m//) { next }
      if ($s =~ s/^\e\[H//) { $row = 0; $text = ""; next }
      if ($s =~ s/^\e\[K//) { $screen[$row] = $text; next }
      # ESC[J erases from the CURSOR to the end of the display, so whatever
      # precedes the cursor on the current row survives. Truncating from the
      # start of the row instead would model a terminal that erases text the
      # real one keeps, and would mis-score any frame whose last row is not
      # newline-terminated.
      if ($s =~ s/^\e\[J//) { $screen[$row] = $text; $#screen = $row; next }
      if ($s =~ s/^\n//) { $row++; $text = ""; next }
      $s =~ s/^(.)//s or die "unparsed terminal stream";
      $text .= $1;
    }
    pop @screen while @screen && (!defined $screen[-1] || $screen[-1] eq "");
    exit !(@screen == 1 && $screen[0] eq "short");
  ' "$output" || fail "a shorter watch frame left residual lines from the longer frame"
  pass "watch mode computes before painting and erases residual lines from shorter frames"
}

test_non_watch_outputs_remain_byte_exact() {
  local home fakebin view_bin panel json
  home=$(make_home non-watch-bytes)
  fakebin=$(fm_fakebin "$home")
  view_bin="$home/bin"
  mkdir -p "$view_bin"
  ln -s "$VIEW" "$view_bin/fm-fleet-view.sh"
  ln -s "$ROOT/bin/fm-terminal-frame-lib.sh" "$view_bin/fm-terminal-frame-lib.sh"
  cat > "$view_bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"exact":"json"}'
SH
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
printf 'plain\nframe\n'
SH
  chmod +x "$view_bin/fm-fleet-snapshot.sh" "$fakebin/jq"
  PATH="$fakebin:$PATH" "$view_bin/fm-fleet-view.sh" > "$home/panel.out"
  PATH="$fakebin:$PATH" "$view_bin/fm-fleet-view.sh" --json --section blocked > "$home/json.out"
  printf 'plain\nframe\n' > "$home/panel.expected"
  printf '%s\n' '{"exact":"json"}' > "$home/json.expected"
  cmp -s "$home/panel.expected" "$home/panel.out" \
    || fail "non-watch panel output changed bytes"
  cmp -s "$home/json.expected" "$home/json.out" \
    || fail "--json output changed bytes when combined with --section"
  panel=$(cat "$home/panel.out")
  json=$(cat "$home/json.out")
  assert_not_contains "$panel$json" $'\033[' "non-watch modes emitted terminal controls"
  pass "non-watch panel and --json output remain byte-exact"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    "window=firstmate:fm-masked-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    "window=firstmate:fm-active-secondmate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# A captain-held parking line never closes an open decision, even when it names
# the same key and says a backlog item tracks it.
test_open_decision_survives_captain_held_parking() {
  local home fakebin out
  home=$(make_home captain-held-transfer)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/transferred-decision.meta" \
    "window=firstmate:fm-transferred-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'captain-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "route"
  ' >/dev/null || fail "captain-held parking hid the unresolved status decision: $out"
  pass "captain-held parking preserves the unresolved live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    "window=firstmate:fm-resolved-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" lavish-103
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    "window=firstmate:fm-parked-scout" \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" parked-scout
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

# --- watched-banner ownership inside an adopted cockpit frame ---------------
#
# The fleet region is built by bin/backends/herdr.sh and recorded in
# state/.herdr-cockpit. These tests drive the same record and the same
# HERDR_* pane identity a real fleet pane is launched with, so they exercise
# the ownership contract through the view's own executable interface.

# The production tracked bin directory, deliberately: current isolated homes do
# not carry their own bin/, so ownership must combine that executable with the
# running pane's authoritative foreground cwd. The homes below are empty, so
# the real snapshot renders an empty board.
painter_bin() {  # <home> -> the bin dir the banner runs from
  local home=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$home/fm-herdr-pane-geometry.sh" <<'SH'
#!/usr/bin/env bash
printf '45 20\n'
SH
  chmod +x "$home/fm-herdr-pane-geometry.sh"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${PAINTER_CALLS:-$PAINTER_HOME/herdr-calls}"
mode=${PAINTER_REPORTED_MODE:-live}
script=${PAINTER_VIEW:?}
geometry=${PAINTER_GEOMETRY:-$PAINTER_HOME/fm-herdr-pane-geometry.sh}
if [ "${1:-}" = pane ] && [ "${2:-}" = close ]; then
  printf '{"result":{"type":"ok"}}\n'
  exit 0
fi
if [ "${1:-}" = pane ] && [ "${2:-}" = get ]; then
  tab=$(cat "$PAINTER_HOME/reported-tab" 2>/dev/null || printf 'w9:t1')
  cwd=$PAINTER_HOME
  [ "$mode" != home ] || cwd=/wrong/home
  jq -cn --arg pane "${HERDR_PANE_ID:?}" --arg tab "$tab" --arg cwd "$cwd" \
    '{result:{pane:{pane_id:$pane,workspace_id:"w9",tab_id:$tab,foreground_cwd:$cwd}}}'
  exit 0
fi
case "$mode" in
  executable) script=/wrong/checkout/bin/not-fleet-view.sh ;;
  basename) script=/wrong/checkout/bin/fm-fleet-view.sh ;;
esac
if [ "$mode" = watch ]; then
  argv=$(jq -cn --arg script "$script" --arg geometry "$geometry" \
    '["bash",$script,"--geometry-command",$geometry]')
else
  argv=$(jq -cn --arg script "$script" --arg geometry "$geometry" \
    --arg sections "${PAINTER_REPORTED_SECTIONS:-}" '
    ["bash",$script,"--geometry-command",$geometry,"--watch","0.1"]
    + (if $sections == "" then [] else ["--section",$sections] end)')
fi
jq -cn --arg pane "${HERDR_PANE_ID:?}" --argjson argv "$argv" '
  {result:{type:"pane_process_info",process_info:{pane_id:$pane,foreground_processes:[{argv:$argv}]}}}'
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$ROOT/bin"
}

write_cockpit_record() {  # <home> <fleet-pane-ids> <fleet-pane-sections>
  local home=$1 ids=$2 sections=$3 exact_home
  exact_home=$(CDPATH='' cd -- "$home" && pwd -P) || return 1
  cat > "$home/state/.herdr-cockpit" <<EOF
version=3
home=$exact_home
session=lab-session
workspace_id=w9
tab_id=w9:t1
head_pane_id=w9:p1
viewport_pane_id=
fleet_pane_ids=$ids
fleet_pane_sections=$sections
EOF
}

# Run a watched banner in the background and publish its pid as PAINTER_PID.
# Output and stderr land in <home>/<tag>.out and <home>/<tag>.err. Keeping the
# process as this shell's direct child makes teardown portable to Bash 3.2.
start_painter() {  # <home> <bin> <pane-id> <tag> [<section>]
  local home=$1 dir=$2 pane=$3 tag=$4 section=${5:-} geometry
  geometry=${PAINTER_GEOMETRY:-$home/fm-herdr-pane-geometry.sh}
  local -a cmd=("$dir/fm-fleet-view.sh" --geometry-command "$geometry" --watch 0.1)
  [ -z "$section" ] || cmd+=(--section "$section")
  FM_HOME="$home" COLUMNS=45 LINES=20 \
    HERDR_SESSION=lab-session HERDR_PANE_ID="$pane" HERDR_TAB_ID=w9:t1 \
    PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" PAINTER_HOME="$home" \
    PAINTER_GEOMETRY="${PAINTER_GEOMETRY:-}" \
    PAINTER_CALLS="${PAINTER_CALLS:-}" \
    PAINTER_REPORTED_SECTIONS="$section" PATH="$home/fakebin:$PATH" \
    "${cmd[@]}" > "$home/$tag.out" 2> "$home/$tag.err" &
  PAINTER_PID=$!
}

reap_painter() {  # <pid>
  kill -TERM "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

wait_for_painter_exit() {  # <pid>
  local pid=$1 waited=0
  while jobs -pr | grep -qx "$pid" && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! jobs -pr | grep -qx "$pid"
}

# Wait for a banner to actually paint rather than for a fixed interval: these
# run the production snapshot, whose cost varies with machine load, and a
# banner that has not painted yet is indistinguishable from one that refused.
wait_for_paint() {  # <file> <pattern>
  local file=$1 pattern=$2 waited=0
  while [ "$waited" -lt 300 ]; do
    [ ! -s "$file" ] || ! LC_ALL=C grep -aq "$pattern" "$file" || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

test_watch_outside_an_adopted_frame_keeps_painting() {
  local home dir pid rc
  home=$(make_home painter-standalone)
  dir=$(painter_bin "$home")
  # The documented fallback panel: a home with no adopted frame at all.
  start_painter "$home" "$dir" w9:p7 fallback
  pid=$PAINTER_PID
  wait_for_paint "$home/fallback.out" 'FLEET STATUS' \
    || { reap_painter "$pid"; fail "the fallback fleet panel painted nothing: $(cat "$home/fallback.err")"; }
  kill -0 "$pid" 2>/dev/null || fail "the fallback fleet panel must keep running with no adopted frame"
  reap_painter "$pid"

  # Same, but inside a herdr pane that belongs to a DIFFERENT tab than the
  # recorded frame: still the operator's own panel, not part of the region.
  write_cockpit_record "$home" 'w9:p2,w9:p3' 'waiting|ready'
  FM_HOME="$home" COLUMNS=45 LINES=20 \
    HERDR_SESSION=lab-session HERDR_PANE_ID=w9:p9 HERDR_TAB_ID=w9:t4 \
    PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" PAINTER_HOME="$home" PATH="$home/fakebin:$PATH" \
    "$dir/fm-fleet-view.sh" --watch 0.1 > "$home/other-tab.out" 2>&1 &
  pid=$!
  rc=0
  wait_for_paint "$home/other-tab.out" 'FLEET STATUS' || rc=1
  kill -0 "$pid" 2>/dev/null || rc=1
  reap_painter "$pid"
  [ "$rc" = 0 ] || fail "a banner on another tab must not be treated as part of the frame: $(cat "$home/other-tab.out")"
  pass "a watched banner outside the adopted fleet region keeps painting"
}

test_watch_refuses_to_paint_inside_a_bound_frame_it_is_not_recorded_for() {
  local home dir out rc
  home=$(make_home painter-unbound)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2,w9:p3' 'waiting|ready'
  # w9:p5 sits on the recorded cockpit tab but is not a recorded fleet pane:
  # exactly the stranded previous-generation banner a region rebuild leaves.
  out=$(fm_run_timed 30 env FM_HOME="$home" COLUMNS=45 LINES=20 \
    HERDR_SESSION=lab-session HERDR_PANE_ID=w9:p5 HERDR_TAB_ID=w9:t1 \
    PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" PAINTER_HOME="$home" PATH="$home/fakebin:$PATH" \
    "$dir/fm-fleet-view.sh" --watch 0.1 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "an unrecorded banner should retire cleanly, not error out"
  assert_contains "$out" 'not this frame' \
    "an unrecorded banner must say why it stopped"
  assert_not_contains "$out" 'FLEET STATUS' \
    "an unrecorded banner must not paint a single frame inside a bound cockpit"

  # A recorded pane asked for someone else's sections is equally not its owner.
  out=$(fm_run_timed 30 env FM_HOME="$home" COLUMNS=45 LINES=20 \
    HERDR_SESSION=lab-session HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t1 \
    PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" PAINTER_HOME="$home" \
    PAINTER_REPORTED_SECTIONS=waiting PATH="$home/fakebin:$PATH" \
    "$dir/fm-fleet-view.sh" --watch 0.1 --section ready 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a mismatched-section banner should retire cleanly"
  assert_not_contains "$out" 'FLEET STATUS' \
    "a banner showing sections the frame records for another pane must not paint"
  pass "a watched banner refuses to paint inside a bound frame it is not recorded for"
}

test_watch_retires_when_its_pane_leaves_the_binding() {
  local home dir pid waited
  home=$(make_home painter-retire)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2,w9:p3' 'waiting|ready'
  start_painter "$home" "$dir" w9:p2 bound waiting
  pid=$PAINTER_PID
  wait_for_paint "$home/bound.out" 'YOUR DECISIONS' \
    || { reap_painter "$pid"; fail "the recorded banner painted nothing: $(cat "$home/bound.err")"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "the recorded banner must keep painting: $(cat "$home/bound.err")"

  # The region is rebuilt: adoption records a fresh set of fleet panes and
  # leaves the previous generation's panes on screen.
  write_cockpit_record "$home" 'w9:p8,w9:p9' 'waiting|ready'
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null \
    && { reap_painter "$pid"; fail "a banner dropped from the binding kept painting"; }
  wait "$pid" 2>/dev/null || true
  assert_contains "$(cat "$home/bound.err")" 'not this frame' \
    "a retired banner must report why it stopped"
  pass "a watched banner retires once the frame stops recording its pane"
}

test_watch_retires_when_its_bound_frame_record_disappears() {
  local home dir pid waited=0
  home=$(make_home painter-record-loss)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2' 'waiting'
  start_painter "$home" "$dir" w9:p2 bound waiting
  pid=$PAINTER_PID
  wait_for_paint "$home/bound.out" 'YOUR DECISIONS' \
    || { reap_painter "$pid"; fail "the recorded banner painted nothing: $(cat "$home/bound.err")"; }
  [ -e "$home/state/.fleet-painter-w9:p2.lock" ] \
    || { reap_painter "$pid"; fail "the recorded banner did not claim its pane"; }

  rm "$home/state/.herdr-cockpit"
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null \
    && { reap_painter "$pid"; fail "a bound banner survived loss of its frame record"; }
  wait "$pid" 2>/dev/null || true
  [ ! -e "$home/state/.fleet-painter-w9:p2.lock" ] \
    || fail "a banner retired after record loss without releasing its pane"
  assert_contains "$(cat "$home/bound.err")" 'not this frame' \
    "a banner retired after record loss must report why it stopped"
  pass "a bound banner retires when its frame record disappears"
}

test_deleted_home_does_not_evict_a_live_exact_pane() {
  local home dir pid geometry calls waited=0 rc=0
  home=$(make_home painter-deleted-home-live-pane)
  dir=$(painter_bin "$home")
  geometry="$TMP_ROOT/fm-herdr-pane-geometry.sh"
  calls="$TMP_ROOT/live-pane-herdr-calls"
  printf '#!/usr/bin/env bash\nprintf "45 20\\n"\n' > "$geometry"
  chmod +x "$geometry"
  write_cockpit_record "$home" 'w9:p2' 'waiting'
  PAINTER_GEOMETRY=$geometry
  PAINTER_CALLS=$calls
  start_painter "$home" "$dir" w9:p2 bound waiting
  PAINTER_GEOMETRY=
  PAINTER_CALLS=
  pid=$PAINTER_PID
  while [ ! -e "$home/state/.fleet-painter-w9:p2.lock" ] && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$home/state/.fleet-painter-w9:p2.lock" ] \
    || { reap_painter "$pid"; fail "the recorded banner did not claim its pane before home deletion: $(cat "$home/bound.err")"; }
  wait_for_paint "$home/bound.out" 'YOUR DECISIONS' \
    || { reap_painter "$pid"; fail "the recorded banner painted nothing before home deletion: $(cat "$home/bound.err")"; }
  waited=0
  rm -rf "$home"
  while jobs -pr | grep -qx "$pid" && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  jobs -pr | grep -qx "$pid" && { reap_painter "$pid"; rc=1; }
  wait "$pid" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "a painter with a deleted home did not retire"
  [ "$(grep -c '^pane close w9:p2' "$calls" 2>/dev/null || true)" -eq 0 ] \
    || fail "home deletion closed an exact pane whose authoritative cwd remained live"
  pass "a deleted home cannot evict an exact pane with a live authoritative cwd"
}

test_watch_retires_when_its_recorded_pane_moves_to_another_tab() {
  local home dir pid waited=0
  home=$(make_home painter-tab-move)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2' 'waiting'
  start_painter "$home" "$dir" w9:p2 bound waiting
  pid=$PAINTER_PID
  wait_for_paint "$home/bound.out" 'YOUR DECISIONS' \
    || { reap_painter "$pid"; fail "the recorded banner painted nothing: $(cat "$home/bound.err")"; }
  [ -e "$home/state/.fleet-painter-w9:p2.lock" ] \
    || { reap_painter "$pid"; fail "the recorded banner did not claim its pane"; }

  printf 'w9:t4\n' > "$home/reported-tab"
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null \
    && { reap_painter "$pid"; fail "a recorded banner kept painting after its pane moved tabs"; }
  wait "$pid" 2>/dev/null || true
  [ ! -e "$home/state/.fleet-painter-w9:p2.lock" ] \
    || fail "a banner moved out of the cockpit tab retained its pane lock"
  assert_contains "$(cat "$home/bound.err")" 'not this frame' \
    "a banner moved out of the cockpit tab must report why it stopped"
  pass "a recorded banner retires when its pane moves to another tab"
}

test_watch_refuses_a_second_painter_for_one_bound_pane() {
  local home dir first second out rc
  home=$(make_home painter-single-owner)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2,w9:p3' 'waiting|ready'
  start_painter "$home" "$dir" w9:p2 owner waiting
  first=$PAINTER_PID
  # Painting proves the pane was claimed: the claim is taken before the loop.
  wait_for_paint "$home/owner.out" 'YOUR DECISIONS' \
    || { reap_painter "$first"; fail "the first banner must own its pane: $(cat "$home/owner.err")"; }

  out=$(fm_run_timed 30 env FM_HOME="$home" COLUMNS=45 LINES=20 \
    HERDR_SESSION=lab-session HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t1 \
    PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" PAINTER_HOME="$home" \
    PAINTER_REPORTED_SECTIONS=waiting PATH="$home/fakebin:$PATH" \
    "$dir/fm-fleet-view.sh" --watch 0.1 --section waiting 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a second painter for one bound pane must refuse"
  assert_contains "$out" 'already painting' \
    "the refusal must name the conflict"
  assert_not_contains "$out" 'FLEET STATUS' \
    "a refused second painter must not paint a frame"
  kill -0 "$first" 2>/dev/null \
    || fail "the refusal must leave the original owner painting"
  reap_painter "$first"

  # The owner's exit releases the pane, so the next launch takes it over
  # rather than inheriting a stale refusal.
  start_painter "$home" "$dir" w9:p2 successor waiting
  second=$PAINTER_PID
  wait_for_paint "$home/successor.out" 'YOUR DECISIONS' \
    || { reap_painter "$second"; fail "a released bound pane must accept a fresh painter: $(cat "$home/successor.err")"; }
  reap_painter "$second"
  pass "one bound cockpit pane admits exactly one painter at a time"
}

test_watch_claims_ownership_when_the_frame_is_published_after_launch() {
  local home dir first out rc waited=0
  home=$(make_home painter-late-binding)
  dir=$(painter_bin "$home")
  start_painter "$home" "$dir" w9:p2 early waiting
  first=$PAINTER_PID
  wait_for_paint "$home/early.out" 'YOUR DECISIONS' \
    || { reap_painter "$first"; fail "the pre-publication banner painted nothing: $(cat "$home/early.err")"; }
  write_cockpit_record "$home" 'w9:p2' 'waiting'
  while [ ! -e "$home/state/.fleet-painter-w9:p2.lock" ] && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$home/state/.fleet-painter-w9:p2.lock" ] \
    || { reap_painter "$first"; fail "the pre-publication banner did not claim its published binding"; }

  out=$(fm_run_timed 30 env FM_HOME="$home" COLUMNS=45 LINES=20 \
    HERDR_SESSION=lab-session HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t1 \
    PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" PAINTER_HOME="$home" \
    PAINTER_REPORTED_SECTIONS=waiting PATH="$home/fakebin:$PATH" \
    "$dir/fm-fleet-view.sh" --watch 0.1 --section waiting 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a later painter must refuse the ownership claimed after publication"
  assert_contains "$out" 'already painting' \
    "the later painter must report the post-publication owner"
  kill -0 "$first" 2>/dev/null \
    || fail "the post-publication owner must remain live"
  reap_painter "$first"
  pass "a banner launched before publication claims ownership when bound"
}

test_watch_recovers_within_the_transient_geometry_budget() {
  local home dir pid count closes
  home=$(make_home painter-geometry-recovery)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2' 'waiting'
  cat > "$home/fm-herdr-pane-geometry.sh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$PAINTER_HOME/geometry-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$PAINTER_HOME/geometry-count"
if [ "$count" -lt 3 ]; then
  exit 75
fi
printf '45 20\n'
SH
  chmod +x "$home/fm-herdr-pane-geometry.sh"
  start_painter "$home" "$dir" w9:p2 recovering waiting
  pid=$PAINTER_PID
  wait_for_paint "$home/recovering.out" 'YOUR DECISIONS' \
    || { reap_painter "$pid"; fail "a transient geometry failure did not recover within its retry budget: $(cat "$home/recovering.err")"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "a painter that recovered transient geometry was evicted"
  count=$(cat "$home/geometry-count" 2>/dev/null || printf 0)
  [ "$count" -eq 3 ] \
    || { reap_painter "$pid"; fail "transient geometry recovered after $count reads instead of the third read"; }
  closes=$(grep -c '^pane close w9:p2' "$home/herdr-calls" 2>/dev/null || true)
  [ "$closes" -eq 0 ] \
    || { reap_painter "$pid"; fail "transient geometry recovery closed its live pane"; }
  reap_painter "$pid"
  pass "a genuinely transient geometry failure recovers within the bounded retry budget"
}

test_standalone_geometry_failures_stop_without_pane_mutation() {
  local home dir geometry calls out rc count
  home=$(make_home painter-geometry-standalone)
  dir=$(painter_bin "$home")
  calls="$home/standalone-herdr-calls"
  geometry="$home/permanent-geometry"
  printf '#!/usr/bin/env bash\nexit 64\n' > "$geometry"
  chmod +x "$geometry"
  out=$(fm_run_timed 30 env FM_HOME="$home" COLUMNS=45 LINES=20 \
    PAINTER_HOME="$home" PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" \
    PAINTER_CALLS="$calls" PATH="$home/fakebin:$PATH" \
    "$dir/fm-fleet-view.sh" --geometry-command "$geometry" --watch 0.1 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "standalone permanent geometry failure must terminate"
  assert_contains "$out" 'STOPPING without pane mutation' \
    "standalone permanent geometry failure must report its non-destructive terminal path"
  assert_not_contains "$out" 'unbound variable' \
    "standalone permanent geometry failure must not expand an absent pane identity"
  [ ! -e "$calls" ] || [ "$(grep -c 'pane close' "$calls" 2>/dev/null)" -eq 0 ] \
    || fail "standalone permanent geometry failure attempted a Herdr pane close"

  geometry="$home/transient-geometry"
  cat > "$geometry" <<'SH'
#!/usr/bin/env bash
count=$(cat "$PAINTER_HOME/standalone-geometry-count" 2>/dev/null || printf 0)
printf '%s\n' "$((count + 1))" > "$PAINTER_HOME/standalone-geometry-count"
exit 75
SH
  chmod +x "$geometry"
  out=$(fm_run_timed 30 env FM_HOME="$home" COLUMNS=45 LINES=20 \
    PAINTER_HOME="$home" PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" \
    PAINTER_CALLS="$calls" PATH="$home/fakebin:$PATH" \
    "$dir/fm-fleet-view.sh" --geometry-command "$geometry" --watch 0.1 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "standalone transient geometry exhaustion must terminate"
  count=$(cat "$home/standalone-geometry-count" 2>/dev/null || printf 0)
  [ "$count" -eq 3 ] || fail "standalone transient geometry used $count attempts instead of three"
  assert_contains "$out" 'STOPPING without pane mutation' \
    "standalone transient exhaustion must report its non-destructive terminal path"
  assert_not_contains "$out" 'unbound variable' \
    "standalone transient exhaustion must not expand an absent pane identity"
  [ ! -e "$calls" ] || [ "$(grep -c 'pane close' "$calls" 2>/dev/null)" -eq 0 ] \
    || fail "standalone transient exhaustion attempted a Herdr pane close"
  pass "standalone geometry failures terminate without Herdr pane mutation"
}

test_watch_evicts_permanently_unavailable_geometry_once() {
  local home dir pid count closes
  home=$(make_home painter-geometry-permanent)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2' 'waiting'
  cat > "$home/fm-herdr-pane-geometry.sh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$PAINTER_HOME/geometry-count" 2>/dev/null || printf 0)
printf '%s\n' "$((count + 1))" > "$PAINTER_HOME/geometry-count"
exit 64
SH
  chmod +x "$home/fm-herdr-pane-geometry.sh"
  start_painter "$home" "$dir" w9:p2 permanent waiting
  pid=$PAINTER_PID
  if ! wait_for_painter_exit "$pid"; then
    reap_painter "$pid"
    fail "permanently unavailable geometry kept retrying instead of evicting its pane"
  fi
  wait "$pid" 2>/dev/null || true
  count=$(cat "$home/geometry-count" 2>/dev/null || printf 0)
  [ "$count" -eq 1 ] \
    || fail "permanent geometry was retried $count times instead of terminating on its first proof"
  closes=$(grep -c '^pane close w9:p2' "$home/herdr-calls" 2>/dev/null || true)
  [ "$closes" -eq 1 ] \
    || fail "permanent geometry issued $closes exact-pane evictions instead of one"
  assert_contains "$(cat "$home/permanent.err")" 'EVICTING fleet pane w9:p2' \
    "permanent geometry eviction was not reported loudly"
  pass "permanently unavailable geometry evicts its exact pane once without redraw retry"
}

test_watch_evicts_after_the_transient_geometry_budget() {
  local home dir pid count closes
  home=$(make_home painter-geometry-exhausted)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2' 'waiting'
  cat > "$home/fm-herdr-pane-geometry.sh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$PAINTER_HOME/geometry-count" 2>/dev/null || printf 0)
printf '%s\n' "$((count + 1))" > "$PAINTER_HOME/geometry-count"
exit 75
SH
  chmod +x "$home/fm-herdr-pane-geometry.sh"
  start_painter "$home" "$dir" w9:p2 exhausted waiting
  pid=$PAINTER_PID
  if ! wait_for_painter_exit "$pid"; then
    reap_painter "$pid"
    fail "transient geometry retried past its terminal boundary"
  fi
  wait "$pid" 2>/dev/null || true
  count=$(cat "$home/geometry-count" 2>/dev/null || printf 0)
  [ "$count" -eq 3 ] \
    || fail "the transient geometry boundary used $count reads instead of three"
  closes=$(grep -c '^pane close w9:p2' "$home/herdr-calls" 2>/dev/null || true)
  [ "$closes" -eq 1 ] \
    || fail "exhausted transient geometry issued $closes exact-pane evictions instead of one"
  assert_contains "$(cat "$home/exhausted.err")" 'after 3 consecutive attempts' \
    "the terminal retry boundary was not reported"
  pass "transient geometry retries are bounded and terminal exhaustion evicts once"
}

test_watch_refuses_a_recorded_pane_with_wrong_process_identity() {
  local home dir mode out rc
  home=$(make_home painter-process-identity)
  dir=$(painter_bin "$home")
  write_cockpit_record "$home" 'w9:p2' 'waiting'
  for mode in executable basename watch home; do
    out=$(fm_run_timed 30 env FM_HOME="$home" COLUMNS=45 LINES=20 \
      HERDR_SESSION=lab-session HERDR_PANE_ID=w9:p2 HERDR_TAB_ID=w9:t1 \
      PAINTER_VIEW="$ROOT/bin/fm-fleet-view.sh" PAINTER_HOME="$home" \
      PAINTER_REPORTED_MODE="$mode" PAINTER_REPORTED_SECTIONS=waiting \
      PATH="$home/fakebin:$PATH" \
      "$dir/fm-fleet-view.sh" --watch 0.1 --section waiting 2>&1) && rc=0 || rc=$?
    expect_code 0 "$rc" "a recorded pane with wrong $mode identity should retire cleanly"
    assert_contains "$out" 'not this frame' \
      "a recorded pane with wrong $mode identity must say why it stopped"
    assert_not_contains "$out" 'FLEET STATUS' \
      "a recorded pane with wrong $mode identity must not paint"
  done
  pass "a recorded pane paints only with the authoritative process identity"
}

test_empty_fleet_json
test_fixture_snapshot_json
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_survives_captain_held_parking
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_ready_set_agrees_with_tasks_axi
test_ready_separates_dispatchable_from_unconfirmed
test_sibling_decisions_stay_distinct_at_every_width
test_ready_counts_stay_plain_without_unconfirmed_work
test_backlog_projection_uses_one_source_image
test_view_respects_terminal_height
test_view_renders_snapshot
test_view_buckets_reconciled_states
test_view_renders_dead_secondmate_agent_status
test_oversized_backlog_and_status_stream
test_read_paths_do_not_mutate_fleet_state
test_watch_redraws_and_exits_cleanly
test_watch_computes_before_paint_and_erases_shorter_frames
test_watch_outside_an_adopted_frame_keeps_painting
test_watch_refuses_to_paint_inside_a_bound_frame_it_is_not_recorded_for
test_watch_retires_when_its_pane_leaves_the_binding
test_watch_retires_when_its_bound_frame_record_disappears
test_deleted_home_does_not_evict_a_live_exact_pane
test_watch_retires_when_its_recorded_pane_moves_to_another_tab
test_watch_refuses_a_second_painter_for_one_bound_pane
test_watch_claims_ownership_when_the_frame_is_published_after_launch
test_watch_recovers_within_the_transient_geometry_budget
test_standalone_geometry_failures_stop_without_pane_mutation
test_watch_evicts_permanently_unavailable_geometry_once
test_watch_evicts_after_the_transient_geometry_budget
test_watch_refuses_a_recorded_pane_with_wrong_process_identity
test_non_watch_outputs_remain_byte_exact
