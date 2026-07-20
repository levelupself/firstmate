#!/usr/bin/env bash
# Show or persist codeburn usage for one crewmate/scout cycle.
#
# The worktree path is the correlation key. fm-spawn captures a baseline before
# launch, so subtracting it excludes earlier occupants of a pooled worktree.
# fm-teardown writes data/<id>/usage.json before removing the task metadata.
# Old metadata without spawned_at or a baseline still works, but its live total
# is only date/path scoped and can therefore include an earlier same-day occupant.
# The codeburn call is bounded by FM_TASK_USAGE_TIMEOUT (default 15s) so a hung
# report never stalls spawn, teardown, or fleet-snapshot generation.
#
# Usage: fm-task-usage.sh <task-id> [--json|--baseline|--snapshot]
#   --json      print the compact summary as JSON
#   --baseline  save the pre-launch codeburn report
#   --snapshot  save data/<id>/usage.json and print its compact text form
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,11s/^# \{0,1\}//p' "$0"
}

ID=${1:-}
MODE=${2:-}
case "$MODE" in
  ''|--json|--baseline|--snapshot) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ -n "$ID" ] || { usage >&2; exit 2; }

META="$STATE/$ID.meta"
TASK_DATA="$DATA/$ID"
BASELINE="$TASK_DATA/usage-baseline.json"
SNAPSHOT="$TASK_DATA/usage.json"

if [ ! -f "$META" ]; then
  if [ -f "$SNAPSHOT" ] && [ "$MODE" != --baseline ]; then
    if [ "$MODE" = --json ]; then
      cat "$SNAPSHOT"
    else
      node -e 'const u=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(`${u.harness} / ${(u.actual_models||[]).join(", ")||"-"} | in ${u.tokens.input}, out ${u.tokens.output}, cache ${u.tokens.cache_read}, write ${u.tokens.cache_write} | $${u.cost_usd.toFixed(4)} | ${u.calls} calls`)' "$SNAPSHOT"
    fi
    exit 0
  fi
  echo "fm-task-usage: no live metadata or snapshot for task $ID" >&2
  exit 1
fi

meta_value() {
  sed -n "s/^$2=//p" "$1" | tail -1
}

KIND=$(meta_value "$META" kind)
[ -n "$KIND" ] || KIND=ship
if [ "$KIND" = secondmate ]; then
  echo "fm-task-usage: secondmates are persistent supervisors, not task cycles" >&2
  exit 1
fi

WORKTREE=$(meta_value "$META" worktree)
HARNESS=$(meta_value "$META" harness)
CONFIGURED_MODEL=$(meta_value "$META" model)
SPAWNED_AT=$(meta_value "$META" spawned_at)
if [ -z "$SPAWNED_AT" ]; then
  SPAWNED_AT=$(date -u -r "$META" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
fi
FROM=${SPAWNED_AT%%T*}
[ -n "$FROM" ] || FROM=$(date -u +%Y-%m-%d)
TO=$(date -u +%Y-%m-%d)

command -v node >/dev/null 2>&1 || { echo "fm-task-usage: node not found" >&2; exit 1; }

CURRENT=$(mktemp "${TMPDIR:-/tmp}/fm-task-usage.XXXXXX") || exit 1
trap 'rm -f "$CURRENT"' EXIT

# Bounded codeburn call; a hung process must never stall spawn/teardown/snapshot.
CODEBURN_TIMEOUT=${FM_TASK_USAGE_TIMEOUT:-15}
case "$CODEBURN_TIMEOUT" in ''|*[!0-9]*|0) CODEBURN_TIMEOUT=15 ;; esac
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
run_bounded() {  # <command...>
  case "$HAVE_TIMEOUT" in
    timeout)  timeout "$CODEBURN_TIMEOUT" "$@" ;;
    gtimeout) gtimeout "$CODEBURN_TIMEOUT" "$@" ;;
    perl)     perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CODEBURN_TIMEOUT" "$@" ;;
    *)        "$@" ;;
  esac
}

