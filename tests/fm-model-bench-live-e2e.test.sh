#!/usr/bin/env bash
# Opt-in credentialed guard for the model gut-check tool end to end.
#
# tests/fm-model-bench.test.sh pins the reader, the independence check, and the
# dry-run refusals against fixtures, which can only confirm the shapes already
# written into the fixtures. This guard runs bin/fm-model-bench.sh for real:
# one arm per INSTALLED harness (codex, claude), each a genuine spawn through
# bin/fm-spawn.sh into a private clone of a scratch project, on a private tmux
# server, then asserts what the fixtures cannot: that the pre-trust entry this
# tool writes really suppresses the harness's first-run directory dialog (the
# arm reaches its terminal report at all), that the harness really writes a
# session record the reader matches on the arm's exact worktree, that the
# record really names the model that was requested, and that the arm's pushed
# branch lands in its private source repository so bin/fm-teardown.sh treats
# the work as landed. A harness release that moves its trust store, its
# session records, or its turn brackets fails here naming the harness and its
# version instead of silently producing a benchmark whose numbers look right.
#
# Every installed harness is exercised; an absent harness is reported, and a
# run that could exercise none refuses to pass. Set FM_MODEL_BENCH_LIVE_MODELS
# to "<harness>:<model> ..." to choose the models; the default reads codex's
# configured model from its config.toml and uses claude-haiku-4-5-20251001 for
# claude.
#
# Refresh command for docs/verification/model-bench.md; run it after every
# codex or claude upgrade.
set -u

if [ "${FM_MODEL_BENCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_MODEL_BENCH_LIVE_E2E=1 to run the model gut-check live guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

for tool in tmux treehouse git node jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found; this guard needs a real spawn path"
done

ARMS=()
VERSIONS=()
if [ -n "${FM_MODEL_BENCH_LIVE_MODELS:-}" ]; then
  # shellcheck disable=SC2206 # deliberate word split of the operator's space-separated list
  ARMS=(${FM_MODEL_BENCH_LIVE_MODELS})
else
  if command -v codex >/dev/null 2>&1; then
    codex_model=$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null | head -1)
    [ -n "$codex_model" ] || fail "codex is installed but its config.toml names no model; set FM_MODEL_BENCH_LIVE_MODELS=codex:<model> ..."
    ARMS+=("codex:$codex_model")
  else
    echo "note: codex not installed; not exercised"
  fi
  if command -v claude >/dev/null 2>&1; then
    ARMS+=("claude:claude-haiku-4-5-20251001")
  else
    echo "note: claude not installed; not exercised"
  fi
fi
[ "${#ARMS[@]}" -ge 1 ] || fail "no supported harness is installed; refusing to pass having checked nothing"
for arm in "${ARMS[@]}"; do
  h=${arm%%:*}
  command -v "$h" >/dev/null 2>&1 || fail "$h named in FM_MODEL_BENCH_LIVE_MODELS but not installed"
  VERSIONS+=("$h $("$h" --version 2>/dev/null | head -1)")
done
# Two arms are the tool's minimum; a machine with one harness exercises it twice.
[ "${#ARMS[@]}" -ge 2 ] || ARMS+=("${ARMS[0]}")

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-bench-live.XXXXXX") || fail "could not create the lab"
# A private tmux server and an explicit tmux backend: this guard must never
# place a pane in the operator's own session provider, whatever the ambient
# environment (a Herdr-launched shell auto-selects Herdr otherwise).
export TMUX_TMPDIR="$LAB/tmux"
export FM_BACKEND=tmux
export FM_SPAWN_NO_GUARD=1
unset TMUX HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH CMUX_WORKSPACE_ID
mkdir -p "$TMUX_TMPDIR" "$LAB/home/data" "$LAB/home/state" "$LAB/home/config"
touch "$LAB/home/state/.last-watcher-beat"
RUN_ID="mb-live-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
POOLS=()

# remember_pool <worktree>: the pool a lab arm's worktree lives in, destroyed
# at cleanup. Recorded from the task record while it still exists, because
# the explicit teardown below removes that record before cleanup runs.
remember_pool() {
  local pool
  [ -n "$1" ] || return 0
  pool=$(dirname "$(dirname "$1")")
  case "$pool" in
    "$HOME/.treehouse/"*) POOLS+=("$pool") ;;
  esac
}

preserve_store_mode() {
  local mode
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$1") || return 1
  else
    mode=$(stat -c %a "$1") || return 1
  fi
  chmod "$mode" "$2"
}

