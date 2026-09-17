#!/usr/bin/env bash
# tests/fm-context-watch.test.sh - the live-worker context signal: the
# bin/fm-context-watch.sh reader over a task's stamped session record (claude
# and codex), and the watcher's once-per-crossing context wakes.
#
# The reader cases prove the per-harness record fields (claude assistant usage
# input + cache_creation + cache_read and isCompactSummary; codex token_count
# last_token_usage and compacted rows) fold into context, peak, and compaction
# count, and that an unbound task is refused by name rather than reported as
# zero. The watcher cases drive a real fm-watch.sh against a growing record and
# assert one durable `context` wake per warn crossing, per further step, and
# per new compaction, with unchanged records absorbed silently.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
READER="$ROOT/bin/fm-context-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-watch)

command -v node >/dev/null 2>&1 || fail "node is required for these tests"

CLAUDE_STAMP=11111111-1111-4111-8111-111111111111
CODEX_STAMP=22222222-2222-4222-8222-222222222222

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Drain and acknowledge a stopped cycle's queue so the next cycle starts clean.
ack_stopped_cycle() {  # <state>
  local state=$1 err
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  ack_drain_err "$state" "$err" >/dev/null
  rm -f "$err"
}

# --- fixture builders -------------------------------------------------------

# Bind <id> to a session store: writes the task identity and one launch receipt
# naming <harness>, <store>, and <worktree> (the exact shape
# bin/fm-task-session.mjs register appends).
bind_task() {  # <data-dir> <id> <harness> <store> <worktree> <stamp>
  local data=$1 id=$2 harness=$3 store=$4 wt=$5 stamp=$6
  mkdir -p "$data/$id/sessions" "$wt"
  printf '{"schema":"fm-task-sessions.v1","id":"%s","spawned_at":"2026-09-17T10:00:00Z"}\n' "$id" \
    > "$data/$id/sessions/identity.json"
  printf '{"stamp":"%s","harness":"%s","store":"%s","worktree":"%s"}\n' "$stamp" "$harness" "$store" "$wt" \
    >> "$data/$id/sessions/launches.jsonl"
}

claude_record_path() {  # <store> <worktree> <stamp>
  local encoded
  encoded=$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '-')
  printf '%s/projects/%s/%s.jsonl' "$1" "$encoded" "$3"
}

claude_open() {  # <store> <worktree> <stamp>
  local file
  file=$(claude_record_path "$1" "$2" "$3")
  mkdir -p "$(dirname "$file")"
  printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"2026-09-17T10:00:01.000Z","uuid":"u-1","parentUuid":null,"isSidechain":false,"message":{"role":"user","content":"go"}}\n' "$2" "$3" > "$file"
  printf '%s' "$file"
}

# One assistant row carrying <fresh> <cache_write> <cache_read>: the context it
# carried is their sum.
claude_usage() {  # <file> <worktree> <stamp> <n> <fresh> <cache_write> <cache_read>
  printf '{"type":"assistant","cwd":"%s","sessionId":"%s","timestamp":"2026-09-17T10:%02d:00.000Z","uuid":"a-%s","parentUuid":"u-1","isSidechain":false,"requestId":"req_%s","message":{"id":"msg_%s","model":"claude-opus-5","role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":40},"content":[{"type":"text","text":"step"}]}}\n' \
    "$2" "$3" "$4" "$4" "$4" "$4" "$5" "$6" "$7" >> "$1"
}

claude_compaction() {  # <file> <worktree> <stamp> <n>
  printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"2026-09-17T10:%02d:00.000Z","uuid":"c-%s","parentUuid":"u-1","isSidechain":false,"isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}\n' \
    "$2" "$3" "$4" "$4" >> "$1"
}

codex_open() {  # <store> <worktree> <stamp>
  local file
  file="$1/sessions/2026/09/17/rollout-2026-09-17T10-00-00-01a0-ctx-$3.jsonl"
  mkdir -p "$(dirname "$file")"
  printf '{"timestamp":"2026-09-17T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"01a0-ctx-%s","id":"01a0-ctx-%s","timestamp":"2026-09-17T10:00:00.000Z","cwd":"%s","originator":"%s","cli_version":"0.153.4","source":"cli"}}\n' \
    "$3" "$3" "$2" "$3" > "$file"
  printf '%s' "$file"
}

codex_usage() {  # <file> <n> <last-input> <cumulative-total>
  printf '{"timestamp":"2026-09-17T10:%02d:00.000Z","ordinal":%s,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":%s},"last_token_usage":{"input_tokens":%s,"cached_input_tokens":1000,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":%s},"model_context_window":258400},"rate_limits":null}}\n' \
    "$2" "$2" "$4" "$4" "$3" "$(( $3 + 100 ))" >> "$1"
}

codex_compaction() {  # <file> <n>
  printf '{"timestamp":"2026-09-17T10:%02d:00.000Z","ordinal":%s,"type":"compacted","payload":{"message":"","replacement_history":[]}}\n' "$2" "$2" >> "$1"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/store"
  printf '%s\n' "$home"
}

