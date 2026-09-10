#!/usr/bin/env bash
# Behavior tests for the model gut-check tool (bin/fm-model-bench.sh and
# bin/fm-model-bench-analyze.mjs).
#
# Every case here exists because a hand-run comparison got the mechanics wrong
# in one of these exact ways (docs/model-bench.md owns the list):
#   - the arithmetic cases prove active time is the sum of the arm's OWN turn
#     brackets from its session record (a two-hour gap in the middle must not
#     count) and that consumption is sliced at the completion milestone;
#   - the confirmation cases prove a running model is read from the session
#     record matched on the exact worktree, and a record that switched models
#     or belongs to another worktree is refused rather than trusted;
#   - the independence cases prove a byte-identical file across two arms voids
#     the later arm and never merges it into the comparison;
#   - the dry-run cases prove setup refuses a non-identical brief, an
#     unconfirmable model, and a source repository holding more than the
#     starting ref, and reports the launch it would perform without launching.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ANALYZE="$ROOT/bin/fm-model-bench-analyze.mjs"
BENCH="$ROOT/bin/fm-model-bench.sh"
FIXTURES="$ROOT/tests/fixtures/model-bench"
TMP_ROOT=$(fm_test_tmproot fm-model-bench)

command -v node >/dev/null 2>&1 || fail "node is required for these tests"
command -v jq >/dev/null 2>&1 || fail "jq is required for these tests"

json_field() {  # <json> <jq-expr>
  printf '%s' "$1" | jq -r "$2"
}

# --- session arithmetic: codex --------------------------------------------

test_codex_gap_sums_turn_brackets_not_wall_clock() {
  local out
  out=$("$ANALYZE" session --harness codex --workspace /work/arm \
    --record "$FIXTURES/codex-gap.jsonl") || fail "codex gap: analyze failed: $out"
  [ "$(json_field "$out" '.active_ms')" = 270000 ] \
    || fail "codex gap: active_ms must be the sum of three brackets (270000), got $(json_field "$out" '.active_ms')"
  [ "$(json_field "$out" '.wall_ms > .active_ms')" = true ] \
    || fail "codex gap: wall clock must exceed active time when a gap sits between turns"
  [ "$(json_field "$out" '.turns | length')" = 3 ] || fail "codex gap: expected 3 closed turns"
  [ "$(json_field "$out" '.usage.total')" = 5500 ] || fail "codex gap: unsliced total must be the last cumulative figure (5500)"
  [ "$(json_field "$out" '.usage.input')" = 5000 ] || fail "codex gap: input tokens"
  [ "$(json_field "$out" '.usage.cached_input')" = 4000 ] || fail "codex gap: cached input tokens"
  [ "$(json_field "$out" '.usage.output')" = 500 ] || fail "codex gap: output tokens"
  [ "$(json_field "$out" '.model_confirmed')" = true ] || fail "codex gap: single-model record must confirm"
  [ "$(json_field "$out" '.models | join(",")')" = gpt-5.6-luna ] || fail "codex gap: confirmed model"
  pass "codex: active time sums the arm's own turn brackets across a two-hour gap"
}

test_codex_milestone_slices_at_the_closing_turn() {
  local out
  out=$("$ANALYZE" session --harness codex --workspace /work/arm \
    --record "$FIXTURES/codex-gap.jsonl" --milestone 2026-09-09T12:03:00.500Z) \
    || fail "codex milestone: analyze failed: $out"
  [ "$(json_field "$out" '.slice_at')" = 2026-09-09T12:03:01.000Z ] \
    || fail "codex milestone: slice must be the close of the turn containing the milestone, got $(json_field "$out" '.slice_at')"
  [ "$(json_field "$out" '.active_ms')" = 180000 ] || fail "codex milestone: turns after the slice must not count"
  [ "$(json_field "$out" '.usage.total')" = 3300 ] || fail "codex milestone: total_token_usage must be read at the slice (3300)"
  [ "$(json_field "$out" '.turns | length')" = 2 ] || fail "codex milestone: two turns closed at the slice"
  pass "codex: consumption and active time are sliced at the completion milestone"
}

test_milestone_excludes_later_restarted_turns() {
  local out
  out=$("$ANALYZE" session --harness codex --workspace /work/arm \
    --record "$FIXTURES/codex-restart-open.jsonl" --milestone 2026-09-09T10:01:30Z) || fail "$out"
  [ "$(json_field "$out" '.slice_at')" = 2026-09-09T10:01:30.000Z ] || fail "later turn absorbed into slice"
  [ "$(json_field "$out" '.active_ms')" = 0 ] || fail "restarted work counted"
  [ "$(json_field "$out" '.open_turns')" = 1 ] || fail "unfinished turn lost"
  [ "$(json_field "$out" '.usage.total')" = 1100 ] || fail "restarted usage counted"
  [ "$(json_field "$out" '.models | join(",")')" = gpt-5.6-luna ] || fail "restarted model counted"
  assert_contains "$(json_field "$out" '.slice_note')" 'still open' "open milestone reason"
  out=$("$ANALYZE" session --harness codex --workspace /work/arm \
    --record "$FIXTURES/codex-gap.jsonl" --milestone 2026-09-09T11:00:00Z) || fail "$out"
  [ "$(json_field "$out" '.usage.total')" = 1100 ] || fail "gap milestone absorbed later usage"
  assert_contains "$(json_field "$out" '.slice_note')" 'no turn contains' "gap milestone reason"
  pass "milestone excludes later restarted turns and gaps"
}