cleanup() {
  local arm id wt pool tmp index
  for ((index = 1; index <= ${#ARMS[@]}; index++)); do
    arm="a$index"
    id="$RUN_ID-$arm"
    wt=$(sed -n 's/^worktree=//p' "$LAB/home/state/$id.meta" 2>/dev/null | tail -1)
    remember_pool "$wt"
    if [ -f "$LAB/home/state/$id.meta" ]; then
      FM_HOME="$LAB/home" "$ROOT/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 || true
    fi
  done
  tmux kill-server 2>/dev/null || true
  for pool in "${POOLS[@]:-}"; do
    # This lab's own pools only: each arm clone lived under the lab, so its
    # pool is disposable once the work has been read.
    [ -n "$pool" ] && treehouse destroy "$pool" --all --include-unlanded --include-in-use --yes >/dev/null 2>&1 || true
  done
  # The trust entries the tool wrote for this lab's clones: remove them from
  # the operator's stores so a guard run leaves no litter behind.
  codex_store="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [ -f "$codex_store" ]; then
    tmp=$(umask 077; mktemp "$codex_store.fm-model-bench-live.XXXXXX") || return 1
    awk -v lab="$LAB" '
      /^\[projects\."/ { skip = index($0, lab) > 0 }
      /^\[/ && !/^\[projects\."/ { skip = 0 }
      !skip
    ' "$codex_store" > "$tmp" && preserve_store_mode "$codex_store" "$tmp" && mv -f "$tmp" "$codex_store"
    rm -f "$tmp"
  fi
  claude_store="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"
  [ -n "$claude_store" ] || claude_store="$HOME/.claude.json"
  if [ -f "$claude_store" ] && command -v jq >/dev/null 2>&1; then
    tmp=$(umask 077; mktemp "$claude_store.fm-model-bench-live.XXXXXX") || return 1
    jq --arg lab "$LAB" '.projects |= with_entries(select(.key | startswith($lab) | not))' "$claude_store" \
      > "$tmp" && preserve_store_mode "$claude_store" "$tmp" && mv -f "$tmp" "$claude_store"
    rm -f "$tmp"
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PROJECT="$LAB/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
printf '# scratch\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

ARM_FLAGS=()
for arm in "${ARMS[@]}"; do ARM_FLAGS+=(--arm "$arm"); done

# The content cannot be identical across arms by construction, so the
# independence check must pass here; a trivial fixed-content task would trip it.
# shellcheck disable=SC2016 # the backticks are prose for the arm, not a command substitution
TASK='Create a file named pong.txt at the repository root whose single line is the word PONG, a space, and the output of `date +%s%N` at the moment you create it. Commit it with the message "add pong". Do nothing else.'

out=$(FM_HOME="$LAB/home" "$ROOT/bin/fm-model-bench.sh" run "$PROJECT" "${ARM_FLAGS[@]}" \
  --task "$TASK" --feasible 'Creating and committing one file is achievable by any coding model.' \
  --env MODEL_BENCH_LIVE_PROBE=1 --run-id "$RUN_ID" --timeout 900 --poll 5 2>&1) \
  || fail "${VERSIONS[*]}: the live run failed: $out"
printf '%s\n' "$out"

report=$(FM_HOME="$LAB/home" "$ROOT/bin/fm-model-bench.sh" report "$RUN_ID" --json) \
  || fail "${VERSIONS[*]}: report failed"
n=$(printf '%s' "$report" | jq '.arms | length')
[ "$n" = "${#ARMS[@]}" ] || fail "expected ${#ARMS[@]} arms in the report, got $n"
for i in $(seq 0 $((n - 1))); do
  arm=$(printf '%s' "$report" | jq -r ".arms[$i].arm")
  harness=$(printf '%s' "$report" | jq -r ".arms[$i].harness")
  requested=$(printf '%s' "$report" | jq -r ".arms[$i].model")
  state=$(printf '%s' "$report" | jq -r ".arms[$i].state")
  confirmed=$(printf '%s' "$report" | jq -r ".arms[$i].session.model_confirmed")
  models=$(printf '%s' "$report" | jq -r ".arms[$i].session.models | join(\",\")")
  active=$(printf '%s' "$report" | jq -r ".arms[$i].session.active_ms")
  total=$(printf '%s' "$report" | jq -r ".arms[$i].session.usage.total")
  verdict=$(printf '%s' "$report" | jq -r ".arms[$i].independence.verdict")
  bare=$(printf '%s' "$report" | jq -r ".arms[$i].source_git")
  branch=$(printf '%s' "$report" | jq -r ".arms[$i].branch")
  ver="${VERSIONS[*]}"
  [ "$state" = 'done' ] || fail "$ver: $arm ($harness) ended '$state', not done - a consumed launch or a dialog would look exactly like this"
  [ "$confirmed" = true ] || fail "$ver: $arm ($harness) running model not confirmed from its session record (models: $models)"
  [ "$models" = "$requested" ] || fail "$ver: $arm ($harness) ran '$models', not the requested '$requested'"
  [ "$active" -gt 0 ] 2>/dev/null || fail "$ver: $arm ($harness) active time must be positive, got '$active'"
  [ "$total" -gt 0 ] 2>/dev/null || fail "$ver: $arm ($harness) token total must be positive, got '$total'"
  [ "$verdict" = independent ] || fail "$ver: $arm ($harness) independence verdict '$verdict'"
  git -C "$bare" rev-parse --verify --quiet "refs/heads/$branch^{commit}" >/dev/null \
    || fail "$ver: $arm ($harness) did not push $branch into its private source repository"
  git -C "$bare" cat-file -e "refs/heads/$branch:pong.txt" 2>/dev/null \
    || fail "$ver: $arm ($harness) branch $branch holds no pong.txt"
  printf 'ok - %s: %s ran %s, active %sms, %s tokens, %s, pushed %s\n' "$arm" "$harness" "$models" "$active" "$total" "$verdict" "$branch"
done
[ "$(printf '%s' "$report" | jq '.void_arms | length')" = 0 ] || fail "${VERSIONS[*]}: a void arm in a run whose files cannot be identical"

# Teardown must accept every arm as landed work (pushed to its private origin).
for i in $(seq 0 $((n - 1))); do
  id=$(printf '%s' "$report" | jq -r ".arms[$i].task_id")
  remember_pool "$(printf '%s' "$report" | jq -r ".arms[$i].worktree")"
  FM_HOME="$LAB/home" "$ROOT/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "${VERSIONS[*]}: fm-teardown refused $id although its branch is on its private origin"
done
printf 'ok - %s live guard: every installed harness launched pre-trusted, confirmed its model from its own record, and landed its branch\n' "${VERSIONS[*]}"
