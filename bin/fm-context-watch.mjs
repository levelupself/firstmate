#!/usr/bin/env node
// fm-context-watch.mjs - a live worker's context size and compaction count,
// read from its own stamped session record. bin/fm-context-watch.sh is the
// operator entry point; bin/fm-watch.sh drives the tick mode on its poll.
//
//   fm-context-watch.mjs read <task-id> [--line]
//
//     Binds the task's launch receipts (data/<id>/sessions/launches.jsonl,
//     written by bin/fm-task-session.mjs) to their exact session records
//     through that module's stamp index, folds every main record from the
//     start, and prints one JSON object: {schema, task, harness, source,
//     context, peak, compactions, restarts, launches, records[]}. context is
//     the prompt size the newest launch's last request carried, peak the
//     largest figure seen across every launch, compactions the count across
//     every launch, and restarts the number of receipts beyond the first. The
//     per-harness fields and compaction invalidation are owned by
//     bin/fm-model-bench-analyze.mjs (foldContext). --line prints instead
//       context=<tokens> peak=<tokens> compactions=<n> harness=<h> source=<record>
//     A task with no bound record - no receipts, a harness that records no
//     stamp, or a stamped record the store has not written yet - exits 1 with
//     a named refusal on stderr and prints nothing, never a zero.
//
//   fm-context-watch.mjs usage <task-id>
//
//     Where the task's tokens went. Binds the same records as read, folds
//     every one with bin/fm-model-bench-analyze.mjs foldTurns (that header
//     owns the turn definition, the ceil(bytes/4) estimate rule, and the tool
//     class taxonomy), and prints one fm-task-tool-usage.v1 JSON object:
//     {schema, task, harness, status, reason?, records[], turns, tool_calls,
//     tool_result_bytes, tool_result_tokens_est, assistant_output_tokens,
//     base_prompt_tokens_est, tools[], classes[], largest[], timeline[]} with
//     turn indexes continuing across relaunched records in ledger order.
//     status is "present" when at least one model request was folded and
//     "unavailable" (reason names why, every count zero or null) when the
//     bound records carry none yet; an unbound task is refused exactly as
//     read refuses it. bin/fm-effort-store.mjs capture persists this object
//     as the task's durable data/<id>/tool-usage.json.
//
//   fm-context-watch.mjs tick
//
//     The watcher's per-poll pass over every live ordinary task
//     (state/<id>.meta whose kind is not secondmate and whose harness is
//     claude or codex). Each task keeps a private cache, state/<id>.context-watch
//     (schema fm-context-watch.v1): the bound records with a byte offset each,
//     the folded context/peak/compactions per record, and the roll-up. A poll
//     reads only the bytes appended since the offset and only for a record
//     whose size changed; a record that has not grown costs one stat. Binding
//     runs when the receipt ledger's size changes and is retried at most every
//     FM_CONTEXT_BIND_RETRY_SECS (default 60) while it fails, so an unbound
//     task never scans the session store every poll. The cache is a derived
//     accelerator: delete it to refold from the start.
//
//     The tick prints one tab-separated line per wake the watcher owes:
//       <task-id> TAB <reason> TAB <warned> TAB <compactions> TAB <restarts>
//     with reason either
//       context: <id> <N>k tokens (warn <W>k)   the first time context reaches
//                                               FM_CONTEXT_WARN_TOKENS (default
//                                               200000) and again at each further
//                                               FM_CONTEXT_WARN_STEP (default
//                                               100000)
//       context: <id> compacted (n=<count>)     on each new compaction
//     The watcher enqueues the wake and then records the three trailing fields
//     in state/.context-surfaced-<id> (warned=, compactions=, restarts=), the
//     marker this tick compares against; the tick never writes that marker, so
//     a wake that fails to enqueue is re-offered on the next poll. A compaction
//     or a relaunch resets the warned level: climbing back over the threshold
//     afterwards is a fresh crossing. Nothing is printed for an unchanged task.
//
// Environment: FM_HOME / FM_STATE_OVERRIDE / FM_DATA_OVERRIDE select the home
// exactly as bin/fm-task-session.mjs does; CLAUDE_CONFIG_DIR and CODEX_HOME
// are irrelevant here because each receipt names its store absolutely.
import fs from 'node:fs'
import path from 'node:path'
import {fileURLToPath} from 'node:url'
import {data, state, taskDir, index} from './fm-task-session.mjs'
import {foldContext, foldTurns, rollUpTurns} from './fm-model-bench-analyze.mjs'

