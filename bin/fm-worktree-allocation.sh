#!/usr/bin/env bash
# Own the per-project worktree allocation ledger (data/worktree-allocations/
# <project-id>.jsonl): initialize records the tracking boundary, acquire and
# release append one event each for a task's hold on a worktree, and released
# is a read-only query that answers whether the ledger already holds a release
# event for exactly that task and worktree after its latest acquire. The query
# exits 0 only on such a release; a missing, unreadable, or malformed ledger,
# a hold with no release, or a release that predates the latest acquire all
# exit 1. bin/fm-teardown.sh writes the release only after a successful
# treehouse return, so a recorded release is durable proof that the task
# returned that copy, and the query never writes the ledger or takes its lock.
set -u

COMMAND=${1:-}
TASK_ID=${2:-}
PROJECT=${3:-}
WORKTREE=${4:-}
EVENT_AT=${5:-}
CANDIDATE=${6:-}
FM_HOME=${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

case "$COMMAND" in
  initialize)
    PROJECT=$TASK_ID
    EVENT_AT=${3:-}
    COMPLETENESS=${4:-}
    shift 4
    [ "$COMPLETENESS" = complete ] || COMPLETENESS=incomplete
    ;;
  acquire)
    [ "$CANDIDATE" = fresh ] || [ "$CANDIDATE" = reused ] || CANDIDATE=unknown
    ;;
  release) ;;
  released) ;;
  *) echo "fm-worktree-allocation: usage: $0 initialize <project> <timestamp> <complete|incomplete> [worktree ...] | acquire|release <task-id> <project> <worktree> <timestamp> [fresh|reused] | released <task-id> <project> <worktree>" >&2; exit 2 ;;
esac
if [ "$COMMAND" = initialize ]; then
  [ -n "$PROJECT" ] && [ -n "$EVENT_AT" ] || exit 2
elif [ "$COMMAND" = released ]; then
  [ -n "$TASK_ID" ] && [ -n "$PROJECT" ] && [ -n "$WORKTREE" ] || exit 2
else
  [ -n "$TASK_ID" ] && [ -n "$PROJECT" ] && [ -n "$WORKTREE" ] && [ -n "$EVENT_AT" ] || exit 2
fi

PROJECT_ID=$(node -e 'const c=require("crypto"); const p=process.argv[1].replace(/\\/g,"/").replace(/\/+$/g,"").toLowerCase(); process.stdout.write(c.createHash("sha256").update(p).digest("hex"))' "$PROJECT") || exit 1
LEDGER_DIR="$DATA/worktree-allocations"
LEDGER="$LEDGER_DIR/$PROJECT_ID.jsonl"
if [ "$COMMAND" = released ]; then
  [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] || exit 1
  exec node - "$LEDGER" "$TASK_ID" "$PROJECT" "$WORKTREE" <<'NODE'
const fs = require('fs')
const [file, taskId, project, worktree] = process.argv.slice(2)
const projectIdentity = String(project).replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase()
const identity = String(worktree).replace(/\\/g, '/').replace(/^\/+/, '').replace(/[-/_]+/g, '/').replace(/\/+$/, '').toLowerCase()
const canonical = value => {
  const time = Date.parse(value)
  return Number.isFinite(time) && new Date(time).toISOString().replace('.000Z', 'Z') === value ? value : null
}
if (!taskId || !projectIdentity || !identity) process.exit(2)
let records
try {
  records = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line))
} catch {
  process.exit(1)
}
if (records[0]?.schema !== 'fm-worktree-allocations.v1' || !canonical(records[0]?.tracking_started_at)
    || records[0]?.project_identity !== projectIdentity
    || typeof records[0]?.boundary_complete !== 'boolean') process.exit(1)
for (const record of records.slice(1)) {
  if (!['boundary', 'acquire', 'release'].includes(record?.event) || !record.task_id || !record.identity
      || !canonical(record.event_at) || !record.worktree) process.exit(1)
}
const events = records.slice(1)
const acquireIndex = events.findLastIndex(record => record.event === 'acquire' && record.task_id === taskId && record.identity === identity)
const released = events.slice(acquireIndex + 1).some(record => record.event === 'release' && record.task_id === taskId && record.identity === identity)
process.exit(released ? 0 : 1)
NODE
fi
mkdir -p "$LEDGER_DIR" "$STATE"
# shellcheck source=bin/fm-wake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
LOCK="$STATE/.worktree-allocation.lock"
fm_lock_acquire_wait "$LOCK" || exit 1
trap 'fm_lock_release "$LOCK" || true' EXIT