reader() {  # <home> <id>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" "$READER" "$2"
}

# --- reader: per-harness record fields -------------------------------------

test_claude_reader_folds_context_peak_and_compactions() {
  local home wt file out
  home=$(make_home claude-reader); wt="$home/wt"
  bind_task "$home/data" ctx-claude claude "$home/store" "$wt" "$CLAUDE_STAMP"
  fm_write_meta "$home/state/ctx-claude.meta" "worktree=$wt" "harness=claude" "kind=ship"
  file=$(claude_open "$home/store" "$wt" "$CLAUDE_STAMP")
  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 1 10 500 149490      # 150000 carried
  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 2 5 0 209995         # 210000 carried: crosses 200k
  claude_compaction "$file" "$wt" "$CLAUDE_STAMP" 3
  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 4 2 59998 0          # 60000 after compaction
  out=$(reader "$home" ctx-claude) || fail "claude reader failed: $out"
  [ "$out" = "context=60000 peak=210000 compactions=1 harness=claude source=$file" ] \
    || fail "claude reader line wrong: $out"
  pass "claude: context is the last assistant usage (input+cache_creation+cache_read), peak survives the compaction, isCompactSummary rows are counted"
}

test_codex_reader_folds_context_peak_and_compactions() {
  local home wt file out
  home=$(make_home codex-reader); wt="$home/wt"
  bind_task "$home/data" ctx-codex codex "$home/store" "$wt" "$CODEX_STAMP"
  fm_write_meta "$home/state/ctx-codex.meta" "worktree=$wt" "harness=codex" "kind=ship"
  file=$(codex_open "$home/store" "$wt" "$CODEX_STAMP")
  codex_usage "$file" 1 150000 150100
  codex_usage "$file" 2 250000 400200      # crosses 200k
  codex_usage "$file" 3 310000 710300      # one further 100k step
  codex_compaction "$file" 4
  codex_usage "$file" 5 40000 750400
  out=$(reader "$home" ctx-codex) || fail "codex reader failed: $out"
  [ "$out" = "context=40000 peak=310000 compactions=1 harness=codex source=$file" ] \
    || fail "codex reader line wrong: $out"
  pass "codex: context is the last token_count last_token_usage input, peak survives the compaction, compacted rows are counted"
}

test_reader_refuses_an_unbound_task_by_name() {
  local home out
  home=$(make_home unbound-reader)
  fm_write_meta "$home/state/ctx-pi.meta" "worktree=$home/wt" "harness=pi" "kind=ship"
  if out=$(reader "$home" ctx-pi 2>&1); then
    fail "an unbound task must be refused, got: $out"
  fi
  assert_contains "$out" "no session record bound" "refusal must name the missing binding"
  assert_contains "$out" "ctx-pi" "refusal must name the task"
  case "$out" in *"context="*) fail "a refusal must not print a context line: $out" ;; esac
  pass "reader: a task with no bound session record is refused by name, never reported as zero"
}

test_reader_counts_restarts_across_launches() {
  local home wt first second out
  home=$(make_home restart-reader); wt="$home/wt"
  bind_task "$home/data" ctx-restart claude "$home/store" "$wt" "$CLAUDE_STAMP"
  fm_write_meta "$home/state/ctx-restart.meta" "worktree=$wt" "harness=claude" "kind=ship"
  first=$(claude_open "$home/store" "$wt" "$CLAUDE_STAMP")
  claude_usage "$first" "$wt" "$CLAUDE_STAMP" 1 0 0 230000
  claude_compaction "$first" "$wt" "$CLAUDE_STAMP" 2
  claude_usage "$first" "$wt" "$CLAUDE_STAMP" 3 0 0 30000
  # A relaunch appends a second receipt and opens a second record.
  printf '{"stamp":"%s","harness":"claude","store":"%s","worktree":"%s"}\n' "$CODEX_STAMP" "$home/store" "$wt" \
    >> "$home/data/ctx-restart/sessions/launches.jsonl"
  second=$(claude_open "$home/store" "$wt" "$CODEX_STAMP")
  claude_usage "$second" "$wt" "$CODEX_STAMP" 1 0 0 80000
  out=$(reader "$home" ctx-restart) || fail "restart reader failed: $out"
  [ "$out" = "context=80000 peak=230000 compactions=1 harness=claude source=$second" ] \
    || fail "restart reader line wrong: $out"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    node "$ROOT/bin/fm-context-watch.mjs" read ctx-restart) || fail "restart json read failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.restarts')" = 1 ] || fail "restarts must count receipts beyond the first: $out"
  [ "$(printf '%s' "$out" | jq -r '.launches')" = 2 ] || fail "launches must count every receipt: $out"
  pass "reader: context follows the newest launch while peak and compactions accumulate across restarts"
}

# --- usage: where the task's tokens went, per tool and per turn -------------

usage_reader() {  # <home> <id>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    node "$ROOT/bin/fm-context-watch.mjs" usage "$2"
}

