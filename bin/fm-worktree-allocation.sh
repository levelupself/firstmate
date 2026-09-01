#!/usr/bin/env bash
set -u

COMMAND=${1:-}
TASK_ID=${2:-}
WORKTREE=${3:-}
EVENT_AT=${4:-}
CANDIDATE=${5:-}
FM_HOME=${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
LEDGER="$DATA/worktree-allocations.jsonl"

case "$COMMAND" in
  acquire)
    [ "$CANDIDATE" = fresh ] || [ "$CANDIDATE" = reused ] || CANDIDATE=unknown
    ;;
  release) ;;
  *) echo "fm-worktree-allocation: usage: $0 acquire|release <task-id> <worktree> <timestamp> [fresh|reused]" >&2; exit 2 ;;
esac
[ -n "$TASK_ID" ] && [ -n "$WORKTREE" ] && [ -n "$EVENT_AT" ] || exit 2

mkdir -p "$DATA" "$STATE"
# shellcheck source=bin/fm-wake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
LOCK="$STATE/.worktree-allocation.lock"
fm_lock_acquire_wait "$LOCK" || exit 1
trap 'fm_lock_release "$LOCK" || true' EXIT

node - "$LEDGER" "$COMMAND" "$TASK_ID" "$WORKTREE" "$EVENT_AT" "$CANDIDATE" <<'NODE'
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const [file, command, taskId, worktree, eventAt, candidate] = process.argv.slice(2)
const identity = String(worktree).replace(/\\/g, '/').replace(/^\/+/, '').replace(/[-/_]+/g, '/').replace(/\/+$/, '').toLowerCase()
const canonical = value => {
  const time = Date.parse(value)
  return Number.isFinite(time) && new Date(time).toISOString().replace('.000Z', 'Z') === value ? value : null
}
if (!taskId || !identity || !canonical(eventAt)) process.exit(2)
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
  if (records[0]?.schema !== 'fm-worktree-allocations.v1' || !canonical(records[0]?.tracking_started_at)) process.exit(1)
  for (const record of records.slice(1)) {
    if (!['acquire', 'release'].includes(record?.event) || !record.task_id || !record.identity
        || !canonical(record.event_at) || !record.worktree) process.exit(1)
  }
} else {
  records.push({schema: 'fm-worktree-allocations.v1', tracking_started_at: eventAt})
}
const events = records.slice(1)
if (command === 'acquire') {
  const prior = events.some(record => record.identity === identity)
  const disposition = candidate === 'reused' || prior ? 'reused'
    : candidate === 'fresh' && existed ? 'first-owner' : 'unknown'
  const record = {event: 'acquire', task_id: taskId, worktree, identity, event_at: eventAt, disposition}
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
  const acquire = [...events].reverse().find(record => record.event === 'acquire' && record.task_id === taskId && record.identity === identity)
  const record = {event: 'release', task_id: taskId, worktree, identity, event_at: eventAt, disposition: acquire?.disposition || 'unknown'}
  const duplicate = events.find(item => item.event === 'release' && item.task_id === taskId && item.identity === identity)
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