query_codeburn() {
  if [ -n "${FM_CODEBURN_BIN:-}" ]; then
    run_bounded "$FM_CODEBURN_BIN" --timezone UTC report --format json --from "$FROM" --to "$TO" --project "$WORKTREE"
  elif command -v codeburn >/dev/null 2>&1; then
    # npm globals installed on Windows need Windows Node so codeburn sees the
    # same Windows-side harness logs. Native installs stay on the native path.
    case "$(command -v codeburn)" in
      /mnt/[a-zA-Z]/*)
        if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
          local win_worktree
          win_worktree=$(wslpath -w "$WORKTREE")
          run_bounded cmd.exe /d /s /c "codeburn --timezone UTC report --format json --from $FROM --to $TO --project \"$win_worktree\""
        else
          run_bounded codeburn --timezone UTC report --format json --from "$FROM" --to "$TO" --project "$WORKTREE"
        fi
        ;;
      *) run_bounded codeburn --timezone UTC report --format json --from "$FROM" --to "$TO" --project "$WORKTREE" ;;
    esac
  else
    return 127
  fi
}

if ! query_codeburn > "$CURRENT" || ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$CURRENT" 2>/dev/null; then
  echo "fm-task-usage: codeburn usage unavailable for $ID" >&2
  exit 1
fi

if [ "$MODE" = --baseline ]; then
  mkdir -p "$TASK_DATA"
  cp "$CURRENT" "$BASELINE"
  exit 0
fi

SUMMARY=$(mktemp "${TMPDIR:-/tmp}/fm-task-usage-summary.XXXXXX") || exit 1
trap 'rm -f "$CURRENT" "$SUMMARY"' EXIT
node - "$CURRENT" "$BASELINE" "$ID" "$HARNESS" "$CONFIGURED_MODEL" "$SPAWNED_AT" "$WORKTREE" > "$SUMMARY" <<'NODE'
const fs = require('fs')
const [currentPath, baselinePath, id, harness, configuredModel, spawnedAt, worktree] = process.argv.slice(2)
const current = JSON.parse(fs.readFileSync(currentPath, 'utf8'))
const baselinePresent = fs.existsSync(baselinePath)
const baseline = baselinePresent ? JSON.parse(fs.readFileSync(baselinePath, 'utf8')) : {}
const before = baseline.overview || {}
const after = current.overview || {}
const diff = (a, b) => Math.max(0, Number(a || 0) - Number(b || 0))
const beforeModels = new Map((baseline.models || []).map(model => [model.name, model]))
const models = (current.models || []).map(model => {
  const old = beforeModels.get(model.name) || {}
  return {
    name: model.name,
    calls: diff(model.calls, old.calls),
    input_tokens: diff(model.inputTokens, old.inputTokens),
    output_tokens: diff(model.outputTokens, old.outputTokens),
    cache_read_tokens: diff(model.cacheReadTokens, old.cacheReadTokens),
    cache_write_tokens: diff(model.cacheWriteTokens, old.cacheWriteTokens),
    cost_usd: diff(model.cost, old.cost),
  }
}).filter(model => model.name !== '<synthetic>' && (model.calls || model.input_tokens || model.output_tokens || model.cache_read_tokens || model.cache_write_tokens || model.cost_usd))
const tokens = after.tokens || {}
const oldTokens = before.tokens || {}
const summary = {
  schema: 'fm-task-usage.v1',
  id,
  harness: harness || 'unknown',
  configured_model: configuredModel || 'default',
  actual_models: models.map(model => model.name),
  models,
  tokens: {
    input: diff(tokens.input, oldTokens.input),
    output: diff(tokens.output, oldTokens.output),
    cache_read: diff(tokens.cacheRead, oldTokens.cacheRead),
    cache_write: diff(tokens.cacheWrite, oldTokens.cacheWrite),
  },
  cost_usd: diff(after.cost, before.cost),
  calls: diff(after.calls, before.calls),
  spawned_at: spawnedAt || null,
  captured_at: new Date().toISOString(),
  correlation: {worktree, baseline: baselinePresent},
}
process.stdout.write(JSON.stringify(summary) + '\n')
NODE

if [ "$MODE" = --snapshot ]; then
  mkdir -p "$TASK_DATA"
  cp "$SUMMARY" "$SNAPSHOT"
fi

if [ "$MODE" = --json ]; then
  cat "$SUMMARY"
else
  node -e 'const u=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(`${u.harness} / ${(u.actual_models||[]).join(", ")||"-"} | in ${u.tokens.input}, out ${u.tokens.output}, cache ${u.tokens.cache_read}, write ${u.tokens.cache_write} | $${u.cost_usd.toFixed(4)} | ${u.calls} calls`)' "$SUMMARY"
fi