# One assistant row carrying one tool_use block. Rows sharing <request> are one
# model request, exactly as claude writes one row per content block.
claude_tool_use() {  # <file> <worktree> <stamp> <minute> <request> <tool-id> <tool-name> <input-json> <context> <output>
  printf '{"type":"assistant","cwd":"%s","sessionId":"%s","timestamp":"2026-09-17T10:%02d:00.000Z","uuid":"a-%s","parentUuid":"u-1","isSidechain":false,"requestId":"req_%s","message":{"id":"msg_%s","model":"claude-opus-5","role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":%s},"content":[{"type":"tool_use","id":"%s","name":"%s","input":%s}]}}\n' \
    "$2" "$3" "$4" "$6" "$5" "$5" "$9" "${10}" "$6" "$7" "$8" >> "$1"
}

claude_tool_result() {  # <file> <worktree> <stamp> <minute> <second> <tool-id> <content-string>
  printf '{"type":"user","cwd":"%s","sessionId":"%s","timestamp":"2026-09-17T10:%02d:%02d.000Z","uuid":"r-%s","parentUuid":"u-1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s"}]}}\n' \
    "$2" "$3" "$4" "$5" "$6" "$6" "$7" >> "$1"
}

codex_call() {  # <file> <minute> <second> <ordinal> <type> <call-id> <name> <payload-field-json>
  printf '{"timestamp":"2026-09-17T10:%02d:%02d.000Z","ordinal":%s,"type":"response_item","payload":{"type":"%s","call_id":"%s","name":"%s",%s}}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$1"
}

codex_output() {  # <file> <minute> <second> <ordinal> <type> <call-id> <output-json>
  printf '{"timestamp":"2026-09-17T10:%02d:%02d.000Z","ordinal":%s,"type":"response_item","payload":{"type":"%s","call_id":"%s","output":%s}}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" >> "$1"
}

codex_count() {  # <file> <minute> <second> <ordinal> <last-input> <last-output> <cumulative-total>
  printf '{"timestamp":"2026-09-17T10:%02d:%02d.000Z","ordinal":%s,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":%s},"last_token_usage":{"input_tokens":%s,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":%s,"reasoning_output_tokens":0,"total_tokens":%s},"model_context_window":258400},"rate_limits":null}}\n' \
    "$2" "$3" "$4" "$7" "$7" "$5" "$6" "$(( $5 + $6 ))" >> "$1"
}

test_claude_usage_folds_tools_classes_and_turns() {
  local home wt file out
  home=$(make_home claude-usage); wt="$home/wt"
  bind_task "$home/data" use-claude claude "$home/store" "$wt" "$CLAUDE_STAMP"
  file=$(claude_open "$home/store" "$wt" "$CLAUDE_STAMP")
  claude_tool_use "$file" "$wt" "$CLAUDE_STAMP" 1 1 tu-1 Bash '{"command":"rg -n foo src"}' 60000 50
  claude_tool_result "$file" "$wt" "$CLAUDE_STAMP" 1 2 tu-1 'src/a.ts:1:foo'
  claude_tool_use "$file" "$wt" "$CLAUDE_STAMP" 2 2 tu-2 Read '{"file_path":"src/a.ts"}' 61000 80
  claude_tool_result "$file" "$wt" "$CLAUDE_STAMP" 2 5 tu-2 "$(printf 'x%.0s' $(seq 1 400))"
  # Two tool_use blocks in one request are one turn with two calls.
  claude_tool_use "$file" "$wt" "$CLAUDE_STAMP" 3 3 tu-3 Bash '{"command":"cd sub && npm test"}' 62000 120
  claude_tool_use "$file" "$wt" "$CLAUDE_STAMP" 3 3 tu-4 Bash '{"command":"git status"}' 62000 120
  claude_tool_result "$file" "$wt" "$CLAUDE_STAMP" 3 10 tu-3 "$(printf 'y%.0s' $(seq 1 40))"
  claude_tool_result "$file" "$wt" "$CLAUDE_STAMP" 3 12 tu-4 'clean'
  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 4 65000 0 0                   # a text-only turn
  out=$(usage_reader "$home" use-claude) || fail "claude usage reader failed: $out"
  printf '%s' "$out" | jq -e '
    .schema == "fm-task-tool-usage.v1" and .task == "use-claude" and .harness == "claude" and .status == "present"
    and .turns == 4 and .tool_calls == 4 and .base_prompt_tokens_est == 60000
    and .assistant_output_tokens == 290 and .tool_result_bytes == 459 and .tool_result_tokens_est == 115' \
    >/dev/null || fail "claude usage totals wrong: $out"
  printf '%s' "$out" | jq -e '
    (.tools | map({tool_name, tool_class, calls, result_bytes, result_tokens_est, wall_seconds_in_tool}))
    == [{"tool_name":"Bash","tool_class":"git","calls":1,"result_bytes":5,"result_tokens_est":2,"wall_seconds_in_tool":12},
        {"tool_name":"Bash","tool_class":"search","calls":1,"result_bytes":14,"result_tokens_est":4,"wall_seconds_in_tool":2},
        {"tool_name":"Bash","tool_class":"test","calls":1,"result_bytes":40,"result_tokens_est":10,"wall_seconds_in_tool":10},
        {"tool_name":"Read","tool_class":"read","calls":1,"result_bytes":400,"result_tokens_est":100,"wall_seconds_in_tool":5}]' \
    >/dev/null || fail "claude per-tool rows wrong: $out"
  printf '%s' "$out" | jq -e '
    (.classes | map([.tool_class, .calls, .result_tokens_est, .wall_seconds_in_tool]))
    == [["read",1,100,5],["search",1,4,2],["test",1,10,10],["git",1,2,12]]' \
    >/dev/null || fail "claude class roll-up wrong: $out"
  printf '%s' "$out" | jq -e '
    (.largest | map([.rank, .tool_name, .tool_class, .tokens_est, .command_or_input_head]))
    == [[1,"Read","read",100,"src/a.ts"],[2,"Bash","test",10,"cd sub && npm test"],[3,"Bash","search",4,"rg -n foo src"],[4,"Bash","git",2,"git status"]]' \
    >/dev/null || fail "claude largest results wrong: $out"
  printf '%s' "$out" | jq -e '
    (.timeline | map([.turn_index, .ts, .context_tokens, .output_tokens, .tool_name, .tool_class, .tool_result_tokens_est]))
    == [[1,"2026-09-17T10:01:00.000Z",60000,50,"Bash","search",4],
        [2,"2026-09-17T10:02:00.000Z",61000,80,"Read","read",100],
        [3,"2026-09-17T10:03:00.000Z",62000,120,"Bash","test",12],
        [4,"2026-09-17T10:04:00.000Z",65000,40,null,null,0]]' \
    >/dev/null || fail "claude turn timeline wrong: $out"
  pass "claude usage: tool_use/tool_result pairs fold into per-tool, per-class, largest-result, and per-turn rows with ceil(bytes/4) estimates"
}

