#!/usr/bin/env bash
# Show or persist codeburn usage for one crewmate/scout cycle.
#
# The worktree path is matched against codeburn's reported project inventory.
# The reported project name is then the filter key; a path is never guessed into
# a slug. fm-spawn captures a baseline before launch, so subtracting it excludes
# earlier occupants of a pooled worktree.
# fm-teardown writes data/<id>/usage.json before removing the task metadata.
# Old metadata without spawned_at or a baseline still works, but its live total
# is only date/project scoped and can therefore include an earlier same-day occupant.
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
# shellcheck source=bin/fm-task-meta-lock-lib.sh
. "$FM_ROOT/bin/fm-task-meta-lock-lib.sh"

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

print_compact() { # <snapshot-or-summary>
  # shellcheck disable=SC2016  # single-quoted: ${} here is JS template-literal syntax, not for bash to expand
  node -e '
    const u=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))
    const parsedDuration = Date.parse(u.captured_at) - Date.parse(u.spawned_at)
    const seconds = Number.isFinite(u.duration_seconds) ? u.duration_seconds : (Number.isFinite(parsedDuration) ? Math.max(0, Math.floor(parsedDuration / 1000)) : null)
    const elapsed = seconds === null ? "-" : `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m ${Math.floor(seconds % 60)}s`
    const sessions = Number.isFinite(u.sessions) ? u.sessions : "-"
    console.log(`${u.harness} / ${(u.actual_models||[]).join(", ")||"-"} | in ${u.tokens.input}, out ${u.tokens.output}, cache ${u.tokens.cache_read}, write ${u.tokens.cache_write} | $${u.cost_usd.toFixed(4)} | ${u.calls} calls | ${sessions} sessions | elapsed ${elapsed}`)
  ' "$1"
}

if [ ! -f "$META" ]; then
  if [ -f "$SNAPSHOT" ] && [ "$MODE" != --baseline ]; then
    if [ "$MODE" = --json ]; then
      cat "$SNAPSHOT"
    else
      print_compact "$SNAPSHOT"
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
PROJECT=$(meta_value "$META" project)
HARNESS=$(meta_value "$META" harness)
CONFIGURED_MODEL=$(meta_value "$META" model)
DELIVERY_MODE=$(meta_value "$META" mode)
TITLE=$(meta_value "$META" title)
if [ -z "$TITLE" ] && [ -f "$TASK_DATA/brief.md" ]; then
  TITLE=$(awk '/^# Task[[:space:]]*$/{in_task=1; next} in_task && NF {print; exit}' "$TASK_DATA/brief.md")