node - "$LEDGER" "$COMMAND" "$TASK_ID" "$PROJECT" "$WORKTREE" "$EVENT_AT" "$CANDIDATE" "${COMPLETENESS:-}" "$@" <<'NODE'
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const [file, command, taskId, project, worktree, eventAt, candidate, completeness, ...boundaryWorktrees] = process.argv.slice(2)
const projectIdentity = String(project).replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase()
const identity = String(worktree).replace(/\\/g, '/').replace(/^\/+/, '').replace(/[-/_]+/g, '/').replace(/\/+$/, '').toLowerCase()
const canonical = value => {
  const time = Date.parse(value)
  return Number.isFinite(time) && new Date(time).toISOString().replace('.000Z', 'Z') === value ? value : null
}
if (!projectIdentity || !canonical(eventAt) || (command !== 'initialize' && (!taskId || !identity))) process.exit(2)
let existed = true
let lines = []
try {
  lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean)
} catch (error) {
  if (error?.code !== 'ENOENT') process.exit(1)
  existed = false
}
let records = []
if (existed) {
  try { records = lines.map(line => JSON.parse(line)) } catch { process.exit(1) }
  if (records[0]?.schema !== 'fm-worktree-allocations.v1' || !canonical(records[0]?.tracking_started_at)
      || records[0]?.project_identity !== projectIdentity
      || typeof records[0]?.boundary_complete !== 'boolean') process.exit(1)
  for (const record of records.slice(1)) {
    if (!['boundary', 'acquire', 'release'].includes(record?.event) || !record.task_id || !record.identity
        || !canonical(record.event_at) || !record.worktree) process.exit(1)
  }
}
if (command === 'initialize') {
  if (existed) process.exit(0)
  const boundaryComplete = completeness === 'complete'
  records.push({schema: 'fm-worktree-allocations.v1', project_identity: projectIdentity,
    tracking_started_at: eventAt, boundary_complete: boundaryComplete})
  const seen = new Set()
  for (const item of boundaryWorktrees) {
    const itemIdentity = String(item).replace(/\\/g, '/').replace(/^\/+/, '').replace(/[-/_]+/g, '/').replace(/\/+$/, '').toLowerCase()
    if (!itemIdentity || seen.has(itemIdentity)) continue
    seen.add(itemIdentity)
    records.push({event: 'boundary', task_id: '-', worktree: item, identity: itemIdentity, event_at: eventAt, disposition: 'unknown'})
  }
  write(records)
  process.exit(0)
}
if (!existed) {
  records.push({schema: 'fm-worktree-allocations.v1', project_identity: projectIdentity,
    tracking_started_at: eventAt, boundary_complete: false})
}
const events = records.slice(1)
if (command === 'acquire') {
  const prior = events.some(record => record.identity === identity)
  const provenCreation = records[0].boundary_complete === true
    && Date.parse(eventAt) >= Date.parse(records[0].tracking_started_at) && !prior
  const disposition = candidate === 'reused' || prior ? 'reused'
    : candidate === 'fresh' && provenCreation ? 'first-owner' : 'unknown'
  const record = {event: 'acquire', task_id: taskId, worktree, identity, event_at: eventAt, disposition,
    origin: disposition === 'first-owner' ? 'created-after-tracking' : 'unproven'}
  const duplicate = events.find(item => item.event === 'acquire' && item.task_id === taskId && item.event_at === eventAt)
  if (duplicate) {
    if (JSON.stringify(duplicate) !== JSON.stringify(record)) process.exit(1)
    process.stdout.write(`${duplicate.disposition}\n`)
    process.exit(0)
  }
  records.push(record)
  write(records)
  process.stdout.write(`${disposition}\n`)
} else {
  const acquireIndex = events.findLastIndex(record => record.event === 'acquire' && record.task_id === taskId && record.identity === identity)
  const acquire = acquireIndex >= 0 ? events[acquireIndex] : null
  const record = {event: 'release', task_id: taskId, worktree, identity, event_at: eventAt, disposition: acquire?.disposition || 'unknown'}
  const duplicate = events.slice(acquireIndex + 1).find(item => item.event === 'release' && item.task_id === taskId && item.identity === identity)
  if (duplicate) {
    if (JSON.stringify(duplicate) !== JSON.stringify(record)) process.exit(1)
    process.exit(0)
  }
  records.push(record)
  write(records)
}
function write(values) {
  const dir = path.dirname(file)
  const staged = path.join(dir, `.worktree-allocations.${process.pid}.${crypto.randomBytes(8).toString('hex')}`)
  try {
    fs.writeFileSync(staged, `${values.map(value => JSON.stringify(value)).join('\n')}\n`, {mode: 0o600, flag: 'wx'})
    fs.renameSync(staged, file)
  } finally {
    try { fs.unlinkSync(staged) } catch {}
  }
}
NODE