test_usage_classifies_quoted_redirects() {
  local home wt file out command input i=0
  home=$(make_home quoted-redirects); wt="$home/wt"
  bind_task "$home/data" use-quotes claude "$home/store" "$wt" "$CLAUDE_STAMP"
  file=$(claude_open "$home/store" "$wt" "$CLAUDE_STAMP")
  while IFS= read -r command; do
    i=$((i + 1))
    input=$(jq -cn --arg command "$command" '{command: $command}')
    claude_tool_use "$file" "$wt" "$CLAUDE_STAMP" "$i" "$i" "tu-$i" Bash "$input" 60000 50
    claude_tool_result "$file" "$wt" "$CLAUDE_STAMP" "$i" 2 "tu-$i" 'done'
  done <<'COMMANDS'
cat input > "output file"
cat input > 'output file'
rg pattern input >> "output file"
printf 'a -> b'
printf "a -> b"
cat input > output
cat input
jq 'select(.n > 1) | .x' data.json
awk '$3 > 100 {print $1}; END {print NR}' file
node -e "console.log(1 > 0); process.exit(0)"
echo "a; b > c"
echo "a; b > c" && rg foo src > hits.txt
cat input &> out.log
cat input &>> out.log
cat input &> /dev/null
cat input 2>&1
cat input >&2
COMMANDS
  out=$(usage_reader "$home" use-quotes) || fail "quoted redirect usage failed: $out"
  printf '%s' "$out" | jq -e '
    (.timeline | map(.tool_class))
    == ["edit","edit","edit","other","other","edit","read",
        "read","read","other","other","edit","edit","edit","read","read","read"]' \
    >/dev/null || fail "quoted redirect classes wrong: $out"
  pass "usage distinguishes quoted redirect destinations and quoted separators from literal arrows"
}