fi
SPAWNED_AT=$(meta_value "$META" spawned_at)
if [ -z "$SPAWNED_AT" ]; then
  # Portable mtime: macOS (BSD) `date -r` takes epoch seconds, not a path, so
  # go through `stat` first. See bin/fm-watch.sh for the same platform split.
  if [ "$(uname)" = Darwin ]; then
    META_MTIME=$(stat -f %m "$META" 2>/dev/null || true)
  else
    META_MTIME=$(stat -c %Y "$META" 2>/dev/null || true)
  fi
  if [ -n "$META_MTIME" ]; then
    if [ "$(uname)" = Darwin ]; then
      SPAWNED_AT=$(date -u -r "$META_MTIME" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    else
      SPAWNED_AT=$(date -u -d "@$META_MTIME" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    fi
  fi
fi
FROM=${SPAWNED_AT%%T*}
[ -n "$FROM" ] || FROM=$(date -u +%Y-%m-%d)
TO=$(date -u +%Y-%m-%d)

command -v node >/dev/null 2>&1 || { echo "fm-task-usage: node not found" >&2; exit 1; }

DISCOVERY=$(mktemp "${TMPDIR:-/tmp}/fm-task-usage-discovery.XXXXXX") || exit 1
CURRENT=$(mktemp "${TMPDIR:-/tmp}/fm-task-usage-current.XXXXXX") || exit 1
PROJECT_KEY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-task-usage-project.XXXXXX") || exit 1
trap 'rm -f "$DISCOVERY" "$CURRENT" "$PROJECT_KEY_FILE"' EXIT

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

query_codeburn() { # [reported-project-key]
  local project_key=${1:-}
  if [ -n "${FM_CODEBURN_BIN:-}" ]; then
    if [ -n "$project_key" ]; then
      run_bounded "$FM_CODEBURN_BIN" --timezone UTC report --format json --from "$FROM" --to "$TO" --project "$project_key"
    else
      run_bounded "$FM_CODEBURN_BIN" --timezone UTC report --format json --from "$FROM" --to "$TO"
    fi
  elif command -v codeburn >/dev/null 2>&1; then
    # npm globals installed on Windows need Windows Node so codeburn sees the
    # same Windows-side harness logs. Native installs stay on the native path.
    case "$(command -v codeburn)" in
      /mnt/[a-zA-Z]/*)
        if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
          case "$project_key" in
            *[!A-Za-z0-9._:-]*)
              echo "fm-task-usage: codeburn reported an unsafe Windows project key" >&2
              return 1
              ;;
          esac
          if [ -n "$project_key" ]; then
            run_bounded cmd.exe /d /s /c "codeburn --timezone UTC report --format json --from $FROM --to $TO --project \"$project_key\""
          else
            run_bounded cmd.exe /d /s /c "codeburn --timezone UTC report --format json --from $FROM --to $TO"
          fi
        else
          if [ -n "$project_key" ]; then
            run_bounded codeburn --timezone UTC report --format json --from "$FROM" --to "$TO" --project "$project_key"
          else
            run_bounded codeburn --timezone UTC report --format json --from "$FROM" --to "$TO"
          fi
        fi
        ;;
      *)
        if [ -n "$project_key" ]; then
          run_bounded codeburn --timezone UTC report --format json --from "$FROM" --to "$TO" --project "$project_key"
        else
          run_bounded codeburn --timezone UTC report --format json --from "$FROM" --to "$TO"
        fi
        ;;
    esac
  else
    return 127
  fi
}

if ! query_codeburn > "$DISCOVERY" || ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$DISCOVERY" 2>/dev/null; then
  echo "fm-task-usage: codeburn usage unavailable for $ID" >&2
  exit 1
fi

WINDOWS_WORKTREE=
case "$WORKTREE" in
  /mnt/[a-zA-Z]/*)
    if command -v wslpath >/dev/null 2>&1; then
      WINDOWS_WORKTREE=$(wslpath -w "$WORKTREE" 2>/dev/null || true)
    fi
    ;;
esac

if ! node - "$DISCOVERY" "$WORKTREE" "$WINDOWS_WORKTREE" > "$PROJECT_KEY_FILE" <<'NODE'
const fs = require('fs')
const [reportPath, ...worktrees] = process.argv.slice(2)
const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'))
const projects = Array.isArray(report.projects) ? report.projects : []
const normalize = value => String(value || '')
  .replace(/\\/g, '/')
  .replace(/^\/+/, '')
  .replace(/[-/_]+/g, '/')
  .replace(/\/+$/, '')
  .toLowerCase()
const targets = new Set(worktrees.filter(Boolean).map(normalize))
const exactTargets = new Set(worktrees.filter(Boolean).map(value => value.replace(/\\/g, '/').replace(/^\/+/, '').toLowerCase()))
const exact = projects.filter(project => exactTargets.has(String(project.path || '').replace(/\\/g, '/').replace(/^\/+/, '').toLowerCase()))
const normalized = projects.filter(project => targets.has(normalize(project.path)))
const candidates = exact.length ? exact : normalized
const names = [...new Set(candidates.map(project => project.name).filter(name => typeof name === 'string' && name))]
const reported = projects.map(project => project.name).filter(Boolean).join(', ') || '<none>'
if (names.length === 0) {
  console.error(`fm-task-usage: no codeburn project matches worktree ${worktrees[0]}; reported keys: ${reported}`)
  process.exit(1)
}
if (names.length > 1) {
  console.error(`fm-task-usage: codeburn project match is ambiguous for worktree ${worktrees[0]}: ${names.join(', ')}`)
  process.exit(1)
}
process.stdout.write(names[0] + '\n')
NODE
then
  exit 1
fi
PROJECT_KEY=$(cat "$PROJECT_KEY_FILE")

if ! query_codeburn "$PROJECT_KEY" > "$CURRENT" || ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$CURRENT" 2>/dev/null; then
  echo "fm-task-usage: codeburn usage unavailable for $ID" >&2
  exit 1
fi
if ! node -e '
  const r=JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
  if (!Array.isArray(r.projects) || !r.projects.some(project => project.name === process.argv[2])) process.exit(1)
' "$CURRENT" "$PROJECT_KEY"; then
  echo "fm-task-usage: codeburn project filter matched nothing for $ID (reported key: $PROJECT_KEY)" >&2
  exit 1
fi

if [ "$MODE" = --baseline ]; then
  mkdir -p "$TASK_DATA"
  cp "$CURRENT" "$BASELINE"
  exit 0
fi

SUMMARY=$(mktemp "${TMPDIR:-/tmp}/fm-task-usage-summary.XXXXXX") || exit 1
trap 'rm -f "$DISCOVERY" "$CURRENT" "$PROJECT_KEY_FILE" "$SUMMARY"' EXIT
if ! node - "$CURRENT" "$BASELINE" "$ID" "$TITLE" "$KIND" "$PROJECT" "$DELIVERY_MODE" "$HARNESS" "$CONFIGURED_MODEL" "$SPAWNED_AT" "$WORKTREE" "$PROJECT_KEY" > "$SUMMARY" <<'NODE'
const fs = require('fs')
const [currentPath, baselinePath, id, title, kind, project, deliveryMode, harness, configuredModel, spawnedAt, worktree, projectKey] = process.argv.slice(2)
const current = JSON.parse(fs.readFileSync(currentPath, 'utf8'))
const baselinePresent = fs.existsSync(baselinePath)
const baseline = baselinePresent ? JSON.parse(fs.readFileSync(baselinePath, 'utf8')) : {}
if (!baselinePresent) {
  console.error('fm-task-usage: saved baseline is unavailable; refusing an unbounded total')
  process.exit(1)
}
if (baselinePresent && !(baseline.projects || []).some(project => project.name === projectKey)) {
  console.error(`fm-task-usage: saved baseline does not identify codeburn project ${projectKey}; refusing an unbounded total`)
  process.exit(1)
}
const before = baseline.overview || {}
const after = current.overview || {}
const counter = (object, key, label) => {
  if (!Object.prototype.hasOwnProperty.call(object, key)
      || typeof object[key] !== 'number' || !Number.isFinite(object[key]) || object[key] < 0) {
    console.error(`fm-task-usage: invalid ${label} counter; refusing plausible-zero attribution`)
    process.exit(1)
  }
  return object[key]
}
const diff = (currentObject, baselineObject, key, label) => {
  const currentValue = counter(currentObject, key, `current ${label}`)
  const baselineValue = counter(baselineObject, key, `baseline ${label}`)
  if (currentValue < baselineValue) {
    console.error(`fm-task-usage: decreasing ${label} counter; refusing plausible-zero attribution`)
    process.exit(1)
  }
  return currentValue - baselineValue
}
if (!Array.isArray(baseline.models) || !Array.isArray(current.models)) {
  console.error('fm-task-usage: invalid model counters; refusing plausible-zero attribution')
  process.exit(1)
}
const modelKeys = ['calls', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'cost']
const beforeModels = new Map()
for (const model of baseline.models) {
  if (!model || typeof model.name !== 'string' || !model.name || beforeModels.has(model.name)) {
    console.error('fm-task-usage: invalid baseline model identity; refusing plausible-zero attribution')
    process.exit(1)
  }
  for (const key of modelKeys) counter(model, key, `baseline model ${model.name} ${key}`)
  beforeModels.set(model.name, model)
}
const currentModelNames = new Set()
for (const model of current.models) {
  if (!model || typeof model.name !== 'string' || !model.name || currentModelNames.has(model.name)) {
    console.error('fm-task-usage: duplicate or invalid current model identity; refusing attribution')
    process.exit(1)
  }
  currentModelNames.add(model.name)
}
const models = (current.models || []).map(model => {
  const old = beforeModels.get(model.name)
  if (!old) {
    console.error(`fm-task-usage: model ${model.name} lacks baseline counters; refusing plausible-zero attribution`)
    process.exit(1)
  }
  return {
    name: model.name,
    calls: diff(model, old, 'calls', `model ${model.name} calls`),
    input_tokens: diff(model, old, 'inputTokens', `model ${model.name} input tokens`),
    output_tokens: diff(model, old, 'outputTokens', `model ${model.name} output tokens`),
    cache_read_tokens: diff(model, old, 'cacheReadTokens', `model ${model.name} cache read tokens`),
    cache_write_tokens: diff(model, old, 'cacheWriteTokens', `model ${model.name} cache write tokens`),
    cost_usd: diff(model, old, 'cost', `model ${model.name} cost`),
  }
}).filter(model => model.name !== '<synthetic>' && (model.calls || model.input_tokens || model.output_tokens || model.cache_read_tokens || model.cache_write_tokens || model.cost_usd))
const tokens = after.tokens || {}
const oldTokens = before.tokens || {}
const capturedAt = new Date().toISOString()
const started = Date.parse(spawnedAt)
const captured = Date.parse(capturedAt)
const summary = {
  schema: 'fm-task-usage.v2',
  id,
  title: title || id,
  kind: kind || 'ship',
  project: project || null,
  delivery_mode: deliveryMode || null,
  harness: harness || 'unknown',
  configured_model: configuredModel || 'default',
  actual_models: models.map(model => model.name),
  models,
  tokens: {
    input: diff(tokens, oldTokens, 'input', 'input tokens'),
    output: diff(tokens, oldTokens, 'output', 'output tokens'),
    cache_read: diff(tokens, oldTokens, 'cacheRead', 'cache read tokens'),
    cache_write: diff(tokens, oldTokens, 'cacheWrite', 'cache write tokens'),
  },
  cost_usd: diff(after, before, 'cost', 'cost'),
  calls: diff(after, before, 'calls', 'calls'),
  sessions: diff(after, before, 'sessions', 'sessions'),
  spawned_at: spawnedAt || null,
  captured_at: capturedAt,
  duration_seconds: Number.isFinite(started) && Number.isFinite(captured) ? Math.max(0, Math.floor((captured - started) / 1000)) : null,
  correlation: {worktree, project_key: projectKey, project_match: 'reported-path', baseline: baselinePresent},
}
process.stdout.write(JSON.stringify(summary) + '\n')
NODE
then
  exit 1
fi

if [ "$MODE" = --snapshot ]; then
  mkdir -p "$TASK_DATA"
  cp "$SUMMARY" "$SNAPSHOT"
  fm_task_effort_capture_best_effort "$FM_ROOT" "$ID"
fi

if [ "$MODE" = --json ]; then
  cat "$SUMMARY"
else
  print_compact "$SUMMARY"
fi
