#!/usr/bin/env bash
# Stable PreToolUse transport for the crew signal guard.
#
# A crew or scout session must never signal a process it cannot prove it
# started: signalling the parent of a pattern-matched process once reached the
# user service manager, which stopped the shared terminal server and every
# worker with it. bin/fm-spawn.sh installs this check into every crew and scout
# launch on harnesses with a per-task pre-tool hook, and sets the matching
# FM_PROC_SCOPE marker on the agent launch.
# bin/fm-signal-command-policy.mjs is the sole owner of the allow/deny decision;
# this wrapper only acquires the harness payload, runs a cheap prefilter,
# invokes that policy, and renders the harness responses. It never executes,
# sources, evaluates, or expands the command. docs/signal-guard.md owns the
# complete contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-signal-pretool-check.sh [--scope <token>] [--claude]
#   bin/fm-signal-pretool-check.sh --command '<cmd>' [--scope <token>] [--cwd <dir>]
#
# Stdin mode extracts .tool_input.command (Claude, Codex) or .toolInput.command
# (Grok), and .cwd when present. CLI mode is used by the OpenCode plugin and the
# Pi extension. --scope names this session's process-scope token; it defaults to
# $FM_PROC_SCOPE.
#
# Exit/output contract (same shape as bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   NO COMMAND - empty stdin or a payload without a command: exit 0.
#   UNVERIFIABLE - signalling text when payload decoding, Node, or the policy
#          owner is unavailable or answers invalidly: DENY with
#          [signal-unverifiable]. Commands that mention no signal tool are never
#          blocked by a broken runtime.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
SCOPE=${FM_PROC_SCOPE:-}
RUN_CWD=""

usage() {
  cat <<'EOF'
Usage: fm-signal-pretool-check.sh [--command <cmd>] [--scope <token>] [--cwd <dir>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_input.command, or Grok toolInput.command, plus cwd).
Exits 0 to allow and 2 to deny a command that would signal a process this
session cannot prove it started (see docs/signal-guard.md).
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
--scope defaults to $FM_PROC_SCOPE, the marker bin/fm-spawn.sh sets on the
agent launch.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --scope)
      [ "$#" -gt 1 ] || { echo "error: --scope requires a value" >&2; exit 2; }
      SCOPE=$2
      shift 2
      ;;
    --cwd)
      [ "$#" -gt 1 ] || { echo "error: --cwd requires a value" >&2; exit 2; }
      RUN_CWD=$2
      shift 2
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  '
}

render_deny() {  # <code> <reason>
  local escaped
  escaped=$(json_escape "[$1] $2")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

unverifiable() {
  render_deny signal-unverifiable "the signal check could not run or decode its payload, so the target cannot be verified. Restore the checker, then signal only a recorded own PID or use \$! in the command that starts the job."
}

UNVERIFIED=0
if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  if ! command -v jq >/dev/null 2>&1 ||
    ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty) | if type == "string" then . else error("command must be a string") end' 2>/dev/null); then
    CMD=$PAYLOAD
    UNVERIFIED=1
  else
    [ -n "$RUN_CWD" ] || RUN_CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // empty)' 2>/dev/null) || RUN_CWD=""
  fi
fi

[ -n "$CMD" ] || exit 0
[ -n "$RUN_CWD" ] || RUN_CWD=$PWD

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Every tool the policy treats as a signal send contains "kill" or
# is fuser. Quote and escape bytes are stripped first so a fragmented command
# word still reaches the policy, and an ANSI-C ($'...') or locale ($"...")
# quoting marker always delegates because the shared classifier decodes those.
# That marker set is coupled to the decoder set in bin/fm-arm-command-policy.mjs,
# exactly as in bin/fm-cd-pretool-check.sh.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *kill*|*fuser*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

[ "$UNVERIFIED" -eq 0 ] || unverifiable

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || unverifiable
POLICY="$SCRIPT_DIR/fm-signal-command-policy.mjs"
command -v node >/dev/null 2>&1 || unverifiable
[ -f "$POLICY" ] || unverifiable

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --scope "$SCOPE" --cwd "$RUN_CWD" 2>/dev/null) || unverifiable
[ "$POLICY_OUTPUT" = allow ] && exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = deny ] || unverifiable
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || unverifiable
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || unverifiable
render_deny "$CODE" "$REASON"