const SCHEMA = 'fm-context-watch.v1'
const USAGE_SCHEMA = 'fm-task-tool-usage.v1'
const SUPPORTED = new Set(['claude', 'codex'])
const WARN_DEFAULT = 200000
const STEP_DEFAULT = 100000
const BIND_RETRY_DEFAULT = 60

function positiveInt(value, fallback) {
  const n = Number(value)
  return Number.isSafeInteger(n) && n > 0 ? n : fallback
}

const warnTokens = () => positiveInt(process.env.FM_CONTEXT_WARN_TOKENS, WARN_DEFAULT)
const stepTokens = () => positiveInt(process.env.FM_CONTEXT_WARN_STEP, STEP_DEFAULT)
const bindRetrySecs = () => positiveInt(process.env.FM_CONTEXT_BIND_RETRY_SECS, BIND_RETRY_DEFAULT)

class Refusal extends Error {}

function readMeta(id) {
  let text
  try { text = fs.readFileSync(path.join(state, `${id}.meta`), 'utf8') } catch { return null }
  const meta = {}
  for (const line of text.split('\n')) {
    const at = line.indexOf('=')
    if (at > 0) meta[line.slice(0, at)] = line.slice(at + 1)
  }
  return meta
}

// The receipts in ledger order. A receipt's harness decides the parser; the
// index below is what proves which record each stamp actually produced.
function readLedger(id) {
  const file = path.join(taskDir(id), 'sessions', 'launches.jsonl')
  let text
  try { text = fs.readFileSync(file, 'utf8') } catch {
    throw new Refusal(`no launch receipts under ${path.relative(data, path.dirname(file))}`)
  }
  const receipts = text.split('\n').filter(Boolean).map(line => {
    try { return JSON.parse(line) } catch { return null }
  }).filter(Boolean)
  if (!receipts.length) throw new Refusal(`no launch receipts in ${file}`)
  return {file, receipts, size: Buffer.byteLength(text)}
}

// Bind every receipt to its main record: for claude the transcript named by
// the stamp (sidechains have their own context and are excluded), for codex
// the one rollout whose originator is the stamp.
function bindRecords(id) {
  const ledger = readLedger(id)
  const harness = ledger.receipts[ledger.receipts.length - 1].harness
  if (!SUPPORTED.has(harness)) throw new Refusal(`harness ${harness} records no session stamp`)
  let sessions
  try { sessions = index(id) } catch (e) { throw new Refusal(e.message) }
  const records = []
  for (const receipt of ledger.receipts) {
    if (!SUPPORTED.has(receipt.harness)) throw new Refusal(`harness ${receipt.harness} records no session stamp`)
    const main = sessions.find(s => s.stamp === receipt.stamp && s.provider === receipt.harness
      && (s.provider === 'codex' || path.basename(s.file, '.jsonl') === receipt.stamp))
    if (!main) throw new Refusal(`stamped session ${receipt.stamp} has no main record`)
    records.push({stamp: receipt.stamp, file: main.file, harness: receipt.harness})
  }
  return {harness, ledger, records}
}

function parseLines(text) {
  const rows = []
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    try { rows.push(JSON.parse(line)) } catch { rows.push({__malformed: true}) }
  }
  return rows
}

// Read the complete lines appended after <offset>. A torn final line stays
// unread until its newline lands; a record shorter than the offset was
// replaced, so it is refolded from the start.
function readTail(file, offset) {
  const size = fs.statSync(file).size
  let from = Number.isSafeInteger(offset) && offset >= 0 && offset <= size ? offset : 0
  if (size === from) return {rows: [], offset: from, reset: from !== offset}
  const reset = from !== offset
  const fd = fs.openSync(file, 'r')
  let text
  try {
    const buf = Buffer.alloc(size - from)
    const got = fs.readSync(fd, buf, 0, buf.length, from)
    text = buf.toString('utf8', 0, got)
  } finally { fs.closeSync(fd) }
  const lastNl = text.lastIndexOf('\n')
  if (lastNl === -1) return {rows: [], offset: from, reset}
  const complete = text.slice(0, lastNl)
  return {rows: parseLines(complete), offset: from + Buffer.byteLength(complete) + 1, reset}
}