assert_withheld_session() {
  local json=$1 arm=$2 reason=$3
  printf '%s' "$json" | jq -e --arg arm "$arm" --arg reason "$reason" '
    .arms[] | select(.arm == $arm) |
    (.withheld_reason | contains($reason)) and
    (.session.active_ms == null and .session.open_turn_ms == null and .session.turns == null and .session.usage == null) and
    (.session.models | length > 0) and (.session.records | length > 0)
  ' >/dev/null || fail "$arm numbers not withheld with diagnostic evidence"
}

test_codex_explicit_slice_uses_last_cumulative_at_or_before() {
  local out
  out=$("$ANALYZE" session --harness codex --workspace /work/arm \
    --record "$FIXTURES/codex-gap.jsonl" --at 2026-09-09T12:02:30Z) \
    || fail "codex --at: analyze failed: $out"
  [ "$(json_field "$out" '.active_ms')" = 120000 ] || fail "codex --at: only the first bracket closed by 12:02:30"
  [ "$(json_field "$out" '.usage.total')" = 1100 ] || fail "codex --at: cumulative usage at 12:02:30 is 1100"
  [ "$(json_field "$out" '.open_turns')" = 1 ] || fail "codex --at: the turn open at the slice must be reported as open"
  pass "codex: an explicit slice reads the last cumulative figure at or before it"
}

test_codex_model_switch_is_not_confirmed() {
  local out
  out=$("$ANALYZE" session --harness codex --workspace /work/arm \
    --record "$FIXTURES/codex-model-switch.jsonl") || fail "codex switch: analyze failed: $out"
  [ "$(json_field "$out" '.model_confirmed')" = false ] || fail "codex switch: two models in one record must not confirm"
  [ "$(json_field "$out" '.models | length')" = 2 ] || fail "codex switch: both models must be listed"
  [ "$(json_field "$out" '.active_ms')" = 121000 ] || fail "codex switch: an aborted turn is still a closed bracket"
  pass "codex: a record that switched models mid-run refuses confirmation"
}