test_codex_usage_folds_tools_classes_and_turns() {
  local home wt file out
  home=$(make_home codex-usage); wt="$home/wt"
  bind_task "$home/data" use-codex codex "$home/store" "$wt" "$CODEX_STAMP"
  file=$(codex_open "$home/store" "$wt" "$CODEX_STAMP")
  codex_call "$file" 1 0 1 custom_tool_call c1 exec '"input":"text(await tools.exec_command({cmd:\"cat README.md\"}));"'
  codex_output "$file" 1 3 2 custom_tool_call_output c1 '[{"type":"input_text","text":"hello world!"}]'
  codex_count "$file" 1 4 3 900 100 1000
  codex_call "$file" 2 0 4 function_call c2 shell '"arguments":"{\"command\":[\"bash\",\"-lc\",\"cargo test\"]}"'
  codex_output "$file" 2 30 5 function_call_output c2 '"ok"'
  codex_count "$file" 2 31 6 900 100 1000                      # a repeat without advance is not a turn
  codex_count "$file" 2 32 7 1100 200 2300
  codex_call "$file" 3 0 8 custom_tool_call c3 apply_patch '"input":"*** Begin Patch\n*** End Patch"'
  codex_output "$file" 3 1 9 custom_tool_call_output c3 '"Done"'
  codex_count "$file" 3 2 10 1200 100 3600
  out=$(usage_reader "$home" use-codex) || fail "codex usage reader failed: $out"
  printf '%s' "$out" | jq -e '
    .harness == "codex" and .status == "present" and .turns == 3 and .tool_calls == 3
    and .base_prompt_tokens_est == 900 and .assistant_output_tokens == 400
    and .tool_result_bytes == 18 and .tool_result_tokens_est == 5' \
    >/dev/null || fail "codex usage totals wrong: $out"
  printf '%s' "$out" | jq -e '
    (.tools | map([.tool_name, .tool_class, .calls, .result_bytes, .result_tokens_est, .wall_seconds_in_tool]))
    == [["apply_patch","edit",1,4,1,1],["exec","read",1,12,3,3],["shell","test",1,2,1,30]]' \
    >/dev/null || fail "codex per-tool rows wrong: $out"
  printf '%s' "$out" | jq -e '
    (.timeline | map([.turn_index, .context_tokens, .output_tokens, .tool_name, .tool_class, .tool_result_tokens_est]))
    == [[1,900,100,"exec","read",3],[2,1100,200,"shell","test",1],[3,1200,100,"apply_patch","edit",1]]' \
    >/dev/null || fail "codex turn timeline wrong: $out"
  printf '%s' "$out" | jq -e '(.largest | map(.command_or_input_head)) == ["cat README.md", "*** Begin Patch *** End Patch", "cargo test"]' \
    >/dev/null || fail "codex heads should be the command each call ran, unwrapped from its script or shell array: $out"
  pass "codex usage: function_call/custom_tool_call outputs fold by call_id and token_count closes each turn only when the cumulative total advances"
}

test_usage_reports_bound_records_without_a_request_as_unavailable() {
  local home wt out
  home=$(make_home empty-usage); wt="$home/wt"
  bind_task "$home/data" use-empty claude "$home/store" "$wt" "$CLAUDE_STAMP"
  claude_open "$home/store" "$wt" "$CLAUDE_STAMP" >/dev/null
  out=$(usage_reader "$home" use-empty) || fail "an empty bound record must still print a usage object: $out"
  printf '%s' "$out" | jq -e '.status == "unavailable" and .turns == 0 and (.reason | test("no model request"))' \
    >/dev/null || fail "empty record must be reported unavailable, not as zeros: $out"
  if out=$(usage_reader "$home" use-nobody 2>&1); then
    fail "an unbound task must be refused: $out"
  fi
  assert_contains "$out" "no session record bound" "usage refusal must name the missing binding"
  pass "usage: bound records with no model request are unavailable by name, and an unbound task is refused"
}

# --- watcher: one wake per crossing, step, and compaction ------------------