function rollUp(harness, records, launches) {
  const newest = records[records.length - 1]
  const measured = records.some(r => r.offset > 0)
  return {
    harness,
    source: newest ? newest.file : null,
    context: newest && Number.isFinite(newest.context) ? newest.context : null,
    peak: measured ? records.reduce((m, r) => Math.max(m, r.peak || 0), 0) : null,
    compactions: measured ? records.reduce((n, r) => n + (r.compactions || 0), 0) : null,
    restarts: Math.max(0, launches - 1),
    launches,
  }
}

// --- read -------------------------------------------------------------------

export function readTask(id) {
  const {harness, ledger, records} = bindRecords(id)
  const folded = records.map(r => {
    const tail = readTail(r.file, 0)
    const fold = foldContext(r.harness, tail.rows, null)
    return {stamp: r.stamp, file: r.file, harness: r.harness, offset: tail.offset, context: fold.context, peak: fold.peak, compactions: fold.compactions}
  })
  return {schema: SCHEMA, task: id, ...rollUp(harness, folded, ledger.receipts.length), records: folded}
}

export function readUsage(id) {
  const {harness, records} = bindRecords(id)
  const folds = records.map(r => foldTurns(r.harness, readTail(r.file, 0).rows))
  const roll = rollUpTurns(folds)
  const status = roll.turns > 0 ? 'present' : 'unavailable'
  return {
    schema: USAGE_SCHEMA,
    task: id,
    harness,
    status,
    ...(status === 'unavailable' ? {reason: 'no model request in the bound session records'} : {}),
    records: records.map(r => r.file),
    ...roll,
  }
}

function lineOf(result) {
  return `context=${result.context ?? 0} peak=${result.peak} compactions=${result.compactions} harness=${result.harness} source=${result.source}`
}

// --- tick -------------------------------------------------------------------

function cachePath(id) { return path.join(state, `${id}.context-watch`) }
function markerPath(id) { return path.join(state, `.context-surfaced-${id}`) }

function readCache(id) {
  try {
    const value = JSON.parse(fs.readFileSync(cachePath(id), 'utf8'))
    if (value && value.schema === SCHEMA && value.task === id && Array.isArray(value.records)
      && value.records.every(r => SUPPORTED.has(r.harness))) return value
  } catch { /* absent or unreadable: refold */ }
  return {schema: SCHEMA, task: id, harness: null, launches: 0, ledger_size: -1, records: [], refusal: null, bind_attempted: 0}
}

function writeCache(id, cache) {
  const file = cachePath(id)
  const tmp = `${file}.tmp.${process.pid}`
  fs.writeFileSync(tmp, JSON.stringify(cache) + '\n', {mode: 0o600})
  fs.renameSync(tmp, file)
}

function readMarker(id) {
  const marker = {warned: 0, compactions: 0, restarts: 0}
  let text
  try { text = fs.readFileSync(markerPath(id), 'utf8') } catch { return marker }
  for (const line of text.split('\n')) {
    const at = line.indexOf('=')
    if (at <= 0) continue
    const key = line.slice(0, at)
    const n = Number(line.slice(at + 1))
    if (key in marker && Number.isSafeInteger(n) && n >= 0) marker[key] = n
  }
  return marker
}

function kilo(tokens) { return `${Math.round(tokens / 1000)}k` }