test_codex_other_workspace_is_refused() {
  local out rc
  out=$("$ANALYZE" session --harness codex --workspace /work/elsewhere \
    --record "$FIXTURES/codex-gap.jsonl" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "codex workspace: a record for another worktree must be refused"
  assert_contains "$out" "/work/arm" "codex workspace: refusal must name the record's own cwd"
  pass "codex: a record whose cwd is not the arm's worktree is refused"
}

# --- session arithmetic: claude -------------------------------------------

test_claude_gap_sums_turn_durations_and_dedupes_requests() {
  local out
  out=$("$ANALYZE" session --harness claude --workspace /work/arm \
    --record "$FIXTURES/claude-gap.jsonl") || fail "claude gap: analyze failed: $out"
  [ "$(json_field "$out" '.active_ms')" = 50000 ] || fail "claude gap: active_ms must sum turn_duration records (50000)"
  [ "$(json_field "$out" '.wall_ms > .active_ms')" = true ] || fail "claude gap: wall clock must exceed active time"
  [ "$(json_field "$out" '.usage.output')" = 280 ] || fail "claude gap: duplicated requestId rows must count once (output 280)"
  [ "$(json_field "$out" '.usage.input')" = 10675 ] || fail "claude gap: input must include cache creation and cache reads (10675)"
  [ "$(json_field "$out" '.usage.cached_input')" = 9800 ] || fail "claude gap: cached input (9800)"
  [ "$(json_field "$out" '.usage.requests')" = 4 ] || fail "claude gap: four distinct requests"
  [ "$(json_field "$out" '.model_confirmed')" = true ] || fail "claude gap: synthetic rows must not break confirmation"
  [ "$(json_field "$out" '.models | join(",")')" = claude-opus-5 ] || fail "claude gap: confirmed model"
  pass "claude: active time sums turn_duration records and usage dedupes by requestId"
}

test_claude_milestone_slices_at_turn_end() {
  local out
  out=$("$ANALYZE" session --harness claude --workspace /work/arm \
    --record "$FIXTURES/claude-gap.jsonl" --milestone 2026-09-09T12:00:30Z) \
    || fail "claude milestone: analyze failed: $out"
  [ "$(json_field "$out" '.slice_at')" = 2026-09-09T12:00:40.000Z ] || fail "claude milestone: slice at the closing turn_duration"
  [ "$(json_field "$out" '.active_ms')" = 40000 ] || fail "claude milestone: the third turn must not count"
  [ "$(json_field "$out" '.usage.output')" = 250 ] || fail "claude milestone: requests after the slice must not count"
  pass "claude: consumption and active time are sliced at the completion milestone"
}

test_claude_other_workspace_is_refused() {
  local out rc
  out=$("$ANALYZE" session --harness claude --workspace /work/arm \
    --record "$FIXTURES/claude-other-workspace.jsonl" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "claude workspace: a record for another worktree must be refused"
  assert_contains "$out" "/work/other" "claude workspace: refusal must name the record's own cwd"
  pass "claude: a record whose cwd is not the arm's worktree is refused"
}

test_claude_sidechain_counts_as_spend_but_not_as_the_running_model() {
  local root enc out
  root="$TMP_ROOT/claude-sidechain/projects"
  enc=$(printf '%s' /work/arm | tr -c 'a-zA-Z0-9' '-')
  mkdir -p "$root/$enc/c1-claude-gap/subagents"
  cp "$FIXTURES/claude-gap.jsonl" "$root/$enc/c1-claude-gap.jsonl"
  cat > "$root/$enc/c1-claude-gap/subagents/agent-explore.jsonl" <<'JSONL'
{"type":"user","cwd":"/work/arm","sessionId":"c1-claude-gap","agentId":"explore","isSidechain":true,"timestamp":"2026-09-09T10:00:07.000Z","uuid":"su-1","message":{"role":"user","content":"Explore the repository."}}
{"type":"assistant","cwd":"/work/arm","sessionId":"c1-claude-gap","agentId":"explore","isSidechain":true,"timestamp":"2026-09-09T10:00:09.000Z","uuid":"sa-1","requestId":"req_sub_1","message":{"id":"msg_sub_1","model":"claude-haiku-4-5-20251001","role":"assistant","usage":{"input_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":40},"content":[{"type":"text","text":"Found it."}]}}
JSONL
  out=$("$ANALYZE" session --harness claude --workspace /work/arm --sessions-root "$root" --launched-at 2026-09-09T09:59:00Z) \
    || fail "claude sidechain: analyze failed: $out"
  [ "$(json_field "$out" '.records | length')" = 2 ] || fail "claude sidechain: the subagent transcript must be discovered beside its session"
  [ "$(json_field "$out" '.usage.output')" = 320 ] || fail "claude sidechain: subagent output must count as the arm's spend (280 + 40)"
  [ "$(json_field "$out" '.usage.requests')" = 5 ] || fail "claude sidechain: five requests including the subagent's"
  [ "$(json_field "$out" '.models | join(",")')" = claude-opus-5 ] || fail "claude sidechain: the running model is the main session's only"
  [ "$(json_field "$out" '.model_confirmed')" = true ] || fail "claude sidechain: a subagent on another model must not break confirmation"
  [ "$(json_field "$out" '.sidechain_models | join(",")')" = claude-haiku-4-5-20251001 ] || fail "claude sidechain: the subagent model is reported separately"
  [ "$(json_field "$out" '.active_ms')" = 50000 ] || fail "claude sidechain: subagent rows add no turn brackets"
  pass "claude: a subagent transcript counts as spend, is reported separately, and does not decide the running model"
}

# --- independence ----------------------------------------------------------

# make_arm_dir <dir> <relpath> <content> <touch -t stamp>: the stamp is the
# file's first-appearance time the independence check orders copies by.
make_arm_dir() {  # <dir> <relpath> <content> <stamp>
  local dir=$1 rel=$2 content=$3 stamp=$4
  mkdir -p "$dir/$(dirname "$rel")"
  printf '%s' "$content" > "$dir/$rel"
  touch -t "$stamp" "$dir/$rel"
}

test_independence_shared_file_voids_the_later_arm() {
  local base="$TMP_ROOT/indep-shared" out
  make_arm_dir "$base/a1" src/solver.py 'def solve():\n    return 42\n' 202609091000.00
  make_arm_dir "$base/a1" README.md 'arm one notes' 202609091000.00
  make_arm_dir "$base/a2" src/solver.py 'def solve():\n    return 42\n' 202609091030.00
  make_arm_dir "$base/a2" README.md 'arm two notes' 202609091030.00
  out=$("$ANALYZE" independence "a1=$base/a1" "a2=$base/a2") || fail "independence shared: analyze failed: $out"
  [ "$(json_field "$out" '.arms.a2.verdict')" = void ] || fail "independence shared: the later arm must be void, got $(json_field "$out" '.arms.a2.verdict')"
  [ "$(json_field "$out" '.arms.a1.verdict')" = independent ] || fail "independence shared: the earlier arm keeps its result"
  [ "$(json_field "$out" '.arms.a1.copied_by | join(",")')" = a2 ] || fail "independence shared: the earlier arm names who copied it"
  [ "$(json_field "$out" '.arms.a2.matches[0].path')" = src/solver.py ] || fail "independence shared: the matching path is reported"
  [ "$(json_field "$out" '.void_arms | join(",")')" = a2 ] || fail "independence shared: void_arms lists exactly a2"
  pass "independence: a byte-identical file across two arms voids the later arm"
}

test_independence_distinct_files_are_independent() {
  local base="$TMP_ROOT/indep-distinct" out
  make_arm_dir "$base/a1" src/solver.py 'def solve():\n    return 42\n' 202609091000.00
  make_arm_dir "$base/a2" src/solver.py 'def solve():\n    return 41 + 1\n' 202609091030.00
  make_arm_dir "$base/a2" src/extra.py 'x = 1\n' 202609091030.00
  out=$("$ANALYZE" independence "a1=$base/a1" "a2=$base/a2") || fail "independence distinct: analyze failed: $out"
  [ "$(json_field "$out" '.arms.a1.verdict')" = independent ] || fail "independence distinct: a1 independent"
  [ "$(json_field "$out" '.arms.a2.verdict')" = independent ] || fail "independence distinct: same path with different bytes is independent"
  [ "$(json_field "$out" '.void_arms | length')" = 0 ] || fail "independence distinct: no void arm"
  pass "independence: arms whose changed files differ are independent"
}

test_independence_equal_timestamps_void_both() {
  local base="$TMP_ROOT/indep-tie" out
  make_arm_dir "$base/a1" lib.rs 'fn main() {}' 202609091000.00
  make_arm_dir "$base/a2" lib.rs 'fn main() {}' 202609091000.00
  out=$("$ANALYZE" independence "a1=$base/a1" "a2=$base/a2") || fail "independence tie: analyze failed: $out"
  [ "$(json_field "$out" '.void_arms | sort | join(",")')" = a1,a2 ] || fail "independence tie: with no ordering evidence both arms are void"
  pass "independence: an identical file with no ordering evidence voids both arms"
}

# --- dry run ---------------------------------------------------------------

# A bench home: fake codex/claude binaries on PATH, private harness homes
# (CODEX_HOME, CLAUDE_CONFIG_DIR) seeded with one recorded session each so the
# reader self-check has something to read, and a project with one commit.
make_bench_home() {  # <name>
  local name=$1 base fakebin enc
  base="$TMP_ROOT/$name"
  mkdir -p "$base/home/data" "$base/home/state" "$base/home/config" \
    "$base/codex-home/sessions/2026/09/09" "$base/claude-home/projects"
  fakebin=$(fm_fakebin "$base")
  fm_fake_exit0 "$fakebin" codex claude
  cp "$FIXTURES/codex-gap.jsonl" "$base/codex-home/sessions/2026/09/09/rollout-2026-09-09T10-00-00-seed.jsonl"
  enc=$(printf '%s' /work/arm | tr -c 'a-zA-Z0-9' '-')
  mkdir -p "$base/claude-home/projects/$enc"
  cp "$FIXTURES/claude-gap.jsonl" "$base/claude-home/projects/$enc/seed.jsonl"
  printf '{"projects":{}}\n' > "$base/claude-home/.claude.json"
  chmod 600 "$base/claude-home/.claude.json"
  fm_git_init_commit "$base/project"
  printf '%s\n' "$base"
}

bench() {  # <base> <args...>
  local base=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$base/home" \
    FM_STATE_OVERRIDE="$base/home/state" FM_DATA_OVERRIDE="$base/home/data" FM_CONFIG_OVERRIDE="$base/home/config" \
    CODEX_HOME="$base/codex-home" CLAUDE_CONFIG_DIR="$base/claude-home" \
    PATH="$base/fakebin:$PATH" \
    "$BENCH" "$@" 2>&1
}

dry_run_args() {  # <base> [extra...]
  local base=$1
  shift
  printf '%s\n' run "$base/project" --arm codex:gpt-test-model --arm claude:claude-test-model \
    --task 'Add a file named PONG.md containing the word PONG and commit it.' \
    --feasible 'A one-file addition is achievable by any coding model.' \
    --env MTG_ORACLE_ROOT=/data/oracle --run-id mb-test --dry-run "$@"
}

test_dry_run_sets_up_verifies_and_launches_nothing() {
  local base out rc args=()
  base=$(make_bench_home dry-ok)
  mapfile -t args < <(dry_run_args "$base")
  out=$(bench "$base" "${args[@]}")
  rc=$?
  expect_code 0 "$rc" "dry run should succeed: $out"
  assert_contains "$out" "ok: a1 isolation - one remote, one ref" "a1 isolation verified"
  assert_contains "$out" "ok: a2 isolation - one remote, one ref" "a2 isolation verified"
  assert_contains "$out" "ok: a1 pre-trusted" "a1 pre-trusted"
  assert_contains "$out" "ok: codex session-record reader confirmed a model" "codex reader self-check"
  assert_contains "$out" "ok: claude session-record reader confirmed a model" "claude reader self-check"
  assert_contains "$out" "ok: briefs are byte-identical across 2 arms" "brief equality verified"
  assert_contains "$out" "would launch a1:" "the plan names a1"
  assert_contains "$out" "--harness codex --model gpt-test-model --env-file $base/home/data/mb-test/env" "a1 plan carries harness, model, and env file"
  assert_contains "$out" "--harness claude --model claude-test-model" "a2 plan carries claude"
  assert_contains "$out" "feasibility (asserted by the caller, not checked): A one-file addition" "feasibility statement is recorded in the output"
  assert_contains "$out" "dry run: nothing launched" "dry run must say it launched nothing"
  [ -z "$(find "$base/home/state" -mindepth 1 -name '*.meta' 2>/dev/null)" ] || fail "dry run left task records behind: $(find "$base/home/state" -mindepth 1 -name '*.meta')"
  # Isolation on disk: the private source holds exactly one ref, the clone has one remote.
  [ "$(git -C "$base/home/data/mb-test/arms/a1/source.git" for-each-ref --format='%(refname)' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a1 source repository must hold exactly one ref"
  [ "$(git -C "$base/home/data/mb-test/arms/a1/project" remote)" = origin ] || fail "a1 clone must have one remote"
  # Pre-trust on disk, in each harness's own shape.
  assert_grep "[projects.\"$base/home/data/mb-test/arms/a1/project\"]" "$base/codex-home/config.toml" "codex trust entry for a1"
  [ "$(jq -r --arg p "$base/home/data/mb-test/arms/a2/project" '.projects[$p].hasTrustDialogAccepted' "$base/claude-home/.claude.json")" = true ] \
    || fail "claude trust entry for a2"
  # Environment recorded once, names listed in the brief.
  assert_grep "MTG_ORACLE_ROOT=/data/oracle" "$base/home/data/mb-test/env" "env file"
  assert_grep "MTG_ORACLE_ROOT" "$base/home/data/mb-test-a1/brief.md" "brief names the environment variable"
  assert_grep "git push -u origin fm/mb-test-a1" "$base/home/data/mb-test-a1/brief.md" "brief tells the arm to push to its private origin"
  assert_no_grep "gpt-test-model" "$base/home/data/mb-test-a1/brief.md" "brief must not mention the model"
  assert_grep "Delivery contract: mode=local-only" "$base/home/data/mb-test-a1/brief.md" "brief keeps the delivery contract line"
  [ "$(node -e 'console.log((require("fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$base/claude-home/.claude.json")" = 600 ] || fail "trust store permissions changed"
  pass "dry run performs setup and verification for every arm and launches nothing"
}

test_dry_run_catches_a_source_repository_with_an_extra_ref() {
  local base out rc args=() sha
  base=$(make_bench_home dry-extra-ref)
  mapfile -t args < <(dry_run_args "$base")
  out=$(bench "$base" "${args[@]}") || fail "initial dry run failed: $out"
  sha=$(git -C "$base/project" rev-parse HEAD)
  git -C "$base/home/data/mb-test/arms/a2/source.git" update-ref refs/heads/leaked "$sha"
  out=$(bench "$base" "${args[@]}")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a source repository holding an extra ref must be refused: $out"
  assert_contains "$out" "a2: private source repository" "refusal names the arm"
  assert_contains "$out" "must hold exactly one ref" "refusal states the rule"
  assert_contains "$out" "refs/heads/leaked" "refusal lists the extra ref"
  assert_not_contains "$out" "would launch" "no plan is printed after a refusal"
  pass "dry run catches a source repository holding more than the starting ref"
}

test_isolation_ref_rules_follow_launch_state() {
  local base out args=() bare clone sha
  base=$(make_bench_home phase-refs)
  mapfile -t args < <(dry_run_args "$base")
  out=$(bench "$base" "${args[@]}") || fail "$out"
  bare="$base/home/data/mb-test/arms/a1/source.git"
  clone="$base/home/data/mb-test/arms/a1/project"
  sha=$(git -C "$base/project" rev-parse HEAD)
  git -C "$bare" update-ref refs/heads/fm/mb-test-a1 "$sha"
  out=$(bench "$base" "${args[@]}") && fail "prelaunch arm source ref accepted"
  assert_contains "$out" 'must hold exactly one ref' "prelaunch source refusal"
  git -C "$bare" update-ref -d refs/heads/fm/mb-test-a1
  git -C "$clone" update-ref refs/heads/fm/mb-test-a1 "$sha"
  out=$(bench "$base" verify mb-test) && fail "prelaunch clone arm ref accepted"
  git -C "$clone" update-ref -d refs/heads/fm/mb-test-a1
  simulate_launched_arm "$base" a1 codex unique.txt one '2026-09-09T10:02:00Z' codex-gap.jsonl
  out=$(bench "$base" verify mb-test) || fail "launched arm refs refused: $out"
  git -C "$bare" update-ref refs/heads/fm/other "$sha"
  out=$(bench "$base" verify mb-test) && fail "foreign postlaunch source ref accepted"
  assert_contains "$out" refs/heads/fm/other "foreign source ref named"
  git -C "$bare" update-ref -d refs/heads/fm/other
  git -C "$clone" update-ref refs/remotes/origin/fm/other "$sha"
  out=$(bench "$base" verify mb-test) && fail "foreign postlaunch clone ref accepted"
  pass "isolation allows only phase-appropriate exact arm refs"
}

test_dry_run_catches_a_non_identical_brief() {
  local base out rc args=()
  base=$(make_bench_home dry-brief)
  mapfile -t args < <(dry_run_args "$base")
  out=$(bench "$base" "${args[@]}") || fail "initial dry run failed: $out"
  printf 'Use the fastest approach you know.\n' >> "$base/home/data/mb-test-a2/brief.md"
  out=$(bench "$base" "${args[@]}")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a brief that differs must be refused: $out"
  assert_contains "$out" "briefs differ between a1 and a2" "refusal names the differing arms"
  assert_contains "$out" "byte-identical" "refusal states the rule"
  assert_contains "$out" "Use the fastest approach" "refusal shows the differing line"
  pass "dry run catches a non-identical brief"
}

test_dry_run_catches_an_unconfirmable_model() {
  local base out rc
  base=$(make_bench_home dry-unconfirmable)
  out=$(bench "$base" run "$base/project" --arm codex:gpt-test-model --arm grok:grok-test \
    --task 'x' --feasible 'y' --dry-run --run-id mb-grok)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an arm on a harness with no session-record reader must be refused: $out"
  assert_contains "$out" "could never have its running model confirmed" "refusal explains why grok is refused"
  assert_absent "$base/home/data/mb-grok" "a refused arm list must create no run directory"
  # A supported harness whose machine has no session record at all is equally unconfirmable.
  rm -rf "$base/codex-home/sessions"
  mkdir -p "$base/codex-home/sessions"
  out=$(bench "$base" run "$base/project" --arm codex:gpt-test-model --arm claude:claude-test-model \
    --task 'x' --feasible 'y' --dry-run --run-id mb-noreader)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a harness with no readable session record must be refused: $out"
  assert_contains "$out" "no codex session record exists" "refusal names the missing record root"
  assert_contains "$out" "could not be confirmed after launch" "refusal states the consequence"
  pass "dry run catches an unconfirmable model"
}

test_run_refuses_firstmate_owned_env_and_missing_feasibility() {
  local base out rc
  base=$(make_bench_home refusals)
  out=$(bench "$base" run "$base/project" --arm codex:a --arm claude:b --task x --feasible y --env FM_HOME=/x --dry-run --run-id mb-env)
  rc=$?
  [ "$rc" -ne 0 ] || fail "FM_HOME in --env must be refused"
  assert_contains "$out" "FM_HOME" "refusal names the variable"
  out=$(bench "$base" run "$base/project" --arm codex:a --arm claude:b --task x --dry-run --run-id mb-feas)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run without --feasible must be refused"
  assert_contains "$out" "--feasible" "refusal names the missing statement"
  out=$(bench "$base" run "$base/project" --arm codex:a --task x --feasible y --dry-run --run-id mb-one)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a single arm must be refused"
  assert_contains "$out" "at least two" "refusal states the arm minimum"
  pass "run refuses a firstmate-owned environment variable, a missing feasibility statement, and a single arm"
}

# --- report --------------------------------------------------------------

# Simulate launched arms on top of a dry run: a worktree per arm carved from
# the arm's own clone (as treehouse would), a task record naming it, a session
# record under the harness home whose cwd is that worktree, and a terminal
# status line. a3 copies a1's file wholesale, later.
simulate_launched_arm() {  # <base> <arm> <harness> <file> <content> <commit-date> <fixture>
  local base=$1 arm=$2 harness=$3 file=$4 content=$5 when=$6 fixture=$7
  local clone wt id enc rec
  clone="$base/home/data/mb-test/arms/$arm/project"
  wt="$base/pool/$arm/project"
  id="mb-test-$arm"
  rec="$base/home/data/mb-test/arms/$arm/arm"
  mkdir -p "$base/pool/$arm"
  git -C "$clone" worktree add --quiet -b "fm/$id" "$wt"
  printf '%s' "$content" > "$wt/$file"
  git -C "$wt" add "$file"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$wt" -c user.name=arm -c user.email=arm@example.invalid commit -qm "arm $arm"
  git -C "$wt" push --quiet origin "fm/$id"
  fm_write_meta "$base/home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$clone" "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" \
    "spawned_at=2026-09-09T09:59:00Z" "model=$(sed -n 's/^model=//p' "$rec")"
  printf 'launched_at=2026-09-09T09:59:00Z\nworktree=%s\n' "$wt" >> "$rec"
  if [ "$harness" = codex ]; then
    mkdir -p "$base/codex-home/sessions/2026/09/09"
    sed "s|/work/arm|$wt|g" "$FIXTURES/$fixture" > "$base/codex-home/sessions/2026/09/09/rollout-2026-09-09T10-00-00-$arm.jsonl"
  else
    enc=$(printf '%s' "$wt" | tr -c 'a-zA-Z0-9' '-')
    mkdir -p "$base/claude-home/projects/$enc"
    sed "s|/work/arm|$wt|g" "$FIXTURES/$fixture" > "$base/claude-home/projects/$enc/$arm.jsonl"
  fi
  printf 'working: setup done\ndone: ready in branch fm/%s, tests pass, tree clean, pushed\n' "$id" > "$base/home/state/$id.status"
}

test_report_confirms_models_measures_from_records_and_voids_a_copy() {
  local base out rc json
  base=$(make_bench_home report)
  out=$(bench "$base" run "$base/project" --arm codex:gpt-5.6-luna --arm claude:claude-opus-5 --arm codex:gpt-5.6-luna \
    --task 'Add a solver.' --feasible 'Feasible.' --run-id mb-test --dry-run) || fail "dry run failed: $out"
  simulate_launched_arm "$base" a1 codex solver.py 'def solve():\n    return 42\n' '2026-09-09T10:02:00Z' codex-gap.jsonl
  simulate_launched_arm "$base" a2 claude solver.py 'def solve():\n    return 6 * 7\n' '2026-09-09T10:00:24Z' claude-gap.jsonl
  simulate_launched_arm "$base" a3 codex solver.py 'def solve():\n    return 42\n' '2026-09-09T12:11:00Z' codex-gap.jsonl
  out=$(bench "$base" verify mb-test)
  rc=$?
  expect_code 0 "$rc" "verify must tolerate each arm's own pushed branch after launch: $out"
  out=$(bench "$base" report mb-test)
  rc=$?
  expect_code 0 "$rc" "report should render: $out"
  assert_contains "$out" "gpt-5.6-luna" "a1 confirmed model appears"
  assert_contains "$out" "claude-opus-5" "a2 confirmed model appears"
  assert_contains "$out" "4m 30s" "a1 active time is the sum of its turn brackets"
  assert_contains "$out" "5,500 (5,000/4,000/500)" "a1 tokens come from the rollout"
  assert_contains "$out" "50s" "a2 active time from turn_duration records"
  assert_contains "$out" "VOID: arm a3" "the copying arm is impossible to miss"
  assert_contains "$out" "solver.py" "the identical file is named"
  assert_contains "$out" "fm/mb-test-a1" "the per-arm branch is listed"
  assert_contains "$out" "feasibility (asserted by the caller, not checked): Feasible." "the feasibility assertion is in the report"
  json=$(bench "$base" report mb-test --json) || fail "json report failed"
  [ "$(json_field "$json" '.void_arms | join(",")')" = a3 ] || fail "json void_arms must be exactly a3"
  [ "$(json_field "$json" '.arms[0].session.model_confirmed')" = true ] || fail "a1 confirmed"
  [ "$(json_field "$json" '.arms[0].state')" = 'done' ] || fail "a1 state is done"
  [ "$(json_field "$json" '.arms[1].session.usage.output')" = 280 ] || fail "a2 output tokens from its transcript"
  [ "$(json_field "$json" '.arms[2].independence.verdict')" = void ] || fail "a3 void in json"
  assert_withheld_session "$json" a3 "independence void"
  [ "$(json_field "$json" '.arms[0].independence.copied_by | join(",")')" = a3 ] || fail "a1 records who copied it"
  pass "report confirms each arm's model from its own record, measures from the record, and voids the copying arm"
}

test_report_withholds_numbers_for_an_unconfirmed_model() {
  local base out json
  base=$(make_bench_home report-unconfirmed)
  out=$(bench "$base" run "$base/project" --arm codex:gpt-5.6-luna --arm claude:claude-opus-5 \
    --task 'Add a solver.' --feasible 'Feasible.' --run-id mb-test --dry-run) || fail "dry run failed: $out"
  simulate_launched_arm "$base" a1 codex solver.py 'a' '2026-09-09T10:02:00Z' codex-model-switch.jsonl
  simulate_launched_arm "$base" a2 claude other.py 'b' '2026-09-09T10:00:24Z' claude-gap.jsonl
  out=$(bench "$base" report mb-test) || fail "report failed: $out"
  assert_contains "$out" "UNCONFIRMED" "an arm whose record names two models is unconfirmed"
  assert_contains "$out" "numbers withheld" "its numbers are withheld, not printed"
  assert_not_contains "$out" "3,300" "the unconfirmed arm's token total must not appear"
  json=$(bench "$base" report mb-test --json) || fail "json report failed"
  [ "$(json_field "$json" '.arms[0].session.model_confirmed')" = false ] || fail "a1 unconfirmed in json"
  assert_withheld_session "$json" a1 "model unconfirmed"
  pass "report refuses to present numbers for an arm whose running model is not confirmed"
}

test_review_setup_regressions() {
  local base out key args=() store clone
  base=$(make_bench_home review-setup)
  mapfile -t args < <(dry_run_args "$base")
  out=$(bench "$base" "${args[@]}" --task-file /missing) && fail "exclusive task inputs accepted"
  out=$(bench "$base" run "$base/project" --arm codex:a --arm claude:b \
    --task 'Preserve literal \n and \t and C:\new\test.' --feasible yes --run-id mb-test --dry-run) || fail "$out"
  assert_grep 'Preserve literal \n and \t and C:\new\test.' "$base/home/data/mb-test-a1/brief.md" "generated brief preserves literal task bytes"
  printf '\n' >> "$base/home/data/mb-test-a2/brief.md"
  out=$(bench "$base" verify mb-test) && fail "trailing newline difference accepted"
  assert_contains "$out" 'briefs differ' "newline mismatch refusal"
  store="$base/claude-home/.claude.json"
  clone="$base/home/data/mb-test/arms/a2/project"
  jq --arg p "$clone" '.projects[$p].hasTrustDialogAccepted = false' "$store" > "$store.new"
  mv "$store.new" "$store"
  out=$(bench "$base" verify mb-test) && fail "explicit false trust accepted"
  assert_contains "$out" 'refusing to overwrite recorded trust' "trust refusal"
  [ "$(jq -r --arg p "$clone" '.projects[$p].hasTrustDialogAccepted' "$store")" = false ] || fail "trust denial changed"
  for key in HOME CODEX_HOME CLAUDE_CONFIG_DIR; do
    out=$(bench "$base" "${args[@]}" --env "$key=/elsewhere") && fail "$key override accepted"
    assert_contains "$out" "--env may not set $key" "home refusal"
  done
  pass "trust denials, literal tasks, newline differences, and harness homes"
}

test_review_report_regressions() {
  local base out json rec status arm wt name
  base=$(make_bench_home review-report)
  out=$(bench "$base" run "$base/project" --arm codex:gpt-5.6-luna --arm claude:claude-opus-5 \
    --task x --feasible yes --run-id mb-test --dry-run) || fail "$out"
  simulate_launched_arm "$base" a1 codex first.txt first '2026-09-09T10:02:00Z' codex-gap.jsonl
  simulate_launched_arm "$base" a2 claude second.txt second '2026-09-09T10:00:24Z' claude-gap.jsonl
  rec="$base/home/data/mb-test/arms/a1/arm"
  status="$base/home/state/mb-test-a1.status"
  printf 'blocked: missing input\n' > "$status"
  node -e 'require("fs").utimesSync(process.argv[1], 1788948000.875, 1788948000.875)' "$status"
  json=$(bench "$base" report mb-test --json) || fail "$json"
  [ "$(json_field "$json" '.arms[0].milestone')" = null ] || fail "parked milestone persisted"
  [ "$(json_field "$json" '.arms[0].parked')" = blocked ] || fail "parking not recorded"
  [ "$(json_field "$json" '.arms[0].parked_at')" = 2026-09-09T10:00:00.875Z ] || fail "parking timestamp lost milliseconds"
  printf 'milestone=2026-09-09T10:00:00Z\nterminal=blocked\n' >> "$rec"
  printf 'done: complete\n' >> "$status"
  node -e 'require("fs").utimesSync(process.argv[1], 1788955890.875, 1788955890.875)' "$status"
  json=$(bench "$base" report mb-test --json) || fail "$json"
  [ "$(json_field "$json" '.arms[0].session.usage.total')" = 5500 ] || fail "completion retained blocked slice"
  [ "$(json_field "$json" '.arms[0].milestone')" = 2026-09-09T12:11:30.875Z ] || fail "completion timestamp lost milliseconds"
  name=$'renamed\tfile\n.txt'
  for arm in a1 a2; do
    wt="$base/pool/$arm/project"
    git -C "$wt" mv README.md "$name"
    printf 'same addition\n' >> "$wt/$name"
    git -C "$wt" add -- "$name"
    GIT_AUTHOR_DATE='2026-09-09T13:00:00Z' GIT_COMMITTER_DATE='2026-09-09T13:00:00Z' \
      git -C "$wt" -c user.name=test -c user.email=test@example.invalid commit -qm rename
  done
  json=$(bench "$base" report mb-test --json) || fail "$json"
  [ "$(json_field "$json" '.void_arms | length')" = 2 ] || fail "renamed identical files escaped comparison"
  [ "$(printf '%s' "$json" | jq -r --arg p "$name" '.identical_pairs | any(.path == $p)')" = true ] || fail "unusual filename lost"
  git -C "$base/home/data/mb-test/arms/a1/source.git" update-ref -d refs/heads/fm/mb-test-a1
  rm -rf "$base/pool/a1"
  out=$(bench "$base" report mb-test) || fail "$out"
  assert_contains "$out" UNCHECKED "missing comparison source"
  assert_not_contains "$out" '5,500' "unchecked numbers withheld"
  json=$(bench "$base" report mb-test --json) || fail "$json"
  [ "$(json_field "$json" '.arms[0].independence.verdict')" = unchecked ] || fail "missing evidence labeled independent"
  assert_withheld_session "$json" a1 "independence unchecked"
  printf 'base_sha=0000000000000000000000000000000000000000\n' >> "$base/home/data/mb-test/run"
  json=$(bench "$base" report mb-test --json) || fail "$json"
  [ "$(json_field "$json" '.arms[1].independence.verdict')" = unchecked ] || fail "missing base labeled independent"
  pass "parking, completion reslicing, rename inventory, and unavailable evidence"
}

test_review_broadcast_concurrency() {
  local base out args=() arm
  base=$(make_bench_home review-send)
  mapfile -t args < <(dry_run_args "$base")
  out=$(bench "$base" "${args[@]}") || fail "$out"
  for arm in a1 a2; do
    printf 'worktree=unused\n' > "$base/home/state/mb-test-$arm.meta"
  done
  cat > "$base/fakebin/send" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s' "$2" > "$FM_HOME/$1.message"
i=0
while [ ! -f "$FM_HOME/mb-test-a1.message" ] || [ ! -f "$FM_HOME/mb-test-a2.message" ]; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || exit 1
  sleep .1
done
[ ! -f "$FM_HOME/fail" ] || [ "$1" != mb-test-a2 ]
SH
  chmod +x "$base/fakebin/send"
  out=$(FM_MODEL_BENCH_SEND_BIN="$base/fakebin/send" bench "$base" send mb-test 'literal \n correction') || fail "broadcast failed concurrency barrier: $out"
  cmp -s "$base/home/mb-test-a1.message" "$base/home/mb-test-a2.message" || fail "messages differ"
  touch "$base/home/fail"
  out=$(FM_MODEL_BENCH_SEND_BIN="$base/fakebin/send" bench "$base" send mb-test correction) && fail "partial delivery succeeded"
  [ "$(tail -1 "$base/home/data/mb-test/broadcasts.log" | jq -r '.failed | join(",")')" = a2 ] || fail "partial delivery not logged"
  pass "concurrent broadcasts preserve identical messages and partial failures"
}

# --- run -----------------------------------------------------------------

test_codex_gap_sums_turn_brackets_not_wall_clock
test_codex_milestone_slices_at_the_closing_turn
test_codex_explicit_slice_uses_last_cumulative_at_or_before
test_codex_model_switch_is_not_confirmed
test_codex_other_workspace_is_refused
test_claude_gap_sums_turn_durations_and_dedupes_requests
test_claude_milestone_slices_at_turn_end
test_claude_other_workspace_is_refused
test_claude_sidechain_counts_as_spend_but_not_as_the_running_model
test_independence_shared_file_voids_the_later_arm
test_independence_distinct_files_are_independent
test_independence_equal_timestamps_void_both
test_dry_run_sets_up_verifies_and_launches_nothing
test_dry_run_catches_a_source_repository_with_an_extra_ref
test_dry_run_catches_a_non_identical_brief
test_dry_run_catches_an_unconfirmable_model
test_run_refuses_firstmate_owned_env_and_missing_feasibility
test_report_confirms_models_measures_from_records_and_voids_a_copy
test_report_withholds_numbers_for_an_unconfirmed_model

test_review_setup_regressions
test_review_report_regressions
test_review_broadcast_concurrency

test_milestone_excludes_later_restarted_turns

test_isolation_ref_rules_follow_launch_state
