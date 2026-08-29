#!/usr/bin/env bash
# Opt-in credentialed guard for Codex's rollout-log busy source.
#
# tests/fm-codex-harness.test.sh pins the fold against fixtures, which can only
# confirm the shape already written into the fixture. This guard drives a REAL
# codex worker through a real turn and reads the verdict back through the public
# classifier, so a Codex release that renames, moves, or stops writing its turn
# records fails here naming the harness and version instead of silently
# reporting every live worker as unreadable.
#
# Refresh command for docs/verification/supervision.md "Codex rollout turn
# bracket"; run it after every Codex upgrade.
set -u

if [ "${FM_CODEX_BUSY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_BUSY_LIVE_E2E=1 to run the Codex busy-source guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found; this guard refuses to pass having checked nothing"
command -v tmux >/dev/null 2>&1 || fail "tmux not found; this guard needs a real pane worker"
command -v jq >/dev/null 2>&1 || fail "jq not found; the Codex rollout fold needs it"

# shellcheck source=bin/fm-busy-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-busy-lib.sh"

CODEX_VERSION=$(codex --version)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-busy-live.XXXXXX") || fail "could not create the lab"
WT="$LAB/worktree"
STATE="$LAB/state"
SOCKET="fm-codex-busy-$$"
SESSIONS_ROOT="${CODEX_HOME:-$HOME/.codex}/sessions"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mkdir -p "$WT" "$STATE"
printf 'scratch\n' > "$WT/README.md"

# The binding fm-spawn writes, built here through the same library so a drift
# between the writer and the reader shows up as a failure rather than a pass.
{
  printf 'sessions_root=%s\n' "$SESSIONS_ROOT"
  printf 'workspace_root=%s\n' "$WT"
  while IFS= read -r prior; do
    [ -n "$prior" ] && printf 'prior_session=%s\n' "$prior"
  done <<EOF
$(fm_busy_codex_matching_logs "$SESSIONS_ROOT" "$WT" 2>/dev/null || true)
EOF
} > "$STATE/live.codex-session"

# Before a turn exists there is nothing to fold, and the verdict must be
# unknown rather than a guess in either direction.
before=$(fm_busy_classify tmux none codex live "$STATE")
[ "$before" = "unknown codex-rollout" ] \
  || fail "$CODEX_VERSION: an unstarted codex task must be 'unknown codex-rollout', got '$before'"

tmux -L "$SOCKET" new-session -d -s codexbusy -x 120 -y 40 -c "$WT" \
  "codex --dangerously-bypass-approvals-and-sandbox 'Count slowly from 1 to 400, one number per line, no other text.'" \
  || fail "$CODEX_VERSION: could not start a real codex pane worker"

# Answer the directory-trust dialog if this working directory is new to codex.
waited=0
while [ "$waited" -lt 60 ]; do
  pane=$(tmux -L "$SOCKET" capture-pane -p -t codexbusy 2>/dev/null || true)
  case "$pane" in
    *"Do you trust"*) tmux -L "$SOCKET" send-keys -t codexbusy Enter; break ;;
  esac
  case "$pane" in *"esc"*|*"Working"*|*"1"*) break ;; esac
  sleep 0.5
  waited=$((waited + 1))
done

# The worker must read BUSY while its turn is genuinely in flight.
waited=0
during=
while [ "$waited" -lt 120 ]; do
  during=$(fm_busy_classify tmux none codex live "$STATE")
  [ "$during" = "busy codex-rollout" ] && break
  sleep 0.5
  waited=$((waited + 1))
done
[ "$during" = "busy codex-rollout" ] \
  || fail "$CODEX_VERSION: a live codex worker must classify 'busy codex-rollout', got '$during'"

# Interrupting that turn must settle it, not strand it busy forever. Ctrl+C is
# used here deliberately: it is the key observed to reach a running Codex turn
# in a headless pane, and this guard is about the LOG, not the key binding.
tmux -L "$SOCKET" send-keys -t codexbusy C-c
waited=0
after=
while [ "$waited" -lt 120 ]; do
  after=$(fm_busy_classify tmux none codex live "$STATE")
  [ "$after" = "idle codex-rollout" ] && break
  sleep 0.5
  waited=$((waited + 1))
done
[ "$after" = "idle codex-rollout" ] \
  || fail "$CODEX_VERSION: an interrupted codex turn must settle to 'idle codex-rollout', got '$after'"

printf 'ok - %s live guard: a real codex worker reads busy in flight and idle after an interrupt\n' \
  "$CODEX_VERSION"