// One task's tick: refresh its cache from record growth, then list the wakes
// owed against the surfaced marker. Returns the wake lines.
function tickTask(id, nowSecs) {
  const cache = readCache(id)
  let ledgerSize = -1
  try { ledgerSize = fs.statSync(path.join(taskDir(id), 'sessions', 'launches.jsonl')).size } catch { return [] }
  let changed = false
  // ledger_size is the ledger as last bound successfully, so a failed bind (a
  // relaunch whose record is not written yet) keeps the task due for another
  // attempt, throttled by bind_attempted; the records already bound keep
  // folding meanwhile.
  if (ledgerSize !== cache.ledger_size || cache.records.length === 0) {
    if (!cache.bind_attempted || nowSecs - cache.bind_attempted >= bindRetrySecs()) {
      cache.bind_attempted = nowSecs
      changed = true
      try {
        const bound = bindRecords(id)
        const prior = new Map(cache.records.map(r => [r.file, r]))
        cache.records = bound.records.map(r => {
          const old = prior.get(r.file)
          return old && old.harness === r.harness ? old
            : {...r, offset: 0, context: null, peak: 0, compactions: 0}
        })
        cache.harness = bound.harness
        cache.launches = bound.ledger.receipts.length
        cache.ledger_size = ledgerSize
        cache.refusal = null
      } catch (e) {
        cache.refusal = e.message
      }
    }
  }
  for (const record of cache.records) {
    let size
    try { size = fs.statSync(record.file).size } catch { continue }
    if (size === record.offset) continue
    const tail = readTail(record.file, record.offset)
    if (tail.reset) Object.assign(record, {context: null, peak: 0, compactions: 0})
    if (tail.rows.length > 0) {
      const fold = foldContext(record.harness, tail.rows, record)
      Object.assign(record, {context: fold.context, peak: fold.peak, compactions: fold.compactions})
    }
    if (tail.offset !== record.offset || tail.reset) { record.offset = tail.offset; changed = true }
  }
  const roll = rollUp(cache.harness, cache.records, cache.launches)
  Object.assign(cache, {context: roll.context, peak: roll.peak, compactions: roll.compactions,
    restarts: roll.restarts, source: roll.source})
  if (changed) { cache.updated = new Date(nowSecs * 1000).toISOString(); writeCache(id, cache) }

  const marker = readMarker(id)
  if (roll.restarts > marker.restarts) marker.warned = 0
  const wakes = []
  if (roll.compactions > marker.compactions) {
    wakes.push([id, `context: ${id} compacted (n=${roll.compactions})`, 0, roll.compactions, roll.restarts])
    marker.warned = 0
  }
  const warn = warnTokens()
  const step = stepTokens()
  const level = roll.context !== null && roll.context >= warn
    ? warn + Math.floor((roll.context - warn) / step) * step : 0
  if (level > marker.warned) {
    wakes.push([id, `context: ${id} ${kilo(roll.context)} tokens (warn ${kilo(warn)})`, level, roll.compactions, roll.restarts])
  }
  return wakes
}

function tick() {
  const nowSecs = Math.floor(Date.now() / 1000)
  let names
  try { names = fs.readdirSync(state) } catch { return }
  for (const name of names.filter(n => n.endsWith('.meta')).sort()) {
    const id = name.slice(0, -'.meta'.length)
    const meta = readMeta(id)
    if (!meta || meta.kind === 'secondmate' || !SUPPORTED.has(meta.harness)) continue
    let wakes
    try { wakes = tickTask(id, nowSecs) } catch (e) {
      process.stderr.write(`fm-context-watch: ${id}: ${e.message}\n`)
      continue
    }
    for (const wake of wakes) process.stdout.write(wake.join('\t') + '\n')
  }
}

// --- main -------------------------------------------------------------------

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, ...args] = process.argv.slice(2)
  try {
    if (mode === 'read') {
      const id = args.find(a => !a.startsWith('--'))
      if (!id) throw new Error('usage: fm-context-watch.mjs read <task-id> [--line]')
      let result
      try { result = readTask(id) } catch (e) {
        if (e instanceof Refusal) {
          process.stderr.write(`fm-context-watch: ${id}: no session record bound (${e.message})\n`)
          process.exit(1)
        }
        throw e
      }
      process.stdout.write((args.includes('--line') ? lineOf(result) : JSON.stringify(result)) + '\n')
    } else if (mode === 'usage') {
      const id = args.find(a => !a.startsWith('--'))
      if (!id) throw new Error('usage: fm-context-watch.mjs usage <task-id>')
      let result
      try { result = readUsage(id) } catch (e) {
        if (e instanceof Refusal) {
          process.stderr.write(`fm-context-watch: ${id}: no session record bound (${e.message})\n`)
          process.exit(1)
        }
        throw e
      }
      process.stdout.write(JSON.stringify(result) + '\n')
    } else if (mode === 'tick') {
      tick()
    } else {
      throw new Error('usage: fm-context-watch.mjs read <task-id> [--line] | usage <task-id> | tick')
    }
  } catch (e) {
    process.stderr.write(`fm-context-watch: ${e.message}\n`)
    process.exitCode = 2
  }
}