watch_ctx() {  # <home> <fakebin> <out> [env...]
  local home=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

wait_live() {  # <pid> [ticks]
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_exit() {  # <pid> [ticks]
  local pid=$1 limit=${2:-60} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

expect_wake() {  # <home> <fakebin> <out> <expected-reason> <label>
  local home=$1 fakebin=$2 out=$3 want=$4 label=$5 pid
  : > "$out"
  watch_ctx "$home" "$fakebin" "$out"
  pid=$!
  if ! wait_exit "$pid" 80; then
    reap "$pid"; fail "$label: watcher did not exit on the context wake; output: $(cat "$out")"
  fi
  [ "$(cat "$out")" = "$want" ] || fail "$label: wake reason wrong: got '$(cat "$out")', want '$want'"
  grep -q "$(printf '\tcontext\tctx-live\t')" "$home/state/.wake-queue" \
    || fail "$label: no durable context wake record for the task: $(cat "$home/state/.wake-queue" 2>/dev/null)"
  grep -Fq "$want" "$home/state/.wake-queue" || fail "$label: durable record lacks the reason"
  ack_stopped_cycle "$home/state" || fail "$label: could not acknowledge the wake"
}

expect_quiet() {  # <home> <fakebin> <out> <label>
  local home=$1 fakebin=$2 out=$3 label=$4 pid
  : > "$out"
  watch_ctx "$home" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "$label: watcher exited without a change: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "$label: printed a wake with no change: $(cat "$out")"
  [ ! -s "$home/state/.wake-queue" ] || fail "$label: enqueued a wake with no change: $(cat "$home/state/.wake-queue")"
  ack_stopped_cycle "$home/state" || fail "$label: could not acknowledge the intentional watcher stop"
}

test_watcher_wakes_once_per_crossing_step_and_compaction() {
  local dir home fakebin out wt file
  dir=$(make_case ctx-live); home=$dir; fakebin="$dir/fakebin"; out="$dir/watch.out"; wt="$home/wt"
  mkdir -p "$home/data" "$home/store"
  bind_task "$home/data" ctx-live claude "$home/store" "$wt" "$CLAUDE_STAMP"
  fm_write_meta "$home/state/ctx-live.meta" "worktree=$wt" "harness=claude" "kind=ship"
  file=$(claude_open "$home/store" "$wt" "$CLAUDE_STAMP")
  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 1 0 0 150000
  expect_quiet "$home" "$fakebin" "$out" "below the warn threshold"
  [ -s "$home/state/ctx-live.context-watch" ] || fail "the watcher did not record the task's context cache"

  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 2 0 0 210000
  expect_wake "$home" "$fakebin" "$out" "context: ctx-live 210k tokens (warn 200k)" "first crossing"
  expect_quiet "$home" "$fakebin" "$out" "unchanged record after the crossing"

  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 3 0 0 250000
  expect_quiet "$home" "$fakebin" "$out" "growth inside the same step"

  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 4 0 0 310000
  expect_wake "$home" "$fakebin" "$out" "context: ctx-live 310k tokens (warn 200k)" "next 100k step"

  claude_compaction "$file" "$wt" "$CLAUDE_STAMP" 5
  expect_wake "$home" "$fakebin" "$out" "context: ctx-live compacted (n=1)" "compaction"
  expect_quiet "$home" "$fakebin" "$out" "unchanged record after the compaction"

  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 6 0 0 50000
  expect_quiet "$home" "$fakebin" "$out" "first measurement after compaction"

  # Climbing back over the threshold after a compaction is a fresh crossing.
  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 7 0 0 220000
  expect_wake "$home" "$fakebin" "$out" "context: ctx-live 220k tokens (warn 200k)" "re-crossing after compaction"
  pass "watcher: one context wake per warn crossing, per further step, and per new compaction; unchanged records are absorbed"
}

test_watcher_honours_warn_and_step_overrides() {
  local dir home fakebin out wt file
  dir=$(make_case ctx-override); home=$dir; fakebin="$dir/fakebin"; out="$dir/watch.out"; wt="$home/wt"
  mkdir -p "$home/data" "$home/store"
  bind_task "$home/data" ctx-live claude "$home/store" "$wt" "$CLAUDE_STAMP"
  fm_write_meta "$home/state/ctx-live.meta" "worktree=$wt" "harness=claude" "kind=ship"
  file=$(claude_open "$home/store" "$wt" "$CLAUDE_STAMP")
  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 1 0 0 55000
  : > "$out"
  FM_CONTEXT_WARN_TOKENS=50000 FM_CONTEXT_WARN_STEP=20000 watch_ctx "$home" "$fakebin" "$out"
  wait_exit $! 80 || { reap $!; fail "override: watcher did not exit on the lowered threshold"; }
  [ "$(cat "$out")" = "context: ctx-live 55k tokens (warn 50k)" ] || fail "override: reason wrong: $(cat "$out")"
  ack_stopped_cycle "$home/state" || fail "override: could not acknowledge"
  claude_usage "$file" "$wt" "$CLAUDE_STAMP" 2 0 0 72000
  : > "$out"
  FM_CONTEXT_WARN_TOKENS=50000 FM_CONTEXT_WARN_STEP=20000 watch_ctx "$home" "$fakebin" "$out"
  wait_exit $! 80 || { reap $!; fail "override: watcher did not exit on the lowered step"; }
  [ "$(cat "$out")" = "context: ctx-live 72k tokens (warn 50k)" ] || fail "override step: reason wrong: $(cat "$out")"
  pass "watcher: FM_CONTEXT_WARN_TOKENS and FM_CONTEXT_WARN_STEP set the crossing and the step"
}

test_watcher_skips_unbound_and_secondmate_tasks() {
  local dir home fakebin out
  dir=$(make_case ctx-skip); home=$dir; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$home/data"
  fm_write_meta "$home/state/ctx-pi.meta" "worktree=$home/wt" "harness=pi" "kind=ship"
  fm_write_meta "$home/state/ctx-mate.meta" "worktree=$home/mate" "harness=claude" "kind=secondmate"
  expect_quiet "$home" "$fakebin" "$out" "unbound and secondmate tasks"
  [ ! -e "$home/state/ctx-mate.context-watch" ] || fail "a secondmate must not be context-watched"
  pass "watcher: tasks without a bound record and secondmates never produce a context wake"
}

tick() {  # <home> [env...]
  local home=$1
  shift
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$@" \
    node "$ROOT/bin/fm-context-watch.mjs" tick
}

test_tick_rebinds_a_relaunch_whose_record_appears_later() {
  local home wt first second out
  home=$(make_home rebind); wt="$home/wt"
  bind_task "$home/data" ctx-rebind claude "$home/store" "$wt" "$CLAUDE_STAMP"
  fm_write_meta "$home/state/ctx-rebind.meta" "worktree=$wt" "harness=claude" "kind=ship"
  first=$(claude_open "$home/store" "$wt" "$CLAUDE_STAMP")
  claude_usage "$first" "$wt" "$CLAUDE_STAMP" 1 0 0 150000
  out=$(tick "$home") || fail "first tick failed: $out"
  [ -z "$out" ] || fail "first tick owed a wake below the threshold: $out"
  [ "$(jq -r '.records | length' "$home/state/ctx-rebind.context-watch")" = 1 ] || fail "first launch not bound"
  # A relaunch appends its receipt before its record exists: the bind fails,
  # but the record already bound keeps folding and owes its crossing.
  printf '{"stamp":"%s","harness":"claude","store":"%s","worktree":"%s"}\n' "$CODEX_STAMP" "$home/store" "$wt" \
    >> "$home/data/ctx-rebind/sessions/launches.jsonl"
  claude_usage "$first" "$wt" "$CLAUDE_STAMP" 2 0 0 210000
  sleep 1.1
  out=$(tick "$home" FM_CONTEXT_BIND_RETRY_SECS=1) || fail "tick during the unbound relaunch failed: $out"
  [ "$out" = "$(printf 'ctx-rebind\tcontext: ctx-rebind 210k tokens (warn 200k)\t200000\t0\t0')" ] \
    || fail "the already-bound record stopped folding during an unbound relaunch: $out"
  [ "$(jq -r '.refusal // ""' "$home/state/ctx-rebind.context-watch")" != "" ] || fail "the failed bind was not recorded"
  # The record lands; the throttle elapses; the next tick binds both launches.
  second=$(claude_open "$home/store" "$wt" "$CODEX_STAMP")
  claude_usage "$second" "$wt" "$CODEX_STAMP" 1 0 0 30000
  sleep 1.1
  out=$(tick "$home" FM_CONTEXT_BIND_RETRY_SECS=1) || fail "rebinding tick failed: $out"
  [ "$(jq -r '[(.records | length), .launches, .restarts, .context, .peak, .refusal] | @tsv' "$home/state/ctx-rebind.context-watch")" \
    = "$(printf '2\t2\t1\t30000\t210000\t')" ] \
    || fail "relaunch was not rebound once its record appeared: $(cat "$home/state/ctx-rebind.context-watch")"
  pass "tick: a relaunch is rebound once its record exists, while the earlier record keeps folding meanwhile"
}

test_context_is_a_durable_wake_kind() {
  local dir state
  dir=$(make_case ctx-kind); state="$dir/state"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append context ctx-kind "context: ctx-kind 210k tokens (warn 200k)"' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail "fm_wake_append must accept the context kind"
  grep -q "$(printf '\tcontext\tctx-kind\tcontext: ctx-kind 210k tokens (warn 200k)')" "$state/.wake-queue" \
    || fail "context record not written: $(cat "$state/.wake-queue")"
  [ "$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_queued_keys context' _ "$ROOT/bin/fm-wake-lib.sh")" = ctx-kind ] \
    || fail "queued context keys must be listable"
  pass "context is a durable wake kind the queue accepts and lists"
}

test_tick_unread_aggregates_remain_null() {
  local home wt out file
  home=$(make_home unread); wt="$home/wt"
  bind_task "$home/data" ctx-unread claude "$home/store" "$wt" "$CLAUDE_STAMP"
  fm_write_meta "$home/state/ctx-unread.meta" "worktree=$wt" "harness=claude" "kind=ship"
  out=$(tick "$home") || fail "unread tick failed: $out"
  jq -e '.context == null and .peak == null and .compactions == null and .refusal != null' \
    "$home/state/ctx-unread.context-watch" >/dev/null || fail "unread cache reports measured aggregates"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "unread snapshot failed"
  printf '%s' "$out" | jq -e '.tasks[] | select(.id == "ctx-unread") | .context_tokens == null and .context_peak_tokens == null and .compactions == null' \
    >/dev/null || fail "unread snapshot reports measured aggregates: $out"
  file=$(claude_open "$home/store" "$wt" "$CLAUDE_STAMP")
  sleep 1.1
  out=$(tick "$home" FM_CONTEXT_BIND_RETRY_SECS=1) || fail "read tick failed: $out"
  jq -e '.context == null and .peak == 0 and .compactions == 0' \
    "$home/state/ctx-unread.context-watch" >/dev/null || fail "read record lacks measured aggregates"
  pass "unread aggregates stay null through failed binding and snapshot rendering"
}

test_codex_compaction_invalidates_stale_usage() {
  local home wt file out
  home=$(make_home codex-stale); wt="$home/wt"
  bind_task "$home/data" ctx-stale codex "$home/store" "$wt" "$CODEX_STAMP"
  fm_write_meta "$home/state/ctx-stale.meta" "worktree=$wt" "harness=codex" "kind=ship"
  file=$(codex_open "$home/store" "$wt" "$CODEX_STAMP")
  codex_usage "$file" 1 310000 310100
  codex_compaction "$file" 2
  out=$(tick "$home") || fail "compaction tick failed: $out"
  [ "$out" = "$(printf 'ctx-stale\tcontext: ctx-stale compacted (n=1)\t0\t1\t0')" ] || fail "stale usage emitted a threshold wake: $out"
  printf 'warned=0\ncompactions=1\nrestarts=0\n' > "$home/state/.context-surfaced-ctx-stale"
  out=$(tick "$home") || fail "unchanged tick failed"
  [ -z "$out" ] || fail "cached stale usage emitted a wake: $out"
  codex_usage "$file" 3 220000 530200
  out=$(tick "$home") || fail "fresh measurement tick failed"
  [ "$out" = "$(printf 'ctx-stale\tcontext: ctx-stale 220k tokens (warn 200k)\t200000\t1\t0')" ] || fail "fresh crossing missing: $out"
  pass "codex compaction invalidates stale usage until a fresh measurement"
}

test_cross_harness_relaunches() {
  local before after home wt first second out cache
  for before in claude codex; do
    if [ "$before" = claude ]; then after=codex; else after=claude; fi
    home=$(make_home "transition-$before"); wt="$home/wt"
    bind_task "$home/data" ctx-switch "$before" "$home/store" "$wt" "$CLAUDE_STAMP"
    fm_write_meta "$home/state/ctx-switch.meta" "worktree=$wt" "harness=$before" "kind=ship"
    first=$("${before}_open" "$home/store" "$wt" "$CLAUDE_STAMP")
    if [ "$before" = claude ]; then
      claude_usage "$first" "$wt" "$CLAUDE_STAMP" 1 0 0 310000
      claude_compaction "$first" "$wt" "$CLAUDE_STAMP" 2
      claude_usage "$first" "$wt" "$CLAUDE_STAMP" 3 0 0 50000
    else
      codex_usage "$first" 1 310000 310100
      codex_compaction "$first" 2
      codex_usage "$first" 3 50000 360200
    fi
    out=$(tick "$home") || fail "initial $before tick failed: $out"
    printf 'warned=300000\ncompactions=1\nrestarts=0\n' > "$home/state/.context-surfaced-ctx-switch"
    printf '{"stamp":"%s","harness":"%s","store":"%s","worktree":"%s"}\n' "$CODEX_STAMP" "$after" "$home/store" "$wt" \
      >> "$home/data/ctx-switch/sessions/launches.jsonl"
    fm_write_meta "$home/state/ctx-switch.meta" "worktree=$wt" "harness=$after" "kind=ship"
    second=$("${after}_open" "$home/store" "$wt" "$CODEX_STAMP")
    if [ "$after" = claude ]; then
      claude_usage "$second" "$wt" "$CODEX_STAMP" 1 0 0 220000
    else
      codex_usage "$second" 1 220000 220100
    fi
    sleep 1.1
    out=$(tick "$home" FM_CONTEXT_BIND_RETRY_SECS=1) || fail "relaunch tick failed: $out"
    [ "$out" = "$(printf 'ctx-switch\tcontext: ctx-switch 220k tokens (warn 200k)\t200000\t1\t1')" ] || fail "$before to $after crossing missing: $out"
    printf 'warned=200000\ncompactions=1\nrestarts=1\n' > "$home/state/.context-surfaced-ctx-switch"
    if [ "$after" = claude ]; then
      claude_compaction "$second" "$wt" "$CODEX_STAMP" 2
      claude_usage "$second" "$wt" "$CODEX_STAMP" 3 0 0 50000
    else
      codex_compaction "$second" 2
      codex_usage "$second" 3 50000 270200
    fi
    out=$(tick "$home") || fail "replacement compaction tick failed: $out"
    [ "$out" = "$(printf 'ctx-switch\tcontext: ctx-switch compacted (n=2)\t0\t2\t1')" ] || fail "$before to $after compaction missing: $out"
    out=$(reader "$home" ctx-switch) || fail "mixed reader failed: $out"
    [ "$out" = "context=50000 peak=310000 compactions=2 harness=$after source=$second" ] || fail "mixed reader wrong: $out"
    out=$(FM_HOME="$home" node "$ROOT/bin/fm-context-watch.mjs" read ctx-switch) || fail "mixed JSON reader failed"
    printf '%s' "$out" | jq -e --arg before "$before" --arg after "$after" \
      '.harness == $after and .restarts == 1 and .context == 50000 and .peak == 310000 and .compactions == 2 and .records[0].harness == $before and .records[1].harness == $after' \
      >/dev/null || fail "mixed JSON wrong: $out"
    cache="$home/state/ctx-switch.context-watch"
    jq 'del(.records[].harness) | .context = null | .compactions = 1' "$cache" > "$cache.old"
    mv "$cache.old" "$cache"
    out=$(tick "$home") || fail "legacy cache rebuild failed"
    jq -e --arg after "$after" '.harness == $after and .context == 50000 and .peak == 310000 and .compactions == 2' "$cache" \
      >/dev/null || fail "legacy mixed cache was not rebuilt"
    pass "$before to $after relaunch preserves measurements and wakes"
  done
}

test_claude_reader_folds_context_peak_and_compactions
test_codex_reader_folds_context_peak_and_compactions
test_reader_refuses_an_unbound_task_by_name
test_reader_counts_restarts_across_launches
test_claude_usage_folds_tools_classes_and_turns
test_codex_usage_folds_tools_classes_and_turns
test_usage_classifies_quoted_redirects
test_usage_reports_bound_records_without_a_request_as_unavailable
test_watcher_wakes_once_per_crossing_step_and_compaction
test_watcher_honours_warn_and_step_overrides
test_watcher_skips_unbound_and_secondmate_tasks
test_tick_rebinds_a_relaunch_whose_record_appears_later
test_context_is_a_durable_wake_kind

test_tick_unread_aggregates_remain_null
test_codex_compaction_invalidates_stale_usage

test_cross_harness_relaunches
