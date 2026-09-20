#!/usr/bin/env node
// Ingestion and schema for the derived agentic-effort store.
//
// This module owns lifecycle capture and the derived layer. The raw layer,
// data/cost-attribution.tsv, is irreplaceable and append-only. Everything in
// the database is recomputed from three durable sources plus one recorded-by-
// hand source, so the file is safe to delete and `rebuild` restores it exactly.
// Pipeline process counts are read once at a settled sanctioned merge edge and
// become raw lifecycle input; rebuild never consults the mutable pipeline DB.
//
//   raw         data/cost-attribution.tsv       identity, lifecycle, process
//   codeburn    data/<task>/usage.json           effort tokens and notional cost
//   tool-usage  data/<task>/tool-usage.json      where the tokens went, per turn
//   ci          data/pr-ci/<task>.json           the forge's run ledger for the PR
//   git         the project clone               structure, time, durability
//   annotation  data/effort-annotations.jsonl   the posterior nobody can derive
//
// ci is the fm-pr-ci.v1 ledger `capture-ci` reads from GitHub with `gh api`
// (the official CLI, because its raw JSON carries the nested run and job
// arrays) at the sanctioned merge edge, and `backfill-ci` pulls once for
// receipts that predate it: the PR, every workflow run on its head branch
// created before it closed, and each run's jobs across all attempts. Rebuild
// derives the counts and minutes from the recorded runs and never consults the
// forge. Landing is `direct` for a merged PR, `train:<n>` for a manifest
// member of a merged train PR (title `train:` or a `## Manifest` section,
// members `- #<pr> fm/<task-id> ...`) or a closed PR whose closing comment or
// Done row names its train, and `closed` for a closed PR with no train
// evidence. `**N moved**` in the body is the card claim. A run counts as
// failed on a failure, timed_out, or startup_failure conclusion; runner
// seconds sum job durations; queue seconds run from run creation to the first
// job start. Runs on the default branch after the merge are not the PR's.
//
// tool-usage is the fm-task-tool-usage.v1 object bin/fm-context-watch.mjs
// usage folds from the task's bound session records, persisted by capture
// while those records exist and bound to the launch by spawned_at. Capture is
// the only writer: rebuild reads the snapshot and never a session record, so
// the breakdown is forward-only. A bound record that yields no request is
// persisted as status "unavailable" and surfaces as an ingest issue, the same
// way an unusable cost snapshot does. Token figures derived from bytes are
// estimates under the one rule in that reader's header (ceil(bytes / 4)) and
// keep the _est suffix in every column and report label.
//
// The fourth source exists because two of the required fields - round_reasons
// and the loud/quiet failure bit - are not inferable from any artifact, and the
// database is deletable. A field recorded only in the database would not
// survive its own rebuild contract, so recorded-by-hand values live in an
// append-only file beside the raw layer and are read back in as an input.
//
// Missingness is data. A source that could not be consulted for a task is
// stored as a `missing` row in task_source and leaves its columns NULL; a
// source that was consulted and legitimately found nothing is stored as
// `present` with real zeros. Nothing that arrives is dropped: a raw line whose
// schema section is not the v2 join is recorded in ingest_issue rather than
// guessed at.
//
// Determinism: rebuild consults no current wall clock. Event times are durable
// inputs, so two rebuilds over the same inputs produce identical content and
// `fingerprint` can prove it. Capture only appends evidence; the shell queues
// ingestion. Database publication is atomic, so readers never see a partial
// rebuild. Commit-keyed git inventories are disposable ingestion accelerators.
//
// bin/fm-effort-store.sh is the entry point and owns the CLI contract; run it
// with --help. This file is invoked by that script and not directly.

const SCHEMA_VERSION = 'fm-effort-store.v5'
const CLASSIFIER_VERSION = 'fm-effort-classifier.v1'
const V2_MARKER = '# schema=firstmate-effort-attribution-v2'
const LEGACY_CAPTURE_COLUMNS = [
  'task', 'worktree', 'harness', 'model', 'effort', 'kind', 'project', 'captured',
]
const MAX_IMPORT_FILE_BYTES = 512 * 1024
// Composite keys and the fingerprint join on a byte no path, model name, or
// column value can contain, so two different tuples can never collide.
const KEY_SEPARATOR = String.fromCharCode(0)
// A NULL is not the string "NULL": the fingerprint must tell an absent source
// from a value that happens to spell it.
const NULL_MARKER = String.fromCharCode(1) + 'NULL'
// git log output is framed with ASCII record and unit separators so a commit
// subject or body can hold anything without confusing the parser.
const RECORD_SEPARATOR = String.fromCharCode(0x1e)
const FIELD_SEPARATOR = String.fromCharCode(0x1f)

// node:sqlite is behind an experimental warning on the supported Node line.
// Silence that one warning before the import so ingestion stderr carries only
// real diagnostics, and leave every other warning alone.
const nodeEmitWarning = process.emitWarning
process.emitWarning = (warning, ...rest) => {
  const type = typeof rest[0] === 'string' ? rest[0] : rest[0]?.type
  if (type === 'ExperimentalWarning' && /SQLite/i.test(String(warning))) return undefined
  return nodeEmitWarning.call(process, warning, ...rest)
}

const { DatabaseSync } = await import('node:sqlite')
const fs = await import('node:fs')
const path = await import('node:path')
const crypto = await import('node:crypto')
const { spawnSync } = await import('node:child_process')
const { fileURLToPath } = await import('node:url')
const { TOOL_CLASSES: TOOL_CLASS_ORDER } = await import('./fm-model-bench-analyze.mjs')

// --- small helpers ----------------------------------------------------------

const warn = message => process.stderr.write(`fm-effort-store: ${message}\n`)
const sortedBy = (items, key) => [...items].sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0))

function readTextFile(file) {
  try {
    return fs.readFileSync(file, 'utf8')
  } catch {
    return null
  }
}

// The raw layer escapes backslash, tab, CR and LF so a value can never break
// the row. The teardown capture owns that contract; this is its inverse.
function unescapeRawValue(value) {
  let out = ''
  for (let i = 0; i < value.length; i += 1) {
    if (value[i] !== '\\' || i + 1 >= value.length) {
      out += value[i]
      continue
    }
    i += 1
    const next = value[i]
    if (next === 't') out += '\t'
    else if (next === 'r') out += '\r'
    else if (next === 'n') out += '\n'
    else if (next === '\\') out += '\\'
    else out += `\\${next}`
  }
  return out
}

function escapeRawValue(value) {
  return String(value ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/\t/g, '\\t')
    .replace(/\r/g, '\\r')
    .replace(/\n/g, '\\n')
}

function readMeta(file) {
  const text = readTextFile(file)
  if (text === null) return null
  const meta = {}
  for (const line of text.split('\n')) {
    const separator = line.indexOf('=')
    if (separator <= 0) continue
    meta[line.slice(0, separator)] = line.slice(separator + 1)
  }
  return meta
}

function readMetaWithRequiredFields(file, requiredFields) {
  let descriptor
  let text
  try {
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW)
    const stat = fs.fstatSync(descriptor)
    if (!stat.isFile() || stat.size > MAX_IMPORT_FILE_BYTES) return null
    text = fs.readFileSync(descriptor, 'utf8')
  } catch {
    return null
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
  const meta = {}
  const counts = new Map()
  for (const line of text.split('\n')) {
    const separator = line.indexOf('=')
    if (separator <= 0) continue
    const key = line.slice(0, separator)
    meta[key] = line.slice(separator + 1)
    counts.set(key, (counts.get(key) || 0) + 1)
  }
  return requiredFields.every(field => counts.get(field) === 1) ? meta : null
}

// Immutable commit inventories include numstat, statuses, and rename-following
// history anchored at that commit. Cache only successful reads, scoped by repo
// and commit; changing refs still resolves ownership again on each ingestion.
let gitCacheRoot = null
const gitCache = new Map()
const gitMemo = new Map()
function git(repo, args, {timeoutMs = 20000} = {}) {
  const memoKey = JSON.stringify([repo, args])
  if (gitMemo.has(memoKey)) return gitMemo.get(memoKey)
  const sha = args[0] === 'show' ? args.at(-1)
    : args[0] === 'log' && args[1] === '--follow' ? args[5] : null
  let inventory = null
  let cacheFile = null
  const query = JSON.stringify(args)
  if (gitCacheRoot && /^[a-f0-9]{40,64}$/.test(sha || '')) {
    const repoKey = crypto.createHash('sha256').update(path.resolve(repo)).digest('hex')
    cacheFile = path.join(gitCacheRoot, repoKey, `${sha}.json`)
    inventory = gitCache.get(cacheFile)
    if (!inventory) {
      try {
        const saved = JSON.parse(fs.readFileSync(cacheFile, 'utf8'))
        if (saved.version === 1 && saved.commit === sha && saved.queries
            && typeof saved.queries === 'object' && !Array.isArray(saved.queries)) inventory = saved
      } catch { /* A missing or corrupt disposable cache is rebuilt. */ }
      inventory ||= {version: 1, commit: sha, queries: {}}
      gitCache.set(cacheFile, inventory)
    }
    if (typeof inventory.queries[query] === 'string') return inventory.queries[query]
  }
  const result = spawnSync('git', ['-C', repo, ...args], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    timeout: timeoutMs,
  })
  if (result.error || result.status !== 0) return null
  gitMemo.set(memoKey, result.stdout)
  if (inventory) {
    inventory.queries[query] = result.stdout
    fs.mkdirSync(path.dirname(cacheFile), {recursive: true})
    const temporary = `${cacheFile}.${process.pid}.tmp`
    fs.writeFileSync(temporary, JSON.stringify(inventory), {mode: 0o600})
    fs.renameSync(temporary, cacheFile)
  }
  return result.stdout
}

const PIPELINE_GATE_STEPS = new Set(['rebase', 'test', 'document', 'lint', 'ci'])
const PIPELINE_SETTLED_STEPS = new Set(['rebase', 'review', 'test', 'document', 'lint', 'ci'])
const PIPELINE_METRICS_UNAVAILABLE = Symbol('pipeline-metrics-unavailable')

function readPipelineMetrics(dbPath, identity) {
  if (!dbPath || !identity.project || !identity.branch || !identity.prUrl) return null
  try {
    if (!fs.statSync(dbPath).isFile()) return null
  } catch {
    return null
  }
  let db
  let authoritativeRunSelected = false
  try {
    db = new DatabaseSync(dbPath, {readOnly: true})
    const run = db.prepare(`
      SELECT runs.id
      FROM runs
      JOIN repos ON repos.id = runs.repo_id
      WHERE repos.working_path = ? AND runs.branch = ? AND runs.pr_url = ?
        AND runs.status != 'cancelled'
      ORDER BY runs.created_at DESC, runs.id DESC
      LIMIT 1
    `).get(identity.project, identity.branch, identity.prUrl)
    authoritativeRunSelected = Boolean(run)
    if (run) {
      const steps = db.prepare(`
        SELECT id, step_name, status
        FROM step_results
        WHERE run_id = ?
        ORDER BY step_name, id
      `).all(run.id)
      const byName = new Map(steps.map(step => [step.step_name, step]))
      if ([...PIPELINE_SETTLED_STEPS].some(name => {
        const status = byName.get(name)?.status
        return status !== 'completed' && status !== 'skipped'
      })) {
        db.close()
        return PIPELINE_METRICS_UNAVAILABLE
      }
      const rounds = db.prepare(`
        SELECT step_results.step_name, step_rounds.round, step_rounds.findings_json
        FROM step_rounds
        JOIN step_results ON step_results.id = step_rounds.step_result_id
        WHERE step_results.run_id = ?
        ORDER BY step_results.step_name, step_rounds.round, step_rounds.id
      `).all(run.id)
      if (!rounds.some(round => round.step_name === 'review')) {
        db.close()
        return PIPELINE_METRICS_UNAVAILABLE
      }
      let findings = 0
      let reviewRounds = 0
      let askUserCount = 0
      let gateFailures = 0
      let valid = true
      for (const round of rounds) {
        let reported
        try {
          if (round.findings_json === null) throw new Error('missing findings record')
          const parsed = JSON.parse(round.findings_json)
          if (!Array.isArray(parsed?.findings)) throw new Error('missing findings array')
          reported = parsed.findings
        } catch {
          valid = false
          break
        }
        findings += reported.length
        askUserCount += reported.filter(finding => finding?.action === 'ask-user').length
        if (round.step_name === 'review') reviewRounds += 1
        if (PIPELINE_GATE_STEPS.has(round.step_name) && reported.length > 0) gateFailures += 1
      }
      if (!valid) {
        db.close()
        return PIPELINE_METRICS_UNAVAILABLE
      }
      db.close()
      return {
        pipeline_run_id: run.id,
        findings,
        review_rounds: reviewRounds,
        ask_user_count: askUserCount,
        gate_failures: gateFailures,
      }
    }
    db.close()
    return null
  } catch {
    if (db) db.close()
    return authoritativeRunSelected ? PIPELINE_METRICS_UNAVAILABLE : null
  }
}

// --- source 1: the raw capture ---------------------------------------------
//
// The file is a sequence of sections, each opened by its own `# schema=` line.
// The original eight-column preamble has a declared identity shape but no
// launch timestamp, so its task and project fields are retained without
// turning `captured` into lifecycle time. Other preamble or unknown-section
// lines are surfaced as issues instead of being coerced into a guessed shape.

function rawDigest(text) {
  return crypto.createHash('sha256').update(text ?? '').digest('hex')
}

function readRawCapture(file, issues) {
  const text = readTextFile(file)
  if (text === null) {
    // An empty store and an unreadable raw layer look the same from the outside,
    // so say which one happened.
    issues.push({source: 'raw', task_id: null, kind: 'capture-unreadable', detail: file})
    return {rows: [], digest: rawDigest(null)}
  }
  const rows = []
  let section = 'preamble'
  let columns = null
  for (const line of text.split('\n')) {
    if (line === '') continue
    if (line.startsWith('# schema=')) {
      section = line.trim() === V2_MARKER ? 'v2' : 'unknown'
      columns = null
      continue
    }
    const fields = line.split('\t').map(unescapeRawValue)
    if (section === 'preamble' && columns === null
        && fields.length === LEGACY_CAPTURE_COLUMNS.length
        && fields.every((field, index) => field === LEGACY_CAPTURE_COLUMNS[index])) {
      section = 'v1'
      columns = fields
      continue
    }
    if (section !== 'v2' && section !== 'v1') {
      issues.push({source: 'raw', task_id: null, kind: 'unparsed-legacy-line', detail: line})
      continue
    }
    if (columns === null) {
      if (fields[0] === 'task' && fields[1] === 'worktree') {
        columns = fields
        continue
      }
      issues.push({source: 'raw', task_id: null, kind: 'v2-row-before-header', detail: line})
      continue
    }
    if (fields.length !== columns.length) {
      issues.push({
        source: 'raw',
        task_id: section === 'v2' ? (fields[0] || null) : null,
        kind: section === 'v2' ? 'v2-column-count' : 'legacy-column-count',
        detail: line,
      })
      continue
    }
    const row = {}
    columns.forEach((name, index) => { row[name] = fields[index] === '' ? null : fields[index] })
    if (!row.task) {
      issues.push({source: 'raw', task_id: null, kind: 'v2-row-without-task', detail: line})
      continue
    }
    if (section === 'v1') {
      rows.push({
        task: row.task,
        worktree: row.worktree,
        harness: row.harness,
        model: row.model,
        effort: row.effort,
        kind: row.kind,
        project: row.project,
      })
    } else {
      rows.push(row)
    }
  }
  return {rows, digest: rawDigest(text)}
}

// --- source 4: recorded-by-hand annotations --------------------------------

const ROUND_REASONS = new Set(['discovery', 'churn'])
const FAILURE_MODES = new Set(['loudly', 'quietly'])

function readAnnotations(file, issues) {
  const text = readTextFile(file)
  if (text === null) return {byTask: new Map()}
  const byTask = new Map()
  text.split('\n').forEach((line, index) => {
    if (line.trim() === '') return
    let record
    try {
      record = JSON.parse(line)
    } catch {
      issues.push({source: 'annotation', task_id: null, kind: 'unparsable-json', detail: `line ${index + 1}`})
      return
    }
    const taskId = typeof record.task === 'string' ? record.task : ''
    if (!taskId) {
      issues.push({source: 'annotation', task_id: null, kind: 'record-without-task', detail: `line ${index + 1}`})
      return
    }
    // Append-only file, merged field by field with the later line winning, so a
    // failure mode recorded a week after the round reasons does not erase them.
    // Every superseded line stays readable on disk.
    byTask.set(taskId, {...(byTask.get(taskId) || {}), ...record})
  })
  for (const [taskId, record] of byTask) {
    if (record.failure_mode != null && !FAILURE_MODES.has(record.failure_mode)) {
      issues.push({source: 'annotation', task_id: taskId, kind: 'unknown-failure-mode', detail: String(record.failure_mode)})
      record.failure_mode = null
    }
    const rounds = Array.isArray(record.round_reasons) ? record.round_reasons : []
    record.round_reasons = rounds.filter(round => {
      if (ROUND_REASONS.has(round?.reason)) return true
      issues.push({source: 'annotation', task_id: taskId, kind: 'unknown-round-reason', detail: String(round?.reason)})
      return false
    })
  }
  return {byTask}
}

// --- source 2: durable codeburn task snapshots -----------------------------
//
// fm-task-usage writes the task-bounded snapshot while volatile metadata still
// exists. Rebuild consumes only that durable artifact. Re-querying account-wide
// logs here would make an old row change as logs rotate and would turn a failed
// historical attribution into a plausible zero.

const TASK_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

function finiteNonnegative(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
}

function readTaskUsage(dataDir, taskId, spawnedAt, endedAt, issues) {
  if (!TASK_ID_PATTERN.test(taskId)) {
    return {status: 'missing', detail: 'task id is not safe for a durable usage path'}
  }
  const file = path.join(dataDir, taskId, 'usage.json')
  const text = readTextFile(file)
  if (text === null) {
    const baseline = path.join(dataDir, taskId, 'usage-baseline.json')
    let baselineIsFile = false
    try {
      const stat = fs.lstatSync(baseline)
      baselineIsFile = stat.isFile() && !stat.isSymbolicLink()
    } catch {}
    if (!spawnedAt && baselineIsFile) {
      issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-pre-deterministic-attribution', detail: baseline})
      return {status: 'missing', detail: 'launch baseline exists but deterministic lifecycle capture and final usage do not'}
    }
    return {status: 'missing', detail: 'durable task usage snapshot is absent'}
  }
  let usage
  try {
    usage = JSON.parse(text)
  } catch {
    issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-unparsable', detail: file})
    return {status: 'missing', detail: 'durable task usage snapshot is not valid JSON'}
  }
  if (!['fm-task-usage.v1', 'fm-task-usage.v2', 'fm-task-usage.v3'].includes(usage.schema) || usage.id !== taskId) {
    issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-identity', detail: file})
    return {status: 'missing', detail: 'durable task usage snapshot has the wrong schema or task id'}
  }
  if (usage.schema === 'fm-task-usage.v1') {
    issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-pre-deterministic-attribution', detail: file})
    return {status: 'missing', detail: 'legacy usage snapshot predates deterministic project attribution'}
  }
  if (!spawnedAt || usage.spawned_at !== spawnedAt) {
    issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-launch-identity', detail: file})
    return {status: 'missing', detail: 'durable task usage snapshot belongs to another launch'}
  }
  const baselineBounded = usage.correlation?.baseline === true
  const windowBounded = usage.correlation?.attribution === 'timestamp-window'
    && usage.correlation?.baseline === false
    && usage.correlation?.window?.start === spawnedAt
    && usage.correlation?.window?.end === endedAt
    && Number.isSafeInteger(usage.correlation?.records)
    && usage.correlation.records > 0
    && /^[0-9a-f]{64}$/.test(usage.correlation?.export_sha256 || '')
  const stampBounded = usage.correlation?.attribution === 'session-stamp'
    && Array.isArray(usage.correlation.session_records)
    && usage.correlation.session_records.length > 0
    && usage.correlation.session_records.length === usage.sessions
    && new Set(usage.correlation.session_records.map(record => `${record?.provider}\0${record?.id}`)).size === usage.sessions
    && usage.correlation.session_records.every(record => typeof record?.id === 'string' && record.id
      && typeof record.file === 'string' && path.isAbsolute(record.file)
      && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(record.stamp || '')
      && ['claude', 'codex'].includes(record.provider))
  if ((!baselineBounded && !windowBounded && !stampBounded) || (usage.schema === 'fm-task-usage.v3' && !stampBounded)) {
    issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-unbounded-attribution', detail: file})
    return {status: 'missing', detail: 'durable task usage snapshot lacks a valid session stamp, launch baseline, or timestamp window'}
  }
  const totals = {
    tokens_in: finiteNonnegative(usage.tokens?.input),
    tokens_out: finiteNonnegative(usage.tokens?.output),
    tokens_reasoning: finiteNonnegative(usage.tokens?.reasoning),
    tokens_cached_read: finiteNonnegative(usage.tokens?.cache_read),
    tokens_cached_write: finiteNonnegative(usage.tokens?.cache_write),
    notional_cost_usd: finiteNonnegative(usage.cost_usd),
    api_calls: finiteNonnegative(usage.calls),
    sessions: finiteNonnegative(usage.sessions),
    agent_active_seconds: finiteNonnegative(usage.agent_active_seconds),
  }
  const required = ['tokens_in', 'tokens_out', 'tokens_cached_read', 'tokens_cached_write', 'notional_cost_usd', 'api_calls', 'sessions']
  if (required.some(key => totals[key] === null)) {
    issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-shape', detail: file})
    return {status: 'missing', detail: 'durable task usage snapshot is missing required totals'}
  }
  if (!Array.isArray(usage.models) || !Array.isArray(usage.actual_models)) {
    issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-model-shape', detail: file})
    return {status: 'missing', detail: 'durable task usage snapshot has malformed model collections'}
  }
  const producedModelNames = []
  const producedModelIdentities = new Set()
  for (const model of usage.models) {
    const name = typeof model?.name === 'string' ? model.name : ''
    const provider = typeof model?.provider === 'string' ? model.provider.trim() : ''
    const normalizedName = name.trim()
    const identity = `${provider}${KEY_SEPARATOR}${normalizedName}`
    const modelTotals = [model?.calls, model?.input_tokens, model?.output_tokens,
      model?.cache_read_tokens, model?.cache_write_tokens, model?.cost_usd]
    const unknownModelTotals = usage.schema === 'fm-task-usage.v3' && stampBounded
      && modelTotals.every(value => value === null)
    if (!normalizedName || normalizedName === '<synthetic>'
        || (!unknownModelTotals && modelTotals.some(value => typeof value !== 'number' || !Number.isFinite(value) || value < 0))) {
      issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-model-shape', detail: file})
      return {status: 'missing', detail: 'durable task usage snapshot has a malformed model entry'}
    }
    if (producedModelIdentities.has(identity)) {
      issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-model-duplicate', detail: file})
      return {status: 'missing', detail: 'durable task usage snapshot has duplicate model identities'}
    }
    producedModelIdentities.add(identity)
    producedModelNames.push(name)
  }
  if (usage.actual_models.some(name => typeof name !== 'string' || !name.trim())
      || JSON.stringify(usage.actual_models) !== JSON.stringify(producedModelNames)) {
    issues.push({source: 'codeburn', task_id: taskId, kind: 'usage-model-identity', detail: file})
    return {status: 'missing', detail: 'durable task usage snapshot model collections disagree'}
  }
  const models = []
  for (const model of usage.models) {
    const name = model.name.trim()
    models.push({
      provider: typeof model.provider === 'string' ? model.provider.trim() : '',
      model: name,
      tokens_in: finiteNonnegative(model.input_tokens),
      tokens_out: finiteNonnegative(model.output_tokens),
      tokens_reasoning: finiteNonnegative(model.reasoning_tokens),
      tokens_cached_read: finiteNonnegative(model.cache_read_tokens),
      tokens_cached_write: finiteNonnegative(model.cache_write_tokens),
      notional_cost_usd: finiteNonnegative(model.cost_usd),
      api_calls: finiteNonnegative(model.calls),
    })
  }
  return {
    status: 'present',
    detail: `${usage.schema} durable task usage snapshot`,
    totals,
    models: sortedBy(models, model => [model.provider, model.model].join(KEY_SEPARATOR)),
    usage,
  }
}

function discoverUsageTaskIds(dataDir) {
  let entries
  try {
    entries = fs.readdirSync(dataDir, {withFileTypes: true})
  } catch {
    return []
  }
  return entries
    .filter(entry => entry.isDirectory() && TASK_ID_PATTERN.test(entry.name)
      && (fs.existsSync(path.join(dataDir, entry.name, 'usage.json'))
        || fs.existsSync(path.join(dataDir, entry.name, 'usage-baseline.json'))))
    .map(entry => entry.name)
}

function collectUsage(tasks, options, issues) {
  const byTask = new Map()
  for (const task of tasks) {
    byTask.set(task.taskId, readTaskUsage(options.dataDir, task.taskId,
      canonicalTimestamp(task.raw?.started_at),
      validatedLifecycleTimestamp(task.raw?.ended_at, canonicalTimestamp(task.raw?.started_at)),
      issues))
  }
  return byTask
}

// --- source 2b: the tool-usage snapshot ------------------------------------

const TOOL_CLASSES = new Set(TOOL_CLASS_ORDER)
const TOOL_CLASS_LIST = TOOL_CLASS_ORDER.map(cls => `'${cls}'`).join(', ')
const TOOL_USAGE_SCHEMA = 'fm-task-tool-usage.v1'

const countOrNull = value => (Number.isSafeInteger(value) && value >= 0 ? value : null)
const secondsOrNull = value => (value === null ? null : (typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : undefined))

function readTaskToolUsage(dataDir, taskId, spawnedAt, issues) {
  if (!TASK_ID_PATTERN.test(taskId)) return {status: 'missing', detail: 'task id is not safe for a durable usage path'}
  const file = path.join(dataDir, taskId, 'tool-usage.json')
  const text = readTextFile(file)
  if (text === null) return {status: 'missing', detail: 'no tool-usage snapshot was captured'}
  let usage
  try { usage = JSON.parse(text) } catch {
    issues.push({source: 'tool-usage', task_id: taskId, kind: 'tool-usage-unparsable', detail: file})
    return {status: 'missing', detail: 'tool-usage snapshot is not valid JSON'}
  }
  if (usage?.schema !== TOOL_USAGE_SCHEMA || usage.task !== taskId) {
    issues.push({source: 'tool-usage', task_id: taskId, kind: 'tool-usage-identity', detail: file})
    return {status: 'missing', detail: 'tool-usage snapshot has the wrong schema or task id'}
  }
  if (!spawnedAt || usage.spawned_at !== spawnedAt) {
    issues.push({source: 'tool-usage', task_id: taskId, kind: 'tool-usage-launch-identity', detail: file})
    return {status: 'missing', detail: 'tool-usage snapshot belongs to another launch'}
  }
  if (usage.status === 'unavailable') {
    issues.push({source: 'tool-usage', task_id: taskId, kind: 'tool-usage-unavailable', detail: String(usage.reason || file)})
    return {status: 'missing', detail: `bound session records yielded no breakdown: ${usage.reason || 'unknown reason'}`}
  }
  const shape = () => {
    issues.push({source: 'tool-usage', task_id: taskId, kind: 'tool-usage-shape', detail: file})
    return {status: 'missing', detail: 'tool-usage snapshot is malformed'}
  }
  const summary = {
    turns: countOrNull(usage.turns),
    tool_calls: countOrNull(usage.tool_calls),
    tool_result_tokens_est: countOrNull(usage.tool_result_tokens_est),
    assistant_output_tokens: countOrNull(usage.assistant_output_tokens),
    base_prompt_tokens_est: countOrNull(usage.base_prompt_tokens_est),
  }
  if (usage.status !== 'present' || Object.values(summary).some(value => value === null) || summary.turns === 0) return shape()
  if (![usage.tools, usage.classes, usage.largest, usage.timeline].every(Array.isArray)) return shape()
  const usageRow = (row, withName) => {
    const out = {
      tool_name: withName ? row?.tool_name : undefined,
      tool_class: row?.tool_class,
      calls: countOrNull(row?.calls),
      result_bytes: countOrNull(row?.result_bytes),
      result_tokens_est: countOrNull(row?.result_tokens_est),
      wall_seconds_in_tool: secondsOrNull(row?.wall_seconds_in_tool ?? null),
    }
    if ((withName && (typeof out.tool_name !== 'string' || !out.tool_name)) || !TOOL_CLASSES.has(out.tool_class)
        || out.calls === null || out.result_bytes === null || out.result_tokens_est === null
        || out.wall_seconds_in_tool === undefined) return null
    return out
  }
  const tools = usage.tools.map(row => usageRow(row, true))
  const classes = usage.classes.map(row => usageRow(row, false))
  if (tools.includes(null) || classes.includes(null)) return shape()
  const largest = usage.largest.map((row, index) => (
    row?.rank === index + 1 && index < 5 && typeof row.tool_name === 'string' && row.tool_name
      && TOOL_CLASSES.has(row.tool_class) && typeof row.command_or_input_head === 'string'
      && countOrNull(row.tokens_est) !== null
      ? {rank: row.rank, tool_name: row.tool_name, tool_class: row.tool_class,
        command_or_input_head: row.command_or_input_head, tokens_est: row.tokens_est}
      : null))
  const timeline = usage.timeline.map((row, index) => (
    row?.turn_index === index + 1 && (row.ts === null || typeof row.ts === 'string')
      && (row.tool_name === null || typeof row.tool_name === 'string')
      && (row.tool_class === null || TOOL_CLASSES.has(row.tool_class))
      && countOrNull(row.tool_result_tokens_est) !== null
      ? {turn_index: row.turn_index, ts: row.ts, context_tokens: countOrNull(row.context_tokens),
        output_tokens: countOrNull(row.output_tokens), tool_name: row.tool_name,
        tool_class: row.tool_class, tool_result_tokens_est: row.tool_result_tokens_est}
      : null))
  if (largest.includes(null) || timeline.includes(null) || timeline.length !== summary.turns) return shape()
  return {status: 'present', detail: `${TOOL_USAGE_SCHEMA} durable snapshot`, summary, tools, classes, largest, timeline}
}

function collectToolUsage(tasks, options, issues) {
  const byTask = new Map()
  for (const task of tasks) {
    byTask.set(task.taskId, readTaskToolUsage(options.dataDir, task.taskId, canonicalTimestamp(task.raw?.started_at), issues))
  }
  return byTask
}

// --- source 3: git ---------------------------------------------------------

const SOURCE_EXTENSIONS = new Set([
  'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'py', 'rb', 'go', 'rs', 'java', 'kt',
  'kts', 'swift', 'c', 'h', 'cc', 'cpp', 'hpp', 'cs', 'php', 'sh', 'bash',
  'sql', 'scala', 'ex', 'exs', 'lua', 'pl', 'vue', 'svelte',
])
const NON_PRODUCTION_SEGMENTS = new Set([
  'test', 'tests', '__tests__', 'spec', 'specs', 'e2e', 'fixture', 'fixtures',
  'testdata', 'mock', 'mocks', 'docs', 'doc', 'examples', 'example', 'vendor',
  'node_modules', 'third_party', 'scripts',
])
const AREA_GROUP_ROOTS = new Set(['packages', 'apps', 'services', 'libs', 'crates', 'modules', 'plugins'])

const extensionOf = file => {
  const base = path.posix.basename(file)
  const dot = base.lastIndexOf('.')
  return dot <= 0 ? '' : base.slice(dot + 1).toLowerCase()
}

function isProductionSource(file) {
  const extension = extensionOf(file)
  if (!SOURCE_EXTENSIONS.has(extension)) return false
  const segments = file.split('/')
  const base = segments[segments.length - 1]
  if (/\.(test|spec)\.[^.]+$/.test(base)) return false
  if (/\.test\.[^.]+$/.test(base)) return false
  return !segments.slice(0, -1).some(segment => NON_PRODUCTION_SEGMENTS.has(segment.toLowerCase()))
}

function areaOf(file) {
  const segments = file.split('/')
  if (segments.length === 1) return '<root>'
  if (AREA_GROUP_ROOTS.has(segments[0]) && segments.length > 2) return `${segments[0]}/${segments[1]}`
  return segments[0]
}

const IMPORT_PATTERNS = [
  /\bfrom\s+['"]([^'"]+)['"]/g,
  /\bimport\s+['"]([^'"]+)['"]/g,
  /\brequire\(\s*['"]([^'"]+)['"]\s*\)/g,
  /\bimport\(\s*['"]([^'"]+)['"]\s*\)/g,
]
const PYTHON_IMPORT_PATTERNS = [
  /^\s*from\s+([.\w]+)\s+import\b/gm,
  /^\s*import\s+([.\w]+)/gm,
]
const SHELL_SOURCE_PATTERN = /(?:^|[;&|(]|\s)(?:source|\.)\s+["']?\$?\{?[^"'\s;&|)]*?([A-Za-z0-9._-]+\.(?:sh|bash))["']?/gm

function resolveRelativeImport(files, fromFile, spec) {
  const base = path.posix.normalize(path.posix.join(path.posix.dirname(fromFile), spec))
  const candidates = [base]
  for (const extension of ['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'py', 'vue', 'svelte']) {
    candidates.push(`${base}.${extension}`)
    candidates.push(`${base}/index.${extension}`)
    candidates.push(`${base}/__init__.${extension}`)
  }
  // A TypeScript source may be imported through its emitted .js specifier.
  const jsMatch = /^(.*)\.(js|jsx|mjs|cjs)$/.exec(base)
  if (jsMatch) {
    for (const extension of ['ts', 'tsx']) candidates.push(`${jsMatch[1]}.${extension}`)
  }
  return candidates.find(candidate => files.has(candidate)) || null
}

function resolvePythonImport(files, spec) {
  if (spec.startsWith('.')) return null
  const asPath = spec.replace(/\./g, '/')
  return [`${asPath}.py`, `${asPath}/__init__.py`].find(candidate => files.has(candidate)) || null
}

// The graph reflects the project's current checkout, and only the languages
// listed above. A project with no parseable source is reported unsupported so
// its tasks keep NULL degrees instead of an invented zero, and a path a task
// once touched that no longer exists at the current checkout has no degree at
// all rather than a degree of zero.
function buildImportGraph(repo) {
  const listed = git(repo, ['ls-files', '-z'])
  if (listed === null) return null
  const files = new Set(listed.split('\0').filter(Boolean))
  const shellByBasename = new Map()
  for (const file of files) {
    if (!/\.(sh|bash)$/.test(file)) continue
    const base = path.posix.basename(file)
    if (!shellByBasename.has(base)) shellByBasename.set(base, [])
    shellByBasename.get(base).push(file)
  }
  const out = new Map()
  const into = new Map()
  let parsed = 0
  for (const file of sortedBy([...files], f => f)) {
    const extension = extensionOf(file)
    if (!SOURCE_EXTENSIONS.has(extension)) continue
    let text
    try {
      const absolute = path.join(repo, file)
      if (fs.statSync(absolute).size > MAX_IMPORT_FILE_BYTES) continue
      text = fs.readFileSync(absolute, 'utf8')
    } catch {
      continue
    }
    const targets = new Set()
    if (['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'vue', 'svelte'].includes(extension)) {
      parsed += 1
      for (const pattern of IMPORT_PATTERNS) {
        pattern.lastIndex = 0
        let match
        while ((match = pattern.exec(text)) !== null) {
          const spec = match[1]
          if (!spec.startsWith('.')) continue
          const resolved = resolveRelativeImport(files, file, spec)
          if (resolved && resolved !== file) targets.add(resolved)
        }
      }
    } else if (extension === 'py') {
      parsed += 1
      for (const pattern of PYTHON_IMPORT_PATTERNS) {
        pattern.lastIndex = 0
        let match
        while ((match = pattern.exec(text)) !== null) {
          const resolved = resolvePythonImport(files, match[1])
          if (resolved && resolved !== file) targets.add(resolved)
        }
      }
    } else if (extension === 'sh' || extension === 'bash') {
      parsed += 1
      SHELL_SOURCE_PATTERN.lastIndex = 0
      let match
      while ((match = SHELL_SOURCE_PATTERN.exec(text)) !== null) {
        // A sourced path is usually built from a variable, so resolve by
        // basename and only when it names exactly one file in the repo.
        const candidates = shellByBasename.get(match[1]) || []
        if (candidates.length === 1 && candidates[0] !== file) targets.add(candidates[0])
      }
    } else {
      continue
    }
    out.set(file, targets)
    for (const target of targets) {
      if (!into.has(target)) into.set(target, new Set())
      into.get(target).add(file)
    }
  }
  if (parsed === 0) return {supported: false, files, out, into}
  return {supported: true, files, out, into}
}

function defaultBranchTip(repo) {
  const symbolic = git(repo, ['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD'])
  const candidates = []
  if (symbolic) candidates.push(symbolic.trim())
  candidates.push('refs/remotes/origin/main', 'refs/remotes/origin/master', 'refs/heads/main', 'refs/heads/master')
  for (const candidate of candidates) {
    const resolved = git(repo, ['rev-parse', '--verify', '--quiet', `${candidate}^{commit}`])
    if (resolved && resolved.trim()) return {sha: resolved.trim()}
  }
  return null
}

function loadCommitLog(repo) {
  const raw = git(repo, ['log', '--all', '--format=%H%x1f%cI%x1f%s%x1f%B%x1e'])
  if (raw === null) return null
  const commits = new Map()
  for (const chunk of raw.split('\x1e')) {
    const trimmed = chunk.replace(/^\n+/, '')
    if (trimmed === '') continue
    const [sha, committedAt, subject, body] = trimmed.split('\x1f')
    if (!sha) continue
    commits.set(sha, {sha, committed_at: committedAt || null, subject: subject || '', body: body || ''})
  }
  return commits
}

function containsDelimitedIdentifier(text, identifier) {
  const escaped = identifier.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`(^|[^A-Za-z0-9-])${escaped}($|[^A-Za-z0-9-])`).test(text)
}

// Commit resolution is tiered and every link records which tier produced it,
// because a link found by convention is weaker evidence than one recorded at
// the time and the store should never blur the two.
function resolveTaskCommits(repo, taskId, annotation, commits, defaultTip) {
  const declared = Array.isArray(annotation?.commits) ? annotation.commits : []
  const links = new Map()
  const add = (sha, provenance) => {
    if (!commits.has(sha)) return
    if (!links.has(sha)) links.set(sha, provenance)
  }
  for (const sha of declared) {
    const resolved = git(repo, ['rev-parse', '--verify', '--quiet', `${sha}^{commit}`])
    if (resolved) add(resolved.trim(), 'declared')
  }

  const prNumber = typeof annotation?.pr_url === 'string' ? /\/(?:pull|merge_requests)\/(\d+)/.exec(annotation.pr_url)?.[1] : null
  if (prNumber) {
    for (const commit of commits.values()) {
      if (commit.subject.includes(`(#${prNumber})`) || /^Merge pull request #(\d+)/.exec(commit.subject)?.[1] === prNumber) {
        add(commit.sha, 'pr-number')
      }
    }
  }

  const branch = typeof annotation?.branch === 'string' && annotation.branch ? annotation.branch : `fm/${taskId}`
  const refs = git(repo, ['for-each-ref', '--format=%(refname)'])
  if (refs) {
    for (const ref of refs.split('\n').map(line => line.trim()).filter(Boolean)) {
      if (ref !== branch && !ref.endsWith(`/${branch}`)) continue
      const args = ['rev-list', ref]
      if (defaultTip) args.push(`^${defaultTip.sha}`)
      const list = git(repo, args)
      if (!list) continue
      for (const sha of list.split('\n').filter(Boolean)) add(sha, 'branch-ref')
    }
  }

  for (const commit of commits.values()) {
    const haystack = `${commit.subject}\n${commit.body}`
    if (containsDelimitedIdentifier(haystack, branch) || containsDelimitedIdentifier(haystack, taskId)) {
      add(commit.sha, 'commit-message')
    }
  }

  return links
}

// `--numstat` without `-z` compresses a rename into `src/{ => engine}/Foo.ts`,
// which is not a path. The NUL form keeps the real names: a rename emits an
// empty path field followed by the old and new names as separate records.
function commitFileStats(repo, sha) {
  const raw = git(repo, ['show', '--format=', '--numstat', '-z', '-M', sha])
  if (raw === null) return []
  const tokens = raw.split('\0')
  const files = []
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i]
    if (token === '') continue
    const parts = token.split('\t')
    if (parts.length < 3) continue
    const [addsText, delsText, inlinePath] = parts
    let file = inlinePath
    if (file === '') {
      file = tokens[i + 2] ?? ''
      i += 2
    }
    if (file === '') continue
    files.push({
      path: file,
      adds: addsText === '-' ? null : Number(addsText),
      dels: delsText === '-' ? null : Number(delsText),
    })
  }
  return files
}

function commitFileStatuses(repo, sha) {
  const raw = git(repo, ['show', '--format=', '--name-status', '-z', '-M', sha])
  const statuses = new Map()
  if (raw === null) return statuses
  const tokens = raw.split('\0').filter(token => token !== '')
  for (let i = 0; i < tokens.length; i += 1) {
    const code = tokens[i][0]
    if (!/^[A-Z]$/.test(code)) continue
    if (code === 'R' || code === 'C') {
      // status, old path, new path
      if (tokens[i + 2] !== undefined) statuses.set(tokens[i + 2], code)
      i += 2
      continue
    }
    if (tokens[i + 1] !== undefined) statuses.set(tokens[i + 1], code)
    i += 1
  }
  return statuses
}

// --- the store --------------------------------------------------------------

const SCHEMA = `
CREATE TABLE store_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- One row per task. Every derived column is nullable on purpose: NULL means the
-- source that would have filled it was not available, and 0 means the source was
-- available and the real answer is zero.
CREATE TABLE task (
  task_id             TEXT PRIMARY KEY,
  title               TEXT,
  repo                TEXT,
  project_path        TEXT,
  kind                TEXT,
  branch              TEXT,
  pr_url              TEXT,
  harness             TEXT,
  model               TEXT,
  effort              TEXT,
  backend             TEXT,
  worktree            TEXT,
  dispatched_at       TEXT,
  started_at          TEXT,
  ended_at            TEXT,
  wall_clock_seconds  INTEGER,
  agent_active_seconds INTEGER,
  first_commit_at     TEXT,
  pr_opened_at        TEXT,
  launch_to_pr_seconds INTEGER,
  merged_at           TEXT,
  local_landed_at     TEXT,
  teardown_at         TEXT,
  files_changed       INTEGER,
  prod_src_files      INTEGER,
  distinct_areas      INTEGER,
  adds                INTEGER,
  dels                INTEGER,
  import_in_degree    INTEGER,
  import_out_degree   INTEGER,
  findings            INTEGER,
  review_rounds       INTEGER,
  ask_user_count      INTEGER,
  gate_failures       INTEGER,
  failure_mode        TEXT CHECK (failure_mode IN ('loudly', 'quietly')),
  tokens_in           INTEGER,
  tokens_out          INTEGER,
  tokens_reasoning    INTEGER,
  tokens_cached_read  INTEGER,
  tokens_cached_write INTEGER,
  notional_cost_usd   REAL,
  api_calls           INTEGER,
  sessions            INTEGER,
  outcome             TEXT,
  reverted            INTEGER CHECK (reverted IN (0, 1)),
  -- The context signal captured from the task's own session records at
  -- lifecycle capture: the largest prompt any request carried, the number of
  -- context compactions, and the relaunches beyond the first launch. NULL for
  -- a task captured before the signal existed or with no bound record.
  peak_context_tokens INTEGER,
  compactions         INTEGER,
  restarts            INTEGER,
  -- Where the tokens went, from the tool-usage snapshot captured beside the
  -- context signal: model requests, tool calls, the estimated tokens their
  -- results put into the context, the model's own output, and the first
  -- request's prompt size as the fixed-base estimate. *_est columns are
  -- ceil(bytes / 4) estimates. NULL when no snapshot was captured.
  turns                  INTEGER,
  tool_calls             INTEGER,
  tool_result_tokens_est INTEGER,
  assistant_output_tokens INTEGER,
  base_prompt_tokens_est INTEGER,
  -- The **N moved** figure the PR body claims, from the CI ledger's recorded
  -- body. NULL without a ledger or without the figure.
  cards_moved_claimed    INTEGER
);

-- The forge's run ledger for the task's PR, derived from the fm-pr-ci.v1
-- record at rebuild. landing is direct, closed, or train:<pr number>; a train
-- PR carries its manifest shape. Seconds are exact sums of forge timestamps.
CREATE TABLE task_ci (
  task_id               TEXT PRIMARY KEY,
  pr_url                TEXT NOT NULL,
  pr_number             INTEGER NOT NULL,
  repository            TEXT NOT NULL,
  head_ref              TEXT NOT NULL,
  pr_state              TEXT NOT NULL,
  pr_created_at         TEXT,
  pr_closed_at          TEXT,
  pr_merged_at          TEXT,
  landing               TEXT NOT NULL,
  train_pr_number       INTEGER,
  is_train              INTEGER NOT NULL CHECK (is_train IN (0, 1)),
  member_count          INTEGER,
  ejected_count         INTEGER,
  fix_round_count       INTEGER,
  runs                  INTEGER NOT NULL,
  runs_cancelled        INTEGER NOT NULL,
  runs_failed           INTEGER NOT NULL,
  runs_succeeded        INTEGER NOT NULL,
  runner_seconds        INTEGER NOT NULL,
  queue_seconds         INTEGER NOT NULL,
  first_run_created_at  TEXT,
  last_run_completed_at TEXT,
  captured_from         TEXT NOT NULL CHECK (captured_from IN ('manual', 'merge', 'backfill', 'train-manifest')),
  captured_at           TEXT NOT NULL
);

-- One row per recorded workflow run. queue_seconds is NULL when no job of the
-- run ever started; completed_at is the last job completion, or the run's
-- final update when it completed without a timed job.
CREATE TABLE task_ci_run (
  task_id        TEXT NOT NULL,
  run_id         INTEGER NOT NULL,
  name           TEXT,
  event          TEXT,
  status         TEXT,
  conclusion     TEXT,
  run_attempt    INTEGER,
  created_at     TEXT,
  completed_at   TEXT,
  jobs           INTEGER NOT NULL,
  runner_seconds INTEGER NOT NULL,
  queue_seconds  INTEGER,
  PRIMARY KEY (task_id, run_id)
);

-- One row per (tool, class) a task called. wall_seconds_in_tool is the summed
-- gap between each call and its result, NULL when any call of the row was not
-- timed.
CREATE TABLE task_tool_usage (
  task_id              TEXT NOT NULL,
  tool_name            TEXT NOT NULL,
  tool_class           TEXT NOT NULL CHECK (tool_class IN (${TOOL_CLASS_LIST})),
  calls                INTEGER NOT NULL,
  result_bytes         INTEGER NOT NULL,
  result_tokens_est    INTEGER NOT NULL,
  wall_seconds_in_tool REAL,
  PRIMARY KEY (task_id, tool_name, tool_class)
);

-- The same calls rolled up by class.
CREATE TABLE task_tool_class (
  task_id              TEXT NOT NULL,
  tool_class           TEXT NOT NULL CHECK (tool_class IN (${TOOL_CLASS_LIST})),
  calls                INTEGER NOT NULL,
  result_bytes         INTEGER NOT NULL,
  result_tokens_est    INTEGER NOT NULL,
  wall_seconds_in_tool REAL,
  PRIMARY KEY (task_id, tool_class)
);

-- The five results that put the most into the context, with the first 120
-- characters of what the call ran.
CREATE TABLE task_largest_results (
  task_id               TEXT NOT NULL,
  rank                  INTEGER NOT NULL CHECK (rank BETWEEN 1 AND 5),
  tool_name             TEXT NOT NULL,
  tool_class            TEXT NOT NULL,
  command_or_input_head TEXT NOT NULL,
  tokens_est            INTEGER NOT NULL,
  PRIMARY KEY (task_id, rank)
);

-- One row per model request so context growth is queryable turn by turn:
-- the prompt size that request carried, its output, the first tool it called,
-- and the estimated tokens every result of that turn put into the next prompt.
CREATE TABLE task_turn_timeline (
  task_id                TEXT NOT NULL,
  turn_index             INTEGER NOT NULL,
  ts                     TEXT,
  context_tokens         INTEGER,
  output_tokens          INTEGER,
  tool_name              TEXT,
  tool_class             TEXT,
  tool_result_tokens_est INTEGER NOT NULL,
  PRIMARY KEY (task_id, turn_index)
);

-- Which sources were consulted for each task and what came back. A task absent
-- from a source is recorded here, never dropped from the store.
CREATE TABLE task_source (
  task_id TEXT NOT NULL,
  source  TEXT NOT NULL CHECK (source IN ('raw', 'codeburn', 'tool-usage', 'ci', 'git', 'annotation')),
  status  TEXT NOT NULL CHECK (status IN ('present', 'missing')),
  detail  TEXT,
  PRIMARY KEY (task_id, source)
);

-- Recorded as given. Discovery means the work revealed more; churn means the
-- requirements moved. Nothing infers these.
CREATE TABLE round_reason (
  task_id     TEXT NOT NULL,
  round_index INTEGER NOT NULL,
  reason      TEXT NOT NULL CHECK (reason IN ('discovery', 'churn')),
  note        TEXT,
  PRIMARY KEY (task_id, round_index)
);

CREATE TABLE task_commit (
  task_id         TEXT NOT NULL,
  sha             TEXT NOT NULL,
  committed_at    TEXT,
  link_provenance TEXT NOT NULL,
  PRIMARY KEY (task_id, sha)
);

CREATE TABLE task_file (
  task_id           TEXT NOT NULL,
  path              TEXT NOT NULL,
  adds              INTEGER,
  dels              INTEGER,
  is_prod_src       INTEGER NOT NULL,
  area              TEXT NOT NULL,
  introduced        INTEGER NOT NULL,
  import_in_degree  INTEGER,
  import_out_degree INTEGER,
  PRIMARY KEY (task_id, path)
);

CREATE TABLE task_model (
  task_id             TEXT NOT NULL,
  provider            TEXT NOT NULL,
  model               TEXT NOT NULL,
  tokens_in           INTEGER,
  tokens_out          INTEGER,
  tokens_reasoning    INTEGER,
  tokens_cached_read  INTEGER,
  tokens_cached_write INTEGER,
  notional_cost_usd   REAL,
  api_calls           INTEGER,
  PRIMARY KEY (task_id, provider, model)
);

-- Did the work hold? One row per later task that modified code an earlier task
-- introduced. introduced_path is the name the earlier task knew; modified_path is
-- the name at the later change, so a rename is visible rather than fatal.
CREATE TABLE durability (
  introducing_task_id TEXT NOT NULL,
  modifying_task_id   TEXT NOT NULL,
  introduced_path     TEXT NOT NULL,
  modified_path       TEXT NOT NULL,
  introducing_sha     TEXT NOT NULL,
  modifying_sha       TEXT NOT NULL,
  modified_at         TEXT,
  PRIMARY KEY (introducing_task_id, modifying_task_id, introduced_path, modifying_sha)
);

CREATE TABLE ingest_issue (
  source  TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  task_id TEXT,
  kind    TEXT NOT NULL,
  detail  TEXT NOT NULL,
  PRIMARY KEY (source, ordinal)
);
`

function createDatabase(dbPath) {
  fs.mkdirSync(path.dirname(dbPath), {recursive: true})
  fs.rmSync(dbPath, {force: true})
  fs.rmSync(`${dbPath}-wal`, {force: true})
  fs.rmSync(`${dbPath}-shm`, {force: true})
  const db = new DatabaseSync(dbPath)
  db.exec(SCHEMA)
  return db
}

const insert = (db, table, columns) =>
  db.prepare(`INSERT INTO ${table} (${columns.join(', ')}) VALUES (${columns.map(() => '?').join(', ')})`)

const bind = value => {
  if (value === undefined || value === null) return null
  if (typeof value === 'boolean') return value ? 1 : 0
  return value
}

const capturedCount = value => {
  if (typeof value === 'number') return Number.isSafeInteger(value) && value >= 0 ? value : null
  if (typeof value !== 'string' || !/^(0|[1-9]\d*)$/.test(value)) return null
  const count = Number(value)
  return Number.isSafeInteger(count) ? count : null
}

// --- rebuild ----------------------------------------------------------------

function isoSecondsBetween(from, to) {
  const a = Date.parse(from)
  const b = Date.parse(to)
  if (!Number.isFinite(a) || !Number.isFinite(b) || b < a) return null
  return Math.round((b - a) / 1000)
}

function canonicalTimestamp(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value || '')) return null
  const milliseconds = Date.parse(value)
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString().replace('.000Z', 'Z') !== value) return null
  return value
}

function validatedLifecycleTimestamp(value, startedAt) {
  if (!canonicalTimestamp(startedAt) || !canonicalTimestamp(value)) return null
  return isoSecondsBetween(startedAt, value) === null ? null : value
}

function rebuild(options) {
  gitCacheRoot = path.join(options.stateDir, 'effort-git-cache')
  if (options.fullRebuild) fs.rmSync(gitCacheRoot, {recursive: true, force: true})
  const issues = []
  const raw = readRawCapture(options.rawFile, issues)
  const annotations = readAnnotations(options.annotationsFile, issues)

  // A task can enter the store from the raw layer, a durable usage snapshot, or
  // an annotation alone, so partial lifecycle records remain visible with each
  // absent source recorded missing.
  const taskIds = new Set([
    ...raw.rows.map(row => row.task),
    ...annotations.byTask.keys(),
    ...discoverUsageTaskIds(options.dataDir),
    ...discoverCiTaskIds(options.dataDir),
  ])
  const rawByTask = new Map()
  for (const row of raw.rows) {
    const existing = rawByTask.get(row.task)
    // Repeated ids can only come from a reused id; the latest window wins and
    // the superseded one is surfaced rather than silently discarded. An exact
    // retry is intentionally invisible so an interrupted teardown can replay
    // capture without changing the logical store.
    if (existing && existing.started_at !== row.started_at) {
      issues.push({source: 'raw', task_id: row.task, kind: 'duplicate-task-row', detail: `${existing.started_at || ''}..${existing.ended_at || ''}`})
    }
    rawByTask.set(row.task, row)
  }

  const tasks = sortedBy([...taskIds], id => id).map(taskId => ({
    taskId,
    raw: rawByTask.get(taskId) || null,
    annotation: annotations.byTask.get(taskId) || null,
  }))

  const usage = collectUsage(tasks, options, issues)
  const toolUsage = collectToolUsage(tasks, options, issues)
  const gitResults = collectGit(tasks, options, issues)

  const temporaryDb = `${options.dbPath}.${process.pid}.tmp`
  const db = createDatabase(temporaryDb)
  db.exec('BEGIN')
  try {
    const metaInsert = insert(db, 'store_meta', ['key', 'value'])
    for (const [key, value] of [
      ['schema_version', SCHEMA_VERSION],
      ['classifier_version', CLASSIFIER_VERSION],
      ['raw_digest', raw.digest],
    ]) metaInsert.run(key, value)

    writeTasks(db, tasks, usage, toolUsage, gitResults, options, issues)
    writeDurability(db, gitResults)
    writeIssues(db, issues)
    db.exec('COMMIT')
  } catch (error) {
    db.exec('ROLLBACK')
    db.close()
    throw error
  }
  db.close()
  fs.renameSync(temporaryDb, options.dbPath)

  return {tasks: tasks.length, issues: issues.length}
}

function collectGit(tasks, options, issues) {
  const byProject = new Map()
  for (const task of tasks) {
    const project = task.raw?.project || task.annotation?.project || null
    if (!project) continue
    if (!byProject.has(project)) byProject.set(project, [])
    byProject.get(project).push(task)
  }

  const results = new Map()
  const durability = []
  for (const project of sortedBy([...byProject.keys()], p => p)) {
    const projectTasks = byProject.get(project)
    const inside = git(project, ['rev-parse', '--is-inside-work-tree'])
    if (inside === null || inside.trim() !== 'true') {
      const detail = 'project clone is unavailable'
      issues.push({source: 'git', task_id: null, kind: 'project-unavailable', detail: `${project}: ${detail}`})
      for (const task of projectTasks) results.set(task.taskId, {status: 'missing', detail})
      continue
    }
    const commits = loadCommitLog(project)
    if (commits === null) {
      const detail = 'project history could not be read'
      for (const task of projectTasks) results.set(task.taskId, {status: 'missing', detail})
      continue
    }
    const defaultTip = defaultBranchTip(project)
    const graph = options.importGraph === false ? null : buildImportGraph(project)

    const perTask = new Map()
    for (const task of projectTasks) {
      const links = resolveTaskCommits(project, task.taskId, task.annotation, commits, defaultTip)
      if (links.size === 0) {
        results.set(task.taskId, {status: 'missing', detail: 'no commits resolved for this task'})
        continue
      }
      perTask.set(task.taskId, summarizeTaskGit(project, task, links, commits, defaultTip, graph))
      results.set(task.taskId, perTask.get(task.taskId))
    }
    durability.push(...computeDurability(project, perTask))
  }

  for (const task of tasks) {
    if (results.has(task.taskId)) continue
    results.set(task.taskId, {status: 'missing', detail: 'no project recorded for this task'})
  }
  return {results, durability}
}

function summarizeTaskGit(repo, task, links, commits, defaultTip, graph) {
  const shas = sortedBy([...links.keys()], sha => sha)
  const files = new Map()
  let firstCommitAt = null
  let mergedAt = null
  for (const sha of shas) {
    const commit = commits.get(sha)
    if (commit?.committed_at) {
      if (firstCommitAt === null || commit.committed_at < firstCommitAt) firstCommitAt = commit.committed_at
    }
    const statuses = commitFileStatuses(repo, sha)
    for (const stat of commitFileStats(repo, sha)) {
      const existing = files.get(stat.path) || {path: stat.path, adds: 0, dels: 0, introduced: false, shas: []}
      existing.adds = stat.adds === null || existing.adds === null ? null : existing.adds + stat.adds
      existing.dels = stat.dels === null || existing.dels === null ? null : existing.dels + stat.dels
      if (statuses.get(stat.path) === 'A') existing.introduced = true
      existing.shas.push(sha)
      files.set(stat.path, existing)
    }
  }

  let landed = false
  if (defaultTip) {
    for (const sha of shas) {
      const merged = git(repo, ['merge-base', '--is-ancestor', sha, defaultTip.sha])
      // merge-base --is-ancestor communicates through its exit status, so a
      // non-null return is the "yes" answer.
      if (merged !== null) {
        landed = true
        const commit = commits.get(sha)
        if (commit?.committed_at && (mergedAt === null || commit.committed_at > mergedAt)) mergedAt = commit.committed_at
      }
    }
  }

  const subjects = new Set(shas.map(sha => commits.get(sha)?.subject).filter(Boolean))
  let reverted = 0
  for (const commit of commits.values()) {
    if (!commit.subject.startsWith('Revert "')) continue
    if ([...subjects].some(subject => commit.subject.includes(subject) || commit.body.includes(subject))) reverted = 1
  }

  const fileList = sortedBy([...files.values()], file => file.path)
  const taskPaths = new Set(fileList.map(file => file.path))
  // Degrees are only meaningful for paths the current checkout still has: a
  // path that was later renamed or deleted has no position in today's graph,
  // and reporting that as zero reach would be a measurement it never made.
  const graphed = graph && graph.supported ? fileList.filter(file => graph.files.has(file.path)) : []
  let importIn = null
  let importOut = null
  if (graphed.length > 0) {
    const outward = new Set()
    const inward = new Set()
    for (const file of graphed) {
      for (const target of graph.out.get(file.path) || []) {
        if (!taskPaths.has(target)) outward.add(target)
      }
      for (const importer of graph.into.get(file.path) || []) {
        if (!taskPaths.has(importer)) inward.add(importer)
      }
    }
    importOut = outward.size
    importIn = inward.size
  }

  return {
    status: 'present',
    detail: `${shas.length} commit${shas.length === 1 ? '' : 's'} linked by ${[...new Set(shas.map(sha => links.get(sha)))].sort().join(', ')}`,
    links,
    commits: shas.map(sha => ({sha, committed_at: commits.get(sha)?.committed_at || null, provenance: links.get(sha)})),
    files: fileList.map(file => ({
      path: file.path,
      shas: sortedBy(file.shas, sha => commits.get(sha)?.committed_at || ''),
      adds: file.adds,
      dels: file.dels,
      is_prod_src: isProductionSource(file.path) ? 1 : 0,
      area: areaOf(file.path),
      introduced: file.introduced ? 1 : 0,
      import_in_degree: graph?.supported && graph.files.has(file.path) ? (graph.into.get(file.path)?.size ?? 0) : null,
      import_out_degree: graph?.supported && graph.files.has(file.path) ? (graph.out.get(file.path)?.size ?? 0) : null,
    })),
    structure: {
      files_changed: fileList.length,
      prod_src_files: fileList.filter(file => isProductionSource(file.path)).length,
      distinct_areas: new Set(fileList.map(file => areaOf(file.path))).size,
      adds: fileList.some(file => file.adds === null) ? null : fileList.reduce((sum, file) => sum + file.adds, 0),
      dels: fileList.some(file => file.dels === null) ? null : fileList.reduce((sum, file) => sum + file.dels, 0),
      import_in_degree: importIn,
      import_out_degree: importOut,
    },
    first_commit_at: firstCommitAt,
    merged_at: mergedAt,
    outcome: landed ? 'merged' : null,
    reverted,
    repo,
  }
}

// The durability relation, walked from the later change backwards.
//
// `git log --follow` is anchored at the commit where the later task's path
// certainly existed, so it maps that path back through every rename to the name
// an earlier task knew. Walking this direction is what survives a rename: the
// earlier task's path may not exist at HEAD at all.
function computeDurability(repo, perTask) {
  const commitOwner = new Map()
  for (const [taskId, summary] of perTask) {
    for (const commit of summary.commits) {
      if (!commitOwner.has(commit.sha)) commitOwner.set(commit.sha, taskId)
    }
  }
  const rows = []
  const seen = new Set()
  for (const taskId of sortedBy([...perTask.keys()], id => id)) {
    const summary = perTask.get(taskId)
    for (const file of summary.files) {
      // Anchor on the newest of this task's own commits that touched the path,
      // so the path certainly exists at the walk's starting point.
      const anchor = file.shas.at(-1)
      if (!anchor) continue
      const raw = git(repo, ['log', '--follow', '--format=%x1e%H%x1f%cI', '--name-status', '-M', anchor, '--', file.path])
      if (raw === null) continue
      let walkSha = null
      let walkAt = null
      // The newest commit in this walk that this task owns, plus the name the
      // path carried there: that pair is what "this task modified it" means.
      let ownSha = null
      let ownPath = null
      let ownAt = null
      for (const line of raw.split('\n')) {
        if (line === '') continue
        if (line.startsWith(RECORD_SEPARATOR)) {
          const [sha, at] = line.slice(1).split(FIELD_SEPARATOR)
          walkSha = sha
          walkAt = at || null
          continue
        }
        if (walkSha === null) continue
        const parts = line.split('\t')
        const status = parts[0]?.[0]
        // `--name-status` keeps both rename sides as separate fields, and the
        // last one is always the name that commit produced, which is the name
        // that commit's own task recorded.
        const pathAtCommit = parts[parts.length - 1]
        if (!status || !pathAtCommit) continue
        const owner = commitOwner.get(walkSha)
        if (owner === taskId) {
          if (ownSha === null) {
            ownSha = walkSha
            ownPath = pathAtCommit
            ownAt = walkAt
          }
          continue
        }
        if (!owner || ownSha === null) continue
        const ownerFile = perTask.get(owner)?.files.find(entry => entry.path === pathAtCommit)
        if (!ownerFile || ownerFile.introduced !== 1) continue
        const key = `${owner} ${taskId} ${pathAtCommit} ${ownSha}`
        if (seen.has(key)) continue
        seen.add(key)
        rows.push({
          introducing_task_id: owner,
          modifying_task_id: taskId,
          introduced_path: pathAtCommit,
          modified_path: ownPath,
          introducing_sha: walkSha,
          modifying_sha: ownSha,
          modified_at: ownAt,
        })
      }
    }
  }
  return rows
}

function readMergeReceipt(dataDir, taskId, spawnedAt) {
  if (!TASK_ID_PATTERN.test(taskId)) return null
  const file = path.join(dataDir, 'pr-merges', `${taskId}.receipt`)
  const commonFields = ['schema', 'task_id', 'pr', 'spawned_at', 'phase', 'authorization', 'prepared_epoch']
  const first = readMetaWithRequiredFields(file, commonFields)
  const timestampField = ['fm-pr-merge.v2', 'fm-pr-merge.v3', 'fm-pr-merge.v4'].includes(first?.schema) ? 'merged_at' : 'merged_epoch'
  const extraFields = first?.schema === 'fm-pr-merge.v4'
    ? ['repository', 'project', 'default_branch', 'merge_commit']
    : first?.schema === 'fm-pr-merge.v3' ? ['repository', 'default_branch', 'merge_commit'] : []
  const receipt = first && readMetaWithRequiredFields(file, [...commonFields, timestampField, ...extraFields])
  if (!receipt || !['fm-pr-merge.v1', 'fm-pr-merge.v2', 'fm-pr-merge.v3', 'fm-pr-merge.v4'].includes(receipt.schema) || receipt.task_id !== taskId
      || (['fm-pr-merge.v2', 'fm-pr-merge.v3', 'fm-pr-merge.v4'].includes(receipt.schema) && receipt.merged_epoch !== undefined)
      || (receipt.schema === 'fm-pr-merge.v1' && receipt.merged_at !== undefined)
      || (['fm-pr-merge.v3', 'fm-pr-merge.v4'].includes(receipt.schema)
        && (!/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(receipt.repository || '')
          || !/^(?!\.)(?!.*\.\.)(?!.*\/$)[A-Za-z0-9._\/-]+$/.test(receipt.default_branch || '')
          || !/^[0-9a-f]{40}$/.test(receipt.merge_commit || '')))
      || (receipt.schema === 'fm-pr-merge.v4' && !receipt.project)
      || !/^https:\/\/github\.com\/(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])\/[A-Za-z0-9._-]{1,100}\/pull\/[1-9]\d*$/.test(receipt.pr || '')
      || receipt.spawned_at !== spawnedAt || receipt.phase !== 'merged'
      || !['live-meta', 'done-history'].includes(receipt.authorization)) return null
  const epochTimestamp = (value, earliest) => {
    if (!/^(0|[1-9]\d*)$/.test(value || '')) return null
    const epoch = Number(value)
    const milliseconds = epoch * 1000
    if (!Number.isSafeInteger(epoch) || milliseconds > 8640000000000000) return null
    const date = new Date(milliseconds)
    if (!Number.isFinite(date.getTime())) return null
    return validatedLifecycleTimestamp(date.toISOString().replace('.000Z', 'Z'), earliest)
  }
  const preparedAt = epochTimestamp(receipt.prepared_epoch, spawnedAt)
  if (!preparedAt) return null
  const mergedAt = ['fm-pr-merge.v2', 'fm-pr-merge.v3', 'fm-pr-merge.v4'].includes(receipt.schema)
    ? (receipt.merged_at === '' ? null : validatedLifecycleTimestamp(receipt.merged_at, spawnedAt))
    : epochTimestamp(receipt.merged_epoch, preparedAt)
  if (['fm-pr-merge.v2', 'fm-pr-merge.v3', 'fm-pr-merge.v4'].includes(receipt.schema) && receipt.merged_at !== '' && !mergedAt) return null
  if (receipt.schema === 'fm-pr-merge.v1' && !mergedAt) return null
  return {
    pr_url: receipt.pr || null,
    merged_at: mergedAt,
    merged: true,
  }
}

function readLocalLandingReceipt(dataDir, taskId, spawnedAt) {
  if (!TASK_ID_PATTERN.test(taskId)) return null
  const receipt = readMetaWithRequiredFields(
    path.join(dataDir, 'local-landings', `${taskId}.receipt`),
    ['schema', 'task_id', 'spawned_at', 'project', 'branch', 'default_branch',
      'before_sha', 'landed_sha', 'phase', 'event_at'],
  )
  if (!receipt || receipt.schema !== 'fm-local-landing.v1' || receipt.task_id !== taskId || receipt.spawned_at !== spawnedAt || receipt.phase !== 'landed') return null
  const landedAt = validatedLifecycleTimestamp(receipt.event_at, spawnedAt)
  if (!landedAt) return null
  if (!receipt.project || receipt.branch !== `fm/${taskId}` || !receipt.default_branch) return null
  if (!/^[0-9a-f]{40}$/.test(receipt.before_sha || '') || !/^[0-9a-f]{40}$/.test(receipt.landed_sha || '')) return null
  return {local_landed_at: landedAt, project: receipt.project}
}

// --- CI ledger --------------------------------------------------------------
//
// data/pr-ci/<task>.json is the fm-pr-ci.v1 record capture-ci wrote from the
// forge. Rebuild derives every count and minute from the recorded runs and the
// recorded body, so the arithmetic and the body parse have one owner here.

const CI_LEDGER_SCHEMA = 'fm-pr-ci.v1'
const CI_FAILED_CONCLUSIONS = new Set(['failure', 'timed_out', 'startup_failure'])
const CI_CAPTURE_SOURCES = new Set(['manual', 'merge', 'backfill', 'train-manifest'])
const CI_LANDING_PATTERN = /^(direct|closed|train:[1-9]\d*)$/
const MAX_CI_LEDGER_BYTES = 8 * 1024 * 1024
const GITHUB_PR_URL_PATTERN = /^https:\/\/github\.com\/((?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9]))\/([A-Za-z0-9._-]{1,100})\/pull\/([1-9]\d*)$/

function parseGithubPrUrl(url) {
  const match = GITHUB_PR_URL_PATTERN.exec(url || '')
  return match ? {url, owner: match[1], repo: match[2], number: Number(match[3])} : null
}

// The `**N moved**` claim: the number immediately before `moved**`, so both
// `**23 moved**` and `**Strict floor 25: 23 moved**` read as the claim.
function cardsMovedClaimed(body) {
  const match = /(\d[\d,]*)\s+(?:cards?\s+)?moved\*\*/i.exec(String(body ?? ''))
  if (!match) return null
  const count = Number(match[1].replace(/,/g, ''))
  return Number.isSafeInteger(count) ? count : null
}

// A train is a PR titled `train:` or carrying a `## Manifest` section; its
// members are the manifest's `- #<pr> <branch>` lines, its ejections the same
// shape under `## Ejected`, and its fix rounds the `## Fix round` headings.
function parseTrain(title, body) {
  const lines = String(body ?? '').split(/\r?\n/)
  const sectionLines = name => {
    const start = lines.findIndex(line => new RegExp(`^##\\s+${name}\\b`, 'i').test(line))
    if (start < 0) return []
    const end = lines.findIndex((line, index) => index > start && /^##\s/.test(line))
    return lines.slice(start + 1, end < 0 ? lines.length : end)
  }
  const manifest = sectionLines('Manifest')
  if (!/^\s*train:/i.test(String(title ?? '')) && !lines.some(line => /^##\s+Manifest\b/i.test(line))) return null
  const memberLine = /^-\s+#([1-9]\d*)\s+(\S+)/
  const members = manifest.map(line => memberLine.exec(line)).filter(Boolean)
    .map(match => ({number: Number(match[1]), branch: match[2]}))
  return {
    members,
    member_count: members.length,
    ejected_count: sectionLines('Ejected').filter(line => /^-\s+#[1-9]\d*/.test(line)).length,
    fix_round_count: lines.filter(line => /^##+\s+Fix round\b/i.test(line)).length,
  }
}

function discoverCiTaskIds(dataDir) {
  let names
  try {
    names = fs.readdirSync(path.join(dataDir, 'pr-ci'))
  } catch {
    return []
  }
  return names.filter(name => name.endsWith('.json'))
    .map(name => name.slice(0, -'.json'.length))
    .filter(id => TASK_ID_PATTERN.test(id))
}

function ciLedgerPath(dataDir, taskId) {
  return path.join(dataDir, 'pr-ci', `${taskId}.json`)
}

function readCiLedgerFile(dataDir, taskId) {
  if (!TASK_ID_PATTERN.test(taskId)) return null
  let descriptor
  let text
  try {
    descriptor = fs.openSync(ciLedgerPath(dataDir, taskId), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW)
    const stat = fs.fstatSync(descriptor)
    if (!stat.isFile() || stat.size > MAX_CI_LEDGER_BYTES) return null
    text = fs.readFileSync(descriptor, 'utf8')
  } catch {
    return null
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
  try {
    const ledger = JSON.parse(text)
    return ledger && typeof ledger === 'object' && !Array.isArray(ledger) ? ledger : null
  } catch {
    return null
  }
}

const optionalTimestamp = value => (value === null || value === undefined ? null : canonicalTimestamp(value))
const optionalText = value => (typeof value === 'string' ? value : null)

// Derive the per-run and per-task figures from a recorded ledger. Returns
// {status: 'present', ...} or {status: 'missing', detail, kind}.
function summarizeCiLedger(ledger, taskId, taskPrUrl) {
  const invalid = detail => ({status: 'missing', kind: 'ci-ledger-invalid', detail})
  if (!ledger) return {status: 'missing', kind: null, detail: 'no run ledger was captured for this task'}
  if (ledger.schema !== CI_LEDGER_SCHEMA || ledger.task_id !== taskId) return invalid('ledger schema or task identity does not match')
  const pr = parseGithubPrUrl(ledger.pr_url)
  if (!pr || ledger.pr_number !== pr.number || ledger.repository !== `${pr.owner}/${pr.repo}`) return invalid('ledger PR identity is malformed')
  if (taskPrUrl && taskPrUrl !== ledger.pr_url) {
    return {status: 'missing', kind: 'ci-pr-identity', detail: `ledger records ${ledger.pr_url} but the task recorded ${taskPrUrl}`}
  }
  if (typeof ledger.head_ref !== 'string' || !ledger.head_ref) return invalid('ledger has no head ref')
  if (!['open', 'closed'].includes(ledger.pr_state)) return invalid('ledger PR state is malformed')
  if (!CI_LANDING_PATTERN.test(ledger.landing || '')) return invalid('ledger landing is malformed')
  if (!CI_CAPTURE_SOURCES.has(ledger.captured_from) || !canonicalTimestamp(ledger.captured_at)) return invalid('ledger capture provenance is malformed')
  if (!Array.isArray(ledger.runs)) return invalid('ledger runs are malformed')
  const trainNumber = ledger.landing.startsWith('train:') ? Number(ledger.landing.slice('train:'.length)) : null
  if (trainNumber !== null && ledger.train_pr_number !== trainNumber) return invalid('ledger train number does not match its landing')

  const runs = []
  for (const run of ledger.runs) {
    if (!run || !Number.isSafeInteger(run.id) || !Array.isArray(run.jobs)) return invalid('a recorded run is malformed')
    const createdAt = optionalTimestamp(run.created_at)
    let runnerSeconds = 0
    let firstStart = null
    let lastCompleted = null
    for (const job of run.jobs) {
      if (!job || typeof job !== 'object') return invalid('a recorded job is malformed')
      const started = optionalTimestamp(job.started_at)
      const completed = optionalTimestamp(job.completed_at)
      if (started && completed) {
        const seconds = isoSecondsBetween(started, completed)
        if (seconds !== null) runnerSeconds += seconds
      }
      if (started && (firstStart === null || started < firstStart)) firstStart = started
      if (completed && (lastCompleted === null || completed > lastCompleted)) lastCompleted = completed
    }
    const queueSeconds = createdAt && firstStart ? isoSecondsBetween(createdAt, firstStart) : null
    const completedAt = lastCompleted
      ?? (run.status === 'completed' ? optionalTimestamp(run.updated_at) : null)
    runs.push({
      run_id: run.id,
      name: optionalText(run.name),
      event: optionalText(run.event),
      status: optionalText(run.status),
      conclusion: optionalText(run.conclusion),
      run_attempt: Number.isSafeInteger(run.run_attempt) ? run.run_attempt : null,
      created_at: createdAt,
      completed_at: completedAt,
      jobs: run.jobs.length,
      runner_seconds: runnerSeconds,
      queue_seconds: queueSeconds,
    })
  }
  const sortedRuns = sortedBy(runs, run => `${run.created_at ?? ''}${KEY_SEPARATOR}${String(run.run_id).padStart(20, '0')}`)
  const train = parseTrain(ledger.title, ledger.body)
  const created = sortedRuns.map(run => run.created_at).filter(Boolean)
  const completed = sortedRuns.map(run => run.completed_at).filter(Boolean)
  return {
    status: 'present',
    detail: null,
    runs: sortedRuns,
    summary: {
      pr_url: ledger.pr_url,
      pr_number: pr.number,
      repository: ledger.repository,
      head_ref: ledger.head_ref,
      pr_state: ledger.pr_state,
      pr_created_at: optionalTimestamp(ledger.pr_created_at),
      pr_closed_at: optionalTimestamp(ledger.pr_closed_at),
      pr_merged_at: optionalTimestamp(ledger.pr_merged_at),
      landing: ledger.landing,
      train_pr_number: trainNumber,
      is_train: train !== null,
      member_count: train?.member_count ?? null,
      ejected_count: train?.ejected_count ?? null,
      fix_round_count: train?.fix_round_count ?? null,
      runs: sortedRuns.length,
      runs_cancelled: sortedRuns.filter(run => run.conclusion === 'cancelled').length,
      runs_failed: sortedRuns.filter(run => CI_FAILED_CONCLUSIONS.has(run.conclusion)).length,
      runs_succeeded: sortedRuns.filter(run => run.conclusion === 'success').length,
      runner_seconds: sortedRuns.reduce((total, run) => total + run.runner_seconds, 0),
      queue_seconds: sortedRuns.reduce((total, run) => total + (run.queue_seconds ?? 0), 0),
      first_run_created_at: created.length ? created.reduce((min, value) => (value < min ? value : min)) : null,
      last_run_completed_at: completed.length ? completed.reduce((max, value) => (value > max ? value : max)) : null,
      captured_from: ledger.captured_from,
      captured_at: ledger.captured_at,
      cards_moved_claimed: cardsMovedClaimed(ledger.body),
    },
  }
}

function writeTasks(db, tasks, usageByTask, toolUsageByTask, gitResults, options, issues) {
  const taskInsert = insert(db, 'task', [
    'task_id', 'title', 'repo', 'project_path', 'kind', 'branch', 'pr_url',
    'harness', 'model', 'effort', 'backend', 'worktree', 'dispatched_at',
    'started_at', 'ended_at', 'wall_clock_seconds', 'agent_active_seconds',
    'first_commit_at', 'pr_opened_at', 'launch_to_pr_seconds', 'merged_at',
    'local_landed_at', 'teardown_at',
    'files_changed', 'prod_src_files', 'distinct_areas', 'adds', 'dels',
    'import_in_degree', 'import_out_degree',
    'findings', 'review_rounds', 'ask_user_count', 'gate_failures', 'failure_mode',
    'tokens_in', 'tokens_out', 'tokens_reasoning', 'tokens_cached_read',
    'tokens_cached_write', 'notional_cost_usd', 'api_calls', 'sessions',
    'outcome', 'reverted', 'peak_context_tokens', 'compactions', 'restarts',
    'turns', 'tool_calls', 'tool_result_tokens_est', 'assistant_output_tokens', 'base_prompt_tokens_est',
    'cards_moved_claimed',
  ])
  const ciInsert = insert(db, 'task_ci', [
    'task_id', 'pr_url', 'pr_number', 'repository', 'head_ref', 'pr_state',
    'pr_created_at', 'pr_closed_at', 'pr_merged_at', 'landing', 'train_pr_number',
    'is_train', 'member_count', 'ejected_count', 'fix_round_count',
    'runs', 'runs_cancelled', 'runs_failed', 'runs_succeeded', 'runner_seconds', 'queue_seconds',
    'first_run_created_at', 'last_run_completed_at', 'captured_from', 'captured_at',
  ])
  const ciRunInsert = insert(db, 'task_ci_run', [
    'task_id', 'run_id', 'name', 'event', 'status', 'conclusion', 'run_attempt',
    'created_at', 'completed_at', 'jobs', 'runner_seconds', 'queue_seconds',
  ])
  const toolInsert = insert(db, 'task_tool_usage', [
    'task_id', 'tool_name', 'tool_class', 'calls', 'result_bytes', 'result_tokens_est', 'wall_seconds_in_tool',
  ])
  const classInsert = insert(db, 'task_tool_class', [
    'task_id', 'tool_class', 'calls', 'result_bytes', 'result_tokens_est', 'wall_seconds_in_tool',
  ])
  const largestInsert = insert(db, 'task_largest_results', [
    'task_id', 'rank', 'tool_name', 'tool_class', 'command_or_input_head', 'tokens_est',
  ])
  const turnInsert = insert(db, 'task_turn_timeline', [
    'task_id', 'turn_index', 'ts', 'context_tokens', 'output_tokens', 'tool_name', 'tool_class', 'tool_result_tokens_est',
  ])
  const sourceInsert = insert(db, 'task_source', ['task_id', 'source', 'status', 'detail'])
  const roundInsert = insert(db, 'round_reason', ['task_id', 'round_index', 'reason', 'note'])
  const commitInsert = insert(db, 'task_commit', ['task_id', 'sha', 'committed_at', 'link_provenance'])
  const fileInsert = insert(db, 'task_file', [
    'task_id', 'path', 'adds', 'dels', 'is_prod_src', 'area', 'introduced',
    'import_in_degree', 'import_out_degree',
  ])
  const modelInsert = insert(db, 'task_model', [
    'task_id', 'provider', 'model', 'tokens_in', 'tokens_out', 'tokens_reasoning',
    'tokens_cached_read', 'tokens_cached_write', 'notional_cost_usd', 'api_calls',
  ])

  for (const task of tasks) {
    const row = task.raw
    const annotation = task.annotation
    const startedAt = canonicalTimestamp(row?.started_at)
    const endedAt = validatedLifecycleTimestamp(row?.ended_at, startedAt)
    const prOpenedAt = validatedLifecycleTimestamp(row?.pr_opened_at, startedAt)
    const teardownAt = validatedLifecycleTimestamp(row?.teardown_at, startedAt)
    const burn = usageByTask.get(task.taskId) || {status: 'missing', detail: 'durable task usage snapshot was not consulted'}
    const toolUsage = toolUsageByTask.get(task.taskId) || {status: 'missing', detail: 'tool-usage snapshot was not consulted'}
    const attribution = toolUsage.status === 'present' ? toolUsage.summary : null
    const receipt = readMergeReceipt(options.dataDir, task.taskId, startedAt)
    const localReceiptCandidate = readLocalLandingReceipt(options.dataDir, task.taskId, startedAt)
    const localReceipt = localReceiptCandidate && row?.project === localReceiptCandidate.project ? localReceiptCandidate : null
    const gitResult = gitResults.results.get(task.taskId) || {status: 'missing', detail: 'git source not consulted'}
    const structure = gitResult.status === 'present' ? gitResult.structure : null
    const totals = burn.status === 'present' ? burn.totals : null
    const stampedMergedAt = row?.outcome === 'pr-merged'
      ? validatedLifecycleTimestamp(row.merged_at, startedAt) : null
    const stampedLocalLandedAt = row?.outcome === 'local-landed'
      ? validatedLifecycleTimestamp(row.local_landed_at, startedAt) : null
    const teardownOutcome = ['forced', 'scout-complete'].includes(row?.outcome)
      && teardownAt ? row.outcome : null
    const provenOutcome = receipt?.merged ? 'merged'
      : localReceipt?.local_landed_at ? 'local-landed'
        : stampedMergedAt ? 'merged'
          : stampedLocalLandedAt ? 'local-landed' : teardownOutcome
    const taskPrUrl = row?.pr_url ?? receipt?.pr_url ?? annotation?.pr_url ?? null
    const ci = summarizeCiLedger(readCiLedgerFile(options.dataDir, task.taskId), task.taskId, taskPrUrl)
    if (ci.status === 'missing' && ci.kind) {
      issues.push({source: 'ci', task_id: task.taskId, kind: ci.kind, detail: ci.detail})
    }

    taskInsert.run(
      task.taskId,
      bind(burn.usage?.title ?? annotation?.title),
      bind(gitResult.status === 'present' ? gitResult.repo : null),
      bind(row?.project),
      bind(row?.kind ?? annotation?.kind),
      bind(row?.branch ?? annotation?.branch),
      bind(taskPrUrl ?? (ci.status === 'present' ? ci.summary.pr_url : null)),
      bind(row?.harness),
      bind(startedAt ? row?.model : null),
      bind(row?.effort),
      bind(row?.backend ?? annotation?.backend),
      bind(row?.worktree),
      bind(startedAt),
      bind(startedAt),
      bind(endedAt),
      bind(endedAt ? isoSecondsBetween(startedAt, endedAt) : null),
      bind(totals ? totals.agent_active_seconds : null),
      bind(gitResult.status === 'present' ? gitResult.first_commit_at : null),
      bind(prOpenedAt),
      bind(prOpenedAt ? isoSecondsBetween(startedAt, prOpenedAt) : null),
      bind(receipt?.merged ? receipt.merged_at : stampedMergedAt),
      bind(localReceipt?.local_landed_at || stampedLocalLandedAt),
      bind(teardownAt),
      bind(structure?.files_changed),
      bind(structure?.prod_src_files),
      bind(structure?.distinct_areas),
      bind(structure?.adds),
      bind(structure?.dels),
      bind(structure?.import_in_degree),
      bind(structure?.import_out_degree),
      bind(capturedCount(row?.findings)),
      bind(capturedCount(row?.review_rounds)),
      bind(capturedCount(row?.ask_user_count)),
      bind(capturedCount(row?.gate_failures)),
      bind(annotation?.failure_mode),
      bind(totals?.tokens_in),
      bind(totals?.tokens_out),
      bind(totals?.tokens_reasoning),
      bind(totals?.tokens_cached_read),
      bind(totals?.tokens_cached_write),
      bind(totals?.notional_cost_usd),
      bind(totals?.api_calls),
      bind(totals?.sessions),
      bind(provenOutcome),
      bind(annotation?.reverted ?? (gitResult.status === 'present' ? gitResult.reverted : null)),
      bind(capturedCount(row?.peak_context_tokens)),
      bind(capturedCount(row?.compactions)),
      bind(capturedCount(row?.restarts)),
      bind(attribution?.turns),
      bind(attribution?.tool_calls),
      bind(attribution?.tool_result_tokens_est),
      bind(attribution?.assistant_output_tokens),
      bind(attribution?.base_prompt_tokens_est),
      bind(ci.status === 'present' ? ci.summary.cards_moved_claimed : null),
    )

    sourceInsert.run(task.taskId, 'raw', row ? 'present' : 'missing',
      row ? null : 'no lifecycle row in the raw capture')
    sourceInsert.run(task.taskId, 'annotation', annotation ? 'present' : 'missing',
      annotation ? null : 'nothing recorded by hand for this task')
    sourceInsert.run(task.taskId, 'codeburn', burn.status, bind(burn.detail))
    sourceInsert.run(task.taskId, 'tool-usage', toolUsage.status, bind(toolUsage.detail))
    sourceInsert.run(task.taskId, 'ci', ci.status, bind(ci.detail))
    sourceInsert.run(task.taskId, 'git', gitResult.status, bind(gitResult.detail))

    if (ci.status === 'present') {
      const summary = ci.summary
      ciInsert.run(task.taskId, summary.pr_url, summary.pr_number, summary.repository, summary.head_ref,
        summary.pr_state, bind(summary.pr_created_at), bind(summary.pr_closed_at), bind(summary.pr_merged_at),
        summary.landing, bind(summary.train_pr_number), bind(summary.is_train),
        bind(summary.member_count), bind(summary.ejected_count), bind(summary.fix_round_count),
        summary.runs, summary.runs_cancelled, summary.runs_failed, summary.runs_succeeded,
        summary.runner_seconds, summary.queue_seconds,
        bind(summary.first_run_created_at), bind(summary.last_run_completed_at),
        summary.captured_from, summary.captured_at)
      for (const run of ci.runs) {
        ciRunInsert.run(task.taskId, run.run_id, bind(run.name), bind(run.event), bind(run.status),
          bind(run.conclusion), bind(run.run_attempt), bind(run.created_at), bind(run.completed_at),
          run.jobs, run.runner_seconds, bind(run.queue_seconds))
      }
    }

    const rounds = Array.isArray(annotation?.round_reasons) ? annotation.round_reasons : []
    rounds.forEach((round, index) => {
      roundInsert.run(task.taskId, Number(round.round ?? index + 1), round.reason, bind(round.note))
    })

    if (gitResult.status === 'present') {
      for (const commit of gitResult.commits) {
        commitInsert.run(task.taskId, commit.sha, bind(commit.committed_at), commit.provenance)
      }
      for (const file of gitResult.files) {
        fileInsert.run(task.taskId, file.path, bind(file.adds), bind(file.dels),
          file.is_prod_src, file.area, file.introduced,
          bind(file.import_in_degree), bind(file.import_out_degree))
      }
    }
    if (toolUsage.status === 'present') {
      for (const tool of toolUsage.tools) {
        toolInsert.run(task.taskId, tool.tool_name, tool.tool_class, tool.calls, tool.result_bytes,
          tool.result_tokens_est, bind(tool.wall_seconds_in_tool))
      }
      for (const cls of toolUsage.classes) {
        classInsert.run(task.taskId, cls.tool_class, cls.calls, cls.result_bytes, cls.result_tokens_est,
          bind(cls.wall_seconds_in_tool))
      }
      for (const result of toolUsage.largest) {
        largestInsert.run(task.taskId, result.rank, result.tool_name, result.tool_class,
          result.command_or_input_head, result.tokens_est)
      }
      for (const turn of toolUsage.timeline) {
        turnInsert.run(task.taskId, turn.turn_index, bind(turn.ts), bind(turn.context_tokens),
          bind(turn.output_tokens), bind(turn.tool_name), bind(turn.tool_class), turn.tool_result_tokens_est)
      }
    }
    if (burn.status === 'present') {
      for (const model of burn.models) {
        modelInsert.run(task.taskId, model.provider, model.model, bind(model.tokens_in),
          bind(model.tokens_out), bind(model.tokens_reasoning), bind(model.tokens_cached_read),
          bind(model.tokens_cached_write), bind(model.notional_cost_usd), bind(model.api_calls))
      }
    }
  }
}

const durabilityKey = row => [
  row.introducing_task_id, row.modifying_task_id, row.introduced_path, row.modifying_sha,
].join(KEY_SEPARATOR)

function writeDurability(db, gitResults) {
  const statement = insert(db, 'durability', [
    'introducing_task_id', 'modifying_task_id', 'introduced_path', 'modified_path',
    'introducing_sha', 'modifying_sha', 'modified_at',
  ])
  const rows = sortedBy(gitResults.durability, row =>
    durabilityKey(row))
  const seen = new Set()
  for (const row of rows) {
    const key = durabilityKey(row)
    if (seen.has(key)) continue
    seen.add(key)
    statement.run(row.introducing_task_id, row.modifying_task_id, row.introduced_path,
      row.modified_path, row.introducing_sha, row.modifying_sha, bind(row.modified_at))
  }
}

function writeIssues(db, issues) {
  const statement = insert(db, 'ingest_issue', ['source', 'ordinal', 'task_id', 'kind', 'detail'])
  const counters = new Map()
  for (const issue of issues) {
    const ordinal = (counters.get(issue.source) || 0) + 1
    counters.set(issue.source, ordinal)
    statement.run(issue.source, ordinal, bind(issue.task_id), issue.kind, issue.detail)
  }
}

// --- lifecycle capture -----------------------------------------------------

const CAPTURE_COLUMNS = [
  'task', 'worktree', 'harness', 'model', 'effort', 'kind', 'project',
  'started_at', 'ended_at', 'mode', 'backend', 'branch', 'pr_url',
  'pr_opened_at', 'merged_at', 'local_landed_at', 'teardown_at', 'outcome',
  'pipeline_run_id', 'findings', 'review_rounds', 'ask_user_count', 'gate_failures',
  'peak_context_tokens', 'compactions', 'restarts',
]

// The context signal at capture: bin/fm-context-watch.mjs reads the task's
// stamped session records (bin/fm-task-session.mjs owns the receipts) while
// they still exist. A task it cannot bind keeps the three fields empty, so a
// harness without stamps or a record the store never wrote reads as missing
// in the store rather than as zero. Forward-only: capture never derives these
// for a task whose records are gone, and rebuild never backfills them.
function readContextSignal(options, taskId) {
  const reader = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fm-context-watch.mjs')
  const result = spawnSync(process.execPath, [reader, 'read', taskId], {
    encoding: 'utf8',
    env: {...process.env, FM_STATE_OVERRIDE: options.stateDir, FM_DATA_OVERRIDE: options.dataDir},
    timeout: 60000,
    maxBuffer: 16 * 1024 * 1024,
  })
  if (result.error || result.status !== 0) return null
  let signal
  try { signal = JSON.parse(result.stdout) } catch { return null }
  if (signal?.schema !== 'fm-context-watch.v1' || signal.task !== taskId) return null
  return {
    peak_context_tokens: capturedCount(signal.peak),
    compactions: capturedCount(signal.compactions),
    restarts: capturedCount(signal.restarts),
  }
}

// The breakdown at capture: bin/fm-context-watch.mjs usage folds the same
// bound records. The object is persisted beside usage.json, bound to this
// launch by spawned_at, and replaced on every later capture that can still
// read the records; a capture that cannot bind them leaves the prior snapshot
// untouched, so the last successful fold is what survives cleanup.
function readToolUsageSnapshot(options, taskId) {
  const reader = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fm-context-watch.mjs')
  const result = spawnSync(process.execPath, [reader, 'usage', taskId], {
    encoding: 'utf8',
    env: {...process.env, FM_STATE_OVERRIDE: options.stateDir, FM_DATA_OVERRIDE: options.dataDir},
    timeout: 60000,
    maxBuffer: 64 * 1024 * 1024,
  })
  if (result.error || result.status !== 0) return null
  let usage
  try { usage = JSON.parse(result.stdout) } catch { return null }
  if (usage?.schema !== TOOL_USAGE_SCHEMA || usage.task !== taskId) return null
  return usage
}

function persistToolUsageSnapshot(options, taskId, usage, spawnedAt) {
  const dir = path.join(options.dataDir, taskId)
  const file = path.join(dir, 'tool-usage.json')
  fs.mkdirSync(dir, {recursive: true})
  const staged = `${file}.${process.pid}`
  const fd = fs.openSync(staged, 'w', 0o600)
  try {
    fs.writeFileSync(fd, `${JSON.stringify({...usage, spawned_at: spawnedAt ?? null})}\n`)
    fs.fsyncSync(fd)
  } finally {
    fs.closeSync(fd)
  }
  fs.renameSync(staged, file)
}

function resolvePipelineMetrics(pipeline, previous, identity) {
  if (pipeline === PIPELINE_METRICS_UNAVAILABLE) return null
  const source = pipeline ?? (
    previous?.started_at === identity.startedAt
      && previous?.project === identity.project
      && previous?.branch === identity.branch
      && previous?.pr_url === identity.prUrl
      ? previous : null
  )
  if (!source?.pipeline_run_id) return null
  const metrics = {
    pipeline_run_id: source.pipeline_run_id,
    findings: capturedCount(source.findings),
    review_rounds: capturedCount(source.review_rounds),
    ask_user_count: capturedCount(source.ask_user_count),
    gate_failures: capturedCount(source.gate_failures),
  }
  return Object.values(metrics).some(value => value === null) ? null : metrics
}

function capture(options, taskId, argv) {
  if (!TASK_ID_PATTERN.test(taskId)) throw new Error('capture needs a safe task id')
  let outcome = null
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--outcome' && argv[index + 1]) {
      outcome = argv[index + 1]
      index += 1
      continue
    }
    throw new Error(`unknown capture option '${argv[index]}'`)
  }
  const meta = readMeta(path.join(options.stateDir, `${taskId}.meta`))
  const existing = fs.existsSync(options.rawFile) ? readRawCapture(options.rawFile, []).rows : []
  const previous = [...existing].reverse().find(candidate => candidate.task === taskId) || null
  const receiptIdentity = readMetaWithRequiredFields(
    path.join(options.dataDir, 'pr-merges', `${taskId}.receipt`),
    ['schema', 'task_id', 'spawned_at'],
  )
  const receiptStartedAt = receiptIdentity?.task_id === taskId
    ? canonicalTimestamp(receiptIdentity.spawned_at) : null
  if (!meta && !previous && outcome !== 'pr-merged') {
    throw new Error(`task metadata and prior lifecycle capture are unavailable for ${taskId}`)
  }
  if (outcome !== null && !['pr-merged', 'local-landed', 'forced', 'scout-complete'].includes(outcome)) {
    throw new Error(`unsupported lifecycle outcome '${outcome}'`)
  }
  if (outcome !== null && meta?.outcome && outcome !== meta.outcome) {
    throw new Error('capture outcome does not match the stamped lifecycle outcome')
  }
  const startedAt = meta?.spawned_at ?? previous?.started_at ?? receiptStartedAt
  const mergeReceipt = readMergeReceipt(options.dataDir, taskId, canonicalTimestamp(startedAt))
  const stampedMerge = validatedLifecycleTimestamp(meta?.merged_at, canonicalTimestamp(startedAt))
  if (outcome === 'pr-merged' && !mergeReceipt?.merged && !stampedMerge) {
    throw new Error('PR merge capture lacks a completed launch-bound merge receipt')
  }
  const project = meta?.project ?? previous?.project
  const branch = meta?.branch ?? previous?.branch ?? `fm/${taskId}`
  const prUrl = meta?.pr ?? previous?.pr_url ?? mergeReceipt?.pr_url
  const pipeline = readPipelineMetrics(options.pipelineDbPath, {project, branch, prUrl})
  const processMetrics = resolvePipelineMetrics(pipeline, previous, {startedAt, project, branch, prUrl})
  const contextSignal = readContextSignal(options, taskId)
  const toolUsage = readToolUsageSnapshot(options, taskId)
  if (toolUsage) persistToolUsageSnapshot(options, taskId, toolUsage, canonicalTimestamp(startedAt))
  const row = {
    task: taskId,
    worktree: meta?.worktree ?? previous?.worktree,
    harness: meta?.harness ?? previous?.harness,
    model: meta?.model ?? previous?.model,
    effort: meta?.effort ?? previous?.effort,
    kind: meta?.kind ?? previous?.kind,
    project,
    started_at: startedAt,
    ended_at: meta?.teardown_at ?? previous?.ended_at,
    mode: meta?.mode ?? previous?.mode,
    backend: meta?.backend ?? previous?.backend ?? 'tmux',
    branch,
    pr_url: prUrl,
    pr_opened_at: meta?.pr_opened_at ?? previous?.pr_opened_at,
    merged_at: mergeReceipt?.merged
      ? mergeReceipt.merged_at
      : (meta?.merged_at ?? previous?.merged_at),
    local_landed_at: meta?.local_landed_at ?? previous?.local_landed_at,
    teardown_at: meta?.teardown_at ?? previous?.teardown_at,
    outcome: outcome ?? meta?.outcome ?? previous?.outcome,
    pipeline_run_id: processMetrics?.pipeline_run_id,
    findings: processMetrics?.findings,
    review_rounds: processMetrics?.review_rounds,
    ask_user_count: processMetrics?.ask_user_count,
    gate_failures: processMetrics?.gate_failures,
    peak_context_tokens: contextSignal?.peak_context_tokens ?? previous?.peak_context_tokens,
    compactions: contextSignal?.compactions ?? previous?.compactions,
    restarts: contextSignal?.restarts ?? previous?.restarts,
  }
  for (const column of CAPTURE_COLUMNS) row[column] = String(row[column] ?? '')
  fs.mkdirSync(path.dirname(options.rawFile), {recursive: true})
  const exact = previous
    && CAPTURE_COLUMNS.every(column => String(previous[column] ?? '') === row[column])
  if (!exact) {
    const lines = [V2_MARKER, CAPTURE_COLUMNS.join('\t'), CAPTURE_COLUMNS.map(column => escapeRawValue(row[column])).join('\t')]
    // One O_APPEND write keeps concurrent tasks' self-contained schema blocks
    // together. The durable layer is flushed before lifecycle cleanup proceeds.
    const bytes = Buffer.from(`\n${lines.join('\n')}\n`)
    const fd = fs.openSync(options.rawFile, 'a', 0o600)
    try {
      if (fs.writeSync(fd, bytes) !== bytes.length) throw new Error('short lifecycle append')
      fs.fsyncSync(fd)
    } finally {
      fs.closeSync(fd)
    }
  }
}

// --- CI ledger capture from the forge -------------------------------------
//
// Read-only: every call is `gh api` GET. The ledger records what the forge
// reports at capture; nothing is reconstructed. Only the capture path and the
// explicit backfill reach the forge, never rebuild or report.

function forgeJson(route, {paginate = false} = {}) {
  const args = ['api', route]
  if (paginate) args.push('--paginate', '--slurp')
  const result = spawnSync('gh', args, {encoding: 'utf8', timeout: 120000, maxBuffer: 64 * 1024 * 1024})
  if (result.error) throw new Error(`forge read failed for ${route}: ${result.error.message}`)
  if (result.status !== 0) {
    const reason = String(result.stderr || '').trim().split('\n')[0] || `exit ${result.status}`
    throw new Error(`forge read failed for ${route}: ${reason}`)
  }
  try {
    return JSON.parse(result.stdout)
  } catch {
    throw new Error(`forge read for ${route} was not JSON`)
  }
}

// --paginate --slurp yields one element per page: the page object for an
// object endpoint, the page array for an array endpoint.
function forgePages(route, key) {
  const pages = forgeJson(route, {paginate: true})
  const list = Array.isArray(pages) ? pages : [pages]
  return list.flatMap(page => {
    if (Array.isArray(page)) return page
    const items = page?.[key]
    if (!Array.isArray(items)) throw new Error(`forge read for ${route} lacks ${key}`)
    return items
  })
}

function readForgePr(pr) {
  const record = forgeJson(`/repos/${pr.owner}/${pr.repo}/pulls/${pr.number}`)
  if (record?.number !== pr.number || typeof record.merged !== 'boolean'
      || !['open', 'closed'].includes(record.state) || typeof record.head?.ref !== 'string' || !record.head.ref) {
    throw new Error(`forge PR record for ${pr.url} is malformed`)
  }
  const stamp = (field, required) => {
    const value = optionalTimestamp(record[field])
    if (required && !value) throw new Error(`forge PR record for ${pr.url} has no valid ${field}`)
    return value
  }
  return {
    state: record.state,
    merged: record.merged,
    head_ref: record.head.ref,
    title: typeof record.title === 'string' ? record.title : '',
    body: typeof record.body === 'string' ? record.body : '',
    created_at: stamp('created_at', true),
    closed_at: stamp('closed_at', false),
    merged_at: stamp('merged_at', false),
  }
}

// Every workflow run on the PR's head branch created before the PR closed,
// with its jobs across all attempts. Runs after the close are not fetched.
function readForgeRuns(pr, headRef, closedAt) {
  const route = `/repos/${pr.owner}/${pr.repo}/actions/runs?branch=${encodeURIComponent(headRef)}&per_page=100`
  const runs = forgePages(route, 'workflow_runs')
    .filter(run => run && Number.isSafeInteger(run.id) && run.head_branch === headRef)
    .filter(run => !closedAt || (optionalTimestamp(run.created_at) ?? '') <= closedAt)
  const keep = (record, fields) => Object.fromEntries(fields.map(field => [field, record[field] ?? null]))
  return sortedBy(runs, run => `${run.created_at ?? ''}${KEY_SEPARATOR}${String(run.id).padStart(20, '0')}`).map(run => ({
    ...keep(run, ['id', 'name', 'event', 'status', 'conclusion', 'run_attempt', 'created_at', 'run_started_at', 'updated_at', 'head_sha']),
    jobs: forgePages(`/repos/${pr.owner}/${pr.repo}/actions/runs/${run.id}/jobs?filter=all&per_page=100`, 'jobs')
      .filter(job => job && typeof job === 'object')
      .map(job => keep(job, ['id', 'name', 'status', 'conclusion', 'run_attempt', 'started_at', 'completed_at'])),
  }))
}

const TRAIN_MENTION = /train[^\n#]{0,80}#([1-9]\d*)/gi

// The first `train ... #<n>` mention in `text` that names another PR; a PR's
// own number is never its train.
function trainMentionedIn(text, pattern, ownNumber) {
  pattern.lastIndex = 0
  for (let match = pattern.exec(text); match; match = pattern.exec(text)) {
    const number = Number(match[1])
    if (number !== ownNumber) return number
  }
  return null
}

function trainFromClosingComment(pr) {
  let found = null
  for (const comment of forgePages(`/repos/${pr.owner}/${pr.repo}/issues/${pr.number}/comments?per_page=100`, 'comments')) {
    found = trainMentionedIn(String(comment?.body ?? ''), TRAIN_MENTION, pr.number) ?? found
  }
  return found
}

// The task's Done row in data/backlog.md or data/done-archive.md, as the
// backlog format spells it, naming its train by `#<n>` or a PR URL.
function trainFromDoneRow(dataDir, taskId, ownNumber) {
  const escaped = taskId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const row = new RegExp(`^- \\[x\\] ${escaped} `)
  const mention = /train[^\n]{0,80}?(?:#|\/pull\/)([1-9]\d*)/gi
  for (const name of ['backlog.md', 'done-archive.md']) {
    const text = readTextFile(path.join(dataDir, name))
    if (text === null) continue
    for (const line of text.split('\n')) {
      if (!row.test(line)) continue
      const found = trainMentionedIn(line, mention, ownNumber)
      if (found !== null) return found
    }
  }
  return null
}

function buildCiLedger(options, taskId, pr, {landing = null, trainNumber = null, from, allowOpen = false}) {
  const record = readForgePr(pr)
  if (!allowOpen && record.state === 'open') throw new Error(`${pr.url} is still open; the run ledger records landed PRs`)
  let resolvedLanding = landing
  let resolvedTrain = trainNumber
  if (!resolvedLanding) {
    if (record.merged) {
      resolvedLanding = 'direct'
    } else {
      resolvedTrain = trainFromClosingComment(pr) ?? trainFromDoneRow(options.dataDir, taskId, pr.number)
      resolvedLanding = resolvedTrain === null ? 'closed' : `train:${resolvedTrain}`
    }
  }
  return {
    schema: CI_LEDGER_SCHEMA,
    task_id: taskId,
    pr_url: pr.url,
    pr_number: pr.number,
    repository: `${pr.owner}/${pr.repo}`,
    head_ref: record.head_ref,
    title: record.title,
    body: record.body,
    pr_state: record.state,
    pr_created_at: record.created_at,
    pr_closed_at: record.closed_at,
    pr_merged_at: record.merged_at,
    landing: resolvedLanding,
    train_pr_number: resolvedTrain,
    captured_from: from,
    captured_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    runs: readForgeRuns(pr, record.head_ref, record.closed_at),
  }
}

function writeCiLedger(options, ledger) {
  const file = ciLedgerPath(options.dataDir, ledger.task_id)
  fs.mkdirSync(path.dirname(file), {recursive: true})
  const staged = `${file}.${process.pid}`
  const fd = fs.openSync(staged, 'w', 0o600)
  try {
    fs.writeFileSync(fd, `${JSON.stringify(ledger)}\n`)
    fs.fsyncSync(fd)
  } finally {
    fs.closeSync(fd)
  }
  fs.renameSync(staged, file)
}

// Capture one PR's ledger and, for a merged train, every manifest member's
// ledger as landed through it. The PR's own ledger is kept when it already
// records this task and this PR unless replacement is explicit; a ledger for
// another PR is not this landing's record and is rebuilt. A member ledger that
// already exists is never replaced by the manifest path, whatever the flag,
// because the member's own receipt or capture is the closer record of how it
// landed, and a train that did not merge landed nothing.
function captureCiTree(options, taskId, pr, {from, replaceExisting}) {
  const outcome = {captured: [], kept: [], skipped: [], failed: []}
  let ledger = null
  if (!replaceExisting) {
    const existing = readCiLedgerFile(options.dataDir, taskId)
    if (existing?.task_id === taskId && existing.pr_url === pr.url) ledger = existing
  }
  if (ledger) {
    outcome.kept.push(taskId)
  } else {
    ledger = buildCiLedger(options, taskId, pr, {from})
    writeCiLedger(options, ledger)
    outcome.captured.push(taskId)
  }
  const train = parseTrain(ledger.title, ledger.body)
  const trainMerged = ledger.landing === 'direct' && Boolean(ledger.pr_merged_at)
  for (const member of train?.members ?? []) {
    const memberTask = /^fm\/(.+)$/.exec(member.branch)?.[1]
    const memberPr = parseGithubPrUrl(`https://github.com/${pr.owner}/${pr.repo}/pull/${member.number}`)
    const label = `#${member.number} ${member.branch}`
    if (!memberTask || !TASK_ID_PATTERN.test(memberTask) || !memberPr) {
      outcome.failed.push({task: label, reason: 'manifest member does not name a task branch'})
      continue
    }
    if (!trainMerged) {
      outcome.failed.push({task: memberTask, reason: `train #${pr.number} did not merge; nothing landed through it`})
      continue
    }
    if (fs.existsSync(ciLedgerPath(options.dataDir, memberTask))) {
      outcome.skipped.push(memberTask)
      continue
    }
    try {
      writeCiLedger(options, buildCiLedger(options, memberTask, memberPr, {
        landing: `train:${pr.number}`, trainNumber: pr.number, from: 'train-manifest', allowOpen: true,
      }))
      outcome.captured.push(memberTask)
    } catch (error) {
      outcome.failed.push({task: memberTask, reason: error.message})
    }
  }
  return outcome
}

function recordedPrUrl(options, taskId) {
  const meta = readMeta(path.join(options.stateDir, `${taskId}.meta`))
  if (meta?.pr) return meta.pr
  const rows = fs.existsSync(options.rawFile) ? readRawCapture(options.rawFile, []).rows : []
  const previous = [...rows].reverse().find(candidate => candidate.task === taskId)
  if (previous?.pr_url) return previous.pr_url
  const receipt = readMetaWithRequiredFields(path.join(options.dataDir, 'pr-merges', `${taskId}.receipt`), ['schema', 'task_id', 'pr'])
  return receipt?.task_id === taskId ? receipt.pr : null
}

function captureCi(options, taskId, argv) {
  if (!TASK_ID_PATTERN.test(taskId)) throw new Error('capture-ci needs a safe task id')
  let explicitUrl = null
  let from = 'manual'
  let replaceExisting = false
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--from' && argv[index + 1]) {
      from = argv[index + 1]
      index += 1
    } else if (argv[index] === '--replace-existing') {
      replaceExisting = true
    } else if (explicitUrl === null && !argv[index].startsWith('-')) {
      explicitUrl = argv[index]
    } else {
      throw new Error(`unknown capture-ci option '${argv[index]}'`)
    }
  }
  if (!CI_CAPTURE_SOURCES.has(from) || from === 'train-manifest') throw new Error(`unsupported capture source '${from}'`)
  const recorded = recordedPrUrl(options, taskId)
  if (explicitUrl && recorded && explicitUrl !== recorded) {
    throw new Error(`${explicitUrl} conflicts with the PR recorded for ${taskId} (${recorded})`)
  }
  const url = explicitUrl ?? recorded
  if (!url) throw new Error(`no PR is recorded for ${taskId}; pass its URL`)
  const pr = parseGithubPrUrl(url)
  if (!pr) throw new Error('capture-ci needs a canonical GitHub PR URL')
  return captureCiTree(options, taskId, pr, {from, replaceExisting})
}

// One pull for every merged receipt without a ledger. A receipt whose PR the
// forge cannot serve is named and counted, never invented.
function backfillCi(options, argv) {
  let replaceExisting = false
  let limit = null
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--replace-existing') {
      replaceExisting = true
    } else if (argv[index] === '--limit' && /^[1-9]\d*$/.test(argv[index + 1] || '')) {
      limit = Number(argv[index + 1])
      index += 1
    } else {
      throw new Error(`unknown backfill-ci option '${argv[index]}'`)
    }
  }
  const receiptDir = path.join(options.dataDir, 'pr-merges')
  let names = []
  try {
    names = fs.readdirSync(receiptDir).filter(name => name.endsWith('.receipt')).sort()
  } catch {
    names = []
  }
  const outcome = {captured: [], skippedExisting: [], skippedNotLanded: [], failed: []}
  for (const name of names) {
    if (limit !== null && outcome.captured.length >= limit) break
    const taskId = name.slice(0, -'.receipt'.length)
    if (!TASK_ID_PATTERN.test(taskId)) continue
    const receipt = readMetaWithRequiredFields(path.join(receiptDir, name), ['schema', 'task_id', 'pr', 'phase'])
    const pr = receipt?.task_id === taskId ? parseGithubPrUrl(receipt.pr) : null
    if (!receipt || !pr || receipt.phase !== 'merged') {
      outcome.skippedNotLanded.push(taskId)
      continue
    }
    try {
      const tree = captureCiTree(options, taskId, pr, {from: 'backfill', replaceExisting})
      outcome.captured.push(...tree.captured)
      outcome.skippedExisting.push(...tree.kept, ...tree.skipped)
      outcome.failed.push(...tree.failed)
    } catch (error) {
      outcome.failed.push({task: taskId, reason: error.message})
    }
  }
  return outcome
}

// --- explicit codeburn-history recovery -----------------------------------

function normalizedObservedPath(value) {
  return String(value || '')
    .replace(/\\/g, '/')
    .replace(/^\/+/, '')
    .replace(/[-/_]+/g, '/')
    .replace(/\/$/, '')
    .toLowerCase()
}

function slashNormalizedObservedPath(value) {
  return String(value || '').replace(/\\/g, '/')
}

function codeburnExportPeriod(record) {
  const summaries = Array.isArray(record?.summary) ? record.summary : []
  if (summaries.length !== 1) throw new Error('codeburn export must declare exactly one summary period')
  const summary = summaries[0]
  const match = /^(\d{4}-\d{2}-\d{2}) to (\d{4}-\d{2}-\d{2})$/.exec(summary?.Period || '')
  if (!match) throw new Error('codeburn export period is malformed')
  const start = new Date(`${match[1]}T00:00:00.000Z`)
  const last = new Date(`${match[2]}T00:00:00.000Z`)
  if (!Number.isFinite(start.getTime()) || !Number.isFinite(last.getTime()) || last < start
      || start.toISOString().slice(0, 10) !== match[1]
      || last.toISOString().slice(0, 10) !== match[2]) {
    throw new Error('codeburn export period is invalid')
  }
  const endExclusive = new Date(last.getTime() + 24 * 60 * 60 * 1000)
  if (typeof summary['Cost (USD)'] !== 'number' || !Number.isFinite(summary['Cost (USD)'])
      || summary['Cost (USD)'] < 0 || !Number.isSafeInteger(summary['API Calls'])
      || summary['API Calls'] < 0) {
    throw new Error('codeburn export summary totals are malformed')
  }
  return {
    start: start.getTime(),
    endExclusive: endExclusive.getTime(),
    label: summary.Period,
    cost_usd: summary['Cost (USD)'],
    calls: summary['API Calls'],
  }
}

function readBackfillTitle(dataDir, taskId) {
  const brief = readTextFile(path.join(dataDir, taskId, 'brief.md'))
  if (brief === null) return taskId
  const lines = brief.split('\n')
  const taskHeader = lines.findIndex(line => /^# Task\s*$/.test(line))
  if (taskHeader < 0) return taskId
  return lines.slice(taskHeader + 1).find(line => line.trim())?.trim() || taskId
}

function planBackfillSnapshot(options, task, aggregation, exportHash, replaceExisting) {
  const models = sortedBy([...aggregation.models.values()], model =>
    [model.provider, model.name].join(KEY_SEPARATOR))
  const snapshot = {
    schema: 'fm-task-usage.v2',
    id: task.task,
    title: readBackfillTitle(options.dataDir, task.task),
    kind: task.kind || 'ship',
    project: task.project || null,
    delivery_mode: task.mode || null,
    harness: task.harness || 'unknown',
    configured_model: task.model || 'default',
    actual_models: models.map(model => model.name),
    models: models.map(model => ({
      name: model.name,
      provider: model.provider,
      calls: model.calls,
      input_tokens: model.input_tokens,
      output_tokens: model.output_tokens,
      reasoning_tokens: model.reasoning_tokens,
      cache_read_tokens: model.cache_read_tokens,
      cache_write_tokens: model.cache_write_tokens,
      cost_usd: model.cost_usd,
    })),
    tokens: {
      input: aggregation.input_tokens,
      output: aggregation.output_tokens,
      reasoning: aggregation.reasoning_tokens,
      cache_read: aggregation.cache_read_tokens,
      cache_write: aggregation.cache_write_tokens,
    },
    cost_usd: aggregation.cost_usd,
    calls: aggregation.records,
    sessions: aggregation.sessions.size,
    spawned_at: task.started_at,
    captured_at: task.ended_at,
    duration_seconds: isoSecondsBetween(task.started_at, task.ended_at),
    correlation: {
      worktree: task.worktree,
      project_key: [...aggregation.projectKeys].sort().join(', '),
      project_match: 'codeburn-export-record',
      baseline: false,
      attribution: 'timestamp-window',
      window: {start: task.started_at, end: task.ended_at},
      records: aggregation.records,
      export_sha256: exportHash,
    },
  }
  const taskDir = path.join(options.dataDir, task.task)
  let taskDirExists = true
  try {
    const stat = fs.lstatSync(taskDir)
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('task usage directory is not a regular directory')
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
    taskDirExists = false
  }
  const target = path.join(taskDir, 'usage.json')
  let existing = null
  if (taskDirExists) {
    try {
      const stat = fs.lstatSync(target)
      if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('task usage snapshot is not a regular file')
      existing = fs.readFileSync(target)
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }
  }
  const snapshotBytes = Buffer.from(`${JSON.stringify(snapshot)}\n`)
  if (existing?.equals(snapshotBytes)) return {taskDir, target, snapshotBytes, existing, backup: null, noop: true}
  if (existing !== null && !replaceExisting) {
    throw new Error(`task ${task.task} already has a different usage snapshot; pass --replace-existing to preserve and replace it`)
  }
  let backup = null
  if (existing !== null) {
    const priorHash = crypto.createHash('sha256').update(existing).digest('hex')
    backup = path.join(taskDir, `usage.pre-backfill.${priorHash}.json`)
    try {
      const stat = fs.lstatSync(backup)
      if (!stat.isFile() || stat.isSymbolicLink() || !fs.readFileSync(backup).equals(existing)) {
        throw new Error(`task ${task.task} has a conflicting preserved usage artifact`)
      }
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error
    }
  }
  return {taskDir, target, snapshotBytes, existing, backup, noop: false}
}

function applyBackfillSnapshot(plan) {
  if (plan.noop) return
  fs.mkdirSync(plan.taskDir, {recursive: true, mode: 0o700})
  if (plan.existing !== null && plan.backup !== null && !fs.existsSync(plan.backup)) {
    fs.writeFileSync(plan.backup, plan.existing, {mode: 0o600, flag: 'wx'})
  }
  const taskDir = plan.taskDir
  const target = plan.target
  const staged = path.join(taskDir, `.usage.backfill.${process.pid}.${crypto.randomBytes(8).toString('hex')}`)
  try {
    fs.writeFileSync(staged, plan.snapshotBytes, {mode: 0o600, flag: 'wx'})
    fs.renameSync(staged, target)
  } finally {
    try { fs.unlinkSync(staged) } catch {}
  }
}

function backfillCodeburn(options, argv) {
  const replaceExisting = argv[0] === '--replace-existing'
  const args = replaceExisting ? argv.slice(1) : argv
  if (args.length !== 1) throw new Error('backfill-codeburn needs [--replace-existing] and exactly one codeburn export.json path')
  const exportFile = args[0]
  const exportText = readTextFile(exportFile)
  if (exportText === null) throw new Error(`codeburn export is unreadable: ${exportFile}`)
  let exported
  try {
    exported = JSON.parse(exportText)
  } catch {
    throw new Error('codeburn export is not valid JSON')
  }
  if (exported?.schema !== 'codeburn.export.v2' || !Array.isArray(exported.records)) {
    throw new Error('codeburn export has an unsupported schema')
  }
  const period = codeburnExportPeriod(exported)
  if (period.calls !== exported.records.length) {
    throw new Error('codeburn export summary calls disagree with its record ledger')
  }
  const exportHash = crypto.createHash('sha256').update(exportText).digest('hex')
  const raw = readRawCapture(options.rawFile, [])
  const latest = new Map()
  for (const row of raw.rows) latest.set(row.task, row)
  const byExactWorktree = new Map()
  const byWorktree = new Map()
  for (const row of latest.values()) {
    const startedAt = canonicalTimestamp(row.started_at)
    const endedAt = validatedLifecycleTimestamp(row.ended_at, startedAt)
    if (!startedAt || !endedAt || !row.worktree || !row.project) continue
    const start = Date.parse(startedAt)
    const end = Date.parse(endedAt)
    if (end < period.start || start >= period.endExclusive) continue
    const completeCoverage = start >= period.start && end <= period.endExclusive
    const missingCoverage = []
    if (start < period.start) {
      missingCoverage.push(`[${startedAt}, ${new Date(period.start).toISOString()})`)
    }
    if (end > period.endExclusive) {
      missingCoverage.push(`[${new Date(period.endExclusive).toISOString()}, ${endedAt}]`)
    }
    const task = {...row, started_at: startedAt, ended_at: endedAt, start, end,
      completeCoverage, missingCoverage}
    const exactWorktree = slashNormalizedObservedPath(row.worktree)
    if (!byExactWorktree.has(exactWorktree)) byExactWorktree.set(exactWorktree, [])
    byExactWorktree.get(exactWorktree).push(task)
    const worktree = normalizedObservedPath(row.worktree)
    if (!byWorktree.has(worktree)) byWorktree.set(worktree, [])
    byWorktree.get(worktree).push(task)
  }

  const classifications = new Map([
    ['outside-task-window', {records: 0, cost_usd: 0}],
    ['unmapped-worktree', {records: 0, cost_usd: 0}],
    ['ambiguous-worktree-key', {records: 0, cost_usd: 0}],
    ['ambiguous-task-window', {records: 0, cost_usd: 0}],
    ['incomplete-export-window', {records: 0, cost_usd: 0, missing: new Set()}],
  ])
  const assigned = new Map()
  const number = (value, label, {integer = false} = {}) => {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0
        || (integer && !Number.isSafeInteger(value))) {
      throw new Error(`codeburn export record has invalid ${label}`)
    }
    return value
  }
  for (const record of exported.records) {
    const timestampText = typeof record?.timestamp === 'string' ? record.timestamp : ''
    const timestamp = Date.parse(timestampText)
    const projectKey = typeof record?.project === 'string' ? record.project : ''
    const provider = typeof record?.provider === 'string' ? record.provider.trim() : ''
    const model = typeof record?.model === 'string' ? record.model.trim() : ''
    const session = typeof record?.sessionId === 'string' ? record.sessionId : ''
    const canonicalRecordTimestamp = Number.isFinite(timestamp)
      ? new Date(timestamp).toISOString() : ''
    const expectedTimestamp = timestampText.includes('.')
      ? canonicalRecordTimestamp : canonicalRecordTimestamp.replace('.000Z', 'Z')
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(timestampText)
        || !Number.isFinite(timestamp) || expectedTimestamp !== timestampText
        || timestamp < period.start || timestamp >= period.endExclusive
        || !projectKey || !provider || !model || !session) {
      throw new Error('codeburn export record has invalid identity or period')
    }
    const values = {
      input_tokens: number(record.inputTokens, 'input tokens', {integer: true}),
      output_tokens: number(record.outputTokens, 'output tokens', {integer: true}),
      reasoning_tokens: number(record.reasoningTokens, 'reasoning tokens', {integer: true}),
      cache_read_tokens: number(record.cacheReadTokens, 'cache-read tokens', {integer: true}),
      cache_write_tokens: number(record.cacheWriteTokens, 'cache-write tokens', {integer: true}),
      cost_usd: number(record.cost, 'cost'),
    }
    const exactWorktreeTasks = byExactWorktree.get(slashNormalizedObservedPath(projectKey)) || []
    const worktreeTasks = exactWorktreeTasks.length > 0
      ? exactWorktreeTasks
      : (byWorktree.get(normalizedObservedPath(projectKey)) || [])
    const matches = worktreeTasks.filter(task => timestamp >= task.start && timestamp <= task.end)
    const distinctWorktrees = new Set(worktreeTasks.map(task => task.worktree))
    let reason
    if (worktreeTasks.length === 0) reason = 'unmapped-worktree'
    else if (distinctWorktrees.size > 1) reason = 'ambiguous-worktree-key'
    else if (matches.length === 0) reason = 'outside-task-window'
    else if (matches.length > 1) reason = 'ambiguous-task-window'
    else if (!matches[0].completeCoverage) reason = 'incomplete-export-window'
    if (reason) {
      const classified = classifications.get(reason)
      classified.records += 1
      classified.cost_usd += values.cost_usd
      if (reason === 'incomplete-export-window') {
        classified.missing.add(`${matches[0].task}: ${matches[0].missingCoverage.join(', ')}`)
      }
      continue
    }
    const task = matches[0]
    if (!assigned.has(task.task)) {
      assigned.set(task.task, {
        task,
        records: 0,
        sessions: new Set(),
        projectKeys: new Set(),
        input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        cost_usd: 0,
        models: new Map(),
      })
    }
    const aggregation = assigned.get(task.task)
    aggregation.records += 1
    aggregation.sessions.add(session)
    aggregation.projectKeys.add(projectKey)
    for (const [key, value] of Object.entries(values)) aggregation[key] += value
    const identity = `${provider}${KEY_SEPARATOR}${model}`
    if (!aggregation.models.has(identity)) {
      aggregation.models.set(identity, {
        provider,
        name: model,
        calls: 0,
        input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        cost_usd: 0,
      })
    }
    const modelAggregation = aggregation.models.get(identity)
    modelAggregation.calls += 1
    for (const [key, value] of Object.entries(values)) modelAggregation[key] += value
  }
  const plans = [...assigned.values()].map(aggregation =>
    planBackfillSnapshot(options, aggregation.task, aggregation, exportHash, replaceExisting))
  for (const plan of plans) applyBackfillSnapshot(plan)
  return {
    period: period.label,
    exportHash,
    assigned,
    classifications,
    records: exported.records.length,
    cost_usd: exported.records.reduce((total, record) => total + record.cost, 0),
    summary_cost_usd: period.cost_usd,
  }
}

// --- reporting -------------------------------------------------------------

function durationText(seconds) {
  if (seconds === null || seconds === undefined) return '-'
  const total = Math.max(0, Number(seconds))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const remainder = Math.floor(total % 60)
  return `${hours > 0 ? `${hours}h ` : ''}${minutes}m ${remainder}s`
}

function storeCurrent(options) {
  if (!fs.existsSync(options.dbPath)) return false
  let db
  try {
    db = new DatabaseSync(options.dbPath, {readOnly: true})
    const digest = db.prepare("SELECT value FROM store_meta WHERE key = 'raw_digest'").get()?.value
    const schema = db.prepare("SELECT value FROM store_meta WHERE key = 'schema_version'").get()?.value
    // A store published by an older schema is stale even with an unchanged raw
    // layer: its task table lacks the newer columns a report reads.
    return schema === SCHEMA_VERSION && digest === rawDigest(readTextFile(options.rawFile))
  } catch {
    return false
  } finally {
    db?.close()
  }
}

function pendingReport(options) {
  const queueKey = crypto.createHash('sha256').update(path.resolve(options.dbPath)).digest('hex')
  const queue = path.join(options.stateDir, `.effort-queue-${queueKey}`)
  let queued = false
  try { queued = fs.readdirSync(queue).some(name => name.startsWith('request.')) } catch { /* No queue yet. */ }
  if (!queued && storeCurrent(options)) return null
  const rows = readRawCapture(options.rawFile, []).rows
  const ids = [...new Set(rows.map(row => row.task))].sort()
    .filter(id => !options.taskId || id === options.taskId)
  if (!ids.length) return null
  return 'Store behind append log or queued evidence; pending ingestion. Run report --sync to wait.\n'
    + `${REPORT_HEADER}\n`
    + ids.map(id => `${id} | - | - | - | - | pending ingestion | - | - | - | -`).join('\n') + '\n'
}

const REPORT_HEADER = 'TASK | LAUNCH->PR | COST | TOKENS | ACTUAL MODEL | OUTCOME | CONTEXT | USAGE | CLASSES (tok est) | CI'

const seconds = value => (value === null ? '-' : String(Math.round(Number(value) * 1000) / 1000))
const minutes = value => (value === null || value === undefined ? '-' : (Number(value) / 60).toFixed(1))
const minutesPerCard = (runnerSeconds, cards) =>
  (cards === null || cards === undefined || Number(cards) <= 0 ? '-' : (Number(runnerSeconds) / 60 / Number(cards)).toFixed(2))

// The CI column: runner and queue minutes, the run outcomes, how the PR
// landed, and runner minutes per card the body claims.
function ciColumn(ci) {
  if (!ci) return '-'
  return `${minutes(ci.runner_seconds)} runner min / ${minutes(ci.queue_seconds)} queue min / ${ci.runs} runs (${ci.runs_cancelled} cancelled, ${ci.runs_failed} failed) / ${ci.landing} / ${minutesPerCard(ci.runner_seconds, ci.cards_moved_claimed)} min per card`
}

function taskCiLines(db, row) {
  const ci = db.prepare(`
    SELECT task_ci.*, task.cards_moved_claimed FROM task_ci JOIN task USING (task_id) WHERE task_id = ?
  `).get(row.task_id)
  if (!ci) {
    const source = db.prepare("SELECT detail FROM task_source WHERE task_id = ? AND source = 'ci'").get(row.task_id)
    return [`CI unavailable: ${source?.detail || 'ci source not consulted'}`]
  }
  const lines = [
    `CI runs ${ci.runs} | cancelled ${ci.runs_cancelled} | failed ${ci.runs_failed} | succeeded ${ci.runs_succeeded}`
    + ` | runner ${minutes(ci.runner_seconds)} min | queue ${minutes(ci.queue_seconds)} min`
    + ` | first run ${ci.first_run_created_at ?? '-'} | last completed ${ci.last_run_completed_at ?? '-'}`
    + ` | landing ${ci.landing} | cards claimed ${ci.cards_moved_claimed ?? '-'}`,
  ]
  if (ci.is_train) lines.push(`TRAIN members ${ci.member_count} | ejected ${ci.ejected_count} | fix rounds ${ci.fix_round_count}`)
  return lines
}

// The before/after the ledger exists for: runner minutes per landed card for
// PRs that landed directly and for PRs that landed through a train, then each
// train with its members' minutes and card claims.
function ciAggregateLines(db) {
  const direct = db.prepare(`
    SELECT COUNT(*) AS prs, SUM(runner_seconds) AS runner, SUM(queue_seconds) AS queue, SUM(cards_moved_claimed) AS cards
    FROM task_ci JOIN task USING (task_id) WHERE landing = 'direct' AND is_train = 0
  `).get()
  const trains = db.prepare(`
    SELECT COUNT(*) AS prs, SUM(runner_seconds) AS runner, SUM(queue_seconds) AS queue, SUM(cards_moved_claimed) AS cards
    FROM task_ci JOIN task USING (task_id) WHERE is_train = 1
  `).get()
  const members = db.prepare(`
    SELECT COUNT(*) AS prs, SUM(runner_seconds) AS runner, SUM(queue_seconds) AS queue, SUM(cards_moved_claimed) AS cards
    FROM task_ci JOIN task USING (task_id) WHERE landing LIKE 'train:%'
  `).get()
  if (direct.prs + trains.prs + members.prs === 0) return ['CI no run ledgers captured']
  const cards = (...values) => (values.every(value => value === null) ? null : values.reduce((sum, value) => sum + (value ?? 0), 0))
  const lines = [
    `CI direct ${direct.prs} PRs | ${minutes(direct.runner ?? 0)} runner min | ${minutes(direct.queue ?? 0)} queue min`
    + ` | ${direct.cards ?? '-'} cards claimed | ${minutesPerCard(direct.runner ?? 0, direct.cards)} min per card`,
    `CI train ${trains.prs} trains / ${members.prs} members | ${minutes((trains.runner ?? 0) + (members.runner ?? 0))} runner min`
    + ` (trains ${minutes(trains.runner ?? 0)} + members ${minutes(members.runner ?? 0)})`
    + ` | ${minutes((trains.queue ?? 0) + (members.queue ?? 0))} queue min`
    + ` | ${cards(trains.cards, members.cards) ?? '-'} cards claimed`
    + ` | ${minutesPerCard((trains.runner ?? 0) + (members.runner ?? 0), cards(trains.cards, members.cards))} min per card`,
  ]
  const perTrain = db.prepare(`
    SELECT train.task_id, train.pr_number, train.member_count, train.ejected_count, train.fix_round_count,
      train.runner_seconds, task.cards_moved_claimed,
      (SELECT COUNT(*) FROM task_ci AS m WHERE m.landing = 'train:' || train.pr_number) AS ledgers,
      (SELECT SUM(m.runner_seconds) FROM task_ci AS m WHERE m.landing = 'train:' || train.pr_number) AS member_runner,
      (SELECT SUM(mt.cards_moved_claimed) FROM task_ci AS m JOIN task AS mt USING (task_id)
        WHERE m.landing = 'train:' || train.pr_number) AS member_cards
    FROM task_ci AS train JOIN task USING (task_id)
    WHERE train.is_train = 1
    ORDER BY train.pr_number, train.task_id
  `).all()
  for (const train of perTrain) {
    const trainCards = cards(train.cards_moved_claimed, train.member_cards)
    lines.push(`TRAIN #${train.pr_number} ${train.task_id} | ${train.member_count} members (${train.ejected_count} ejected)`
      + ` | ${train.fix_round_count} fix rounds | train ${minutes(train.runner_seconds)} runner min`
      + ` | members ${minutes(train.member_runner ?? 0)} runner min (${train.ledgers} ledgers)`
      + ` | ${trainCards ?? '-'} cards claimed | ${minutesPerCard(train.runner_seconds + (train.member_runner ?? 0), trainCards)} min per card`)
  }
  return lines
}

// The per-task breakdown under the summary row. Every figure derived from
// bytes says "tok est"; a task with no snapshot says why instead of zeros.
function taskUsageLines(db, row) {
  const lines = []
  const source = db.prepare("SELECT status, detail FROM task_source WHERE task_id = ? AND source = 'tool-usage'").get(row.task_id)
  if (row.turns === null) {
    lines.push(`TOOL USAGE unavailable: ${source?.detail || 'tool-usage source not consulted'}`)
    return lines
  }
  lines.push(`BASE PROMPT ${row.base_prompt_tokens_est} tok est (first request) | TURNS ${row.turns} | TOOL CALLS ${row.tool_calls} | RESULT ${row.tool_result_tokens_est} tok est | OUTPUT ${row.assistant_output_tokens} tok`)
  lines.push('CLASS | CALLS | RESULT TOK EST | WALL S')
  const classes = db.prepare('SELECT tool_class, calls, result_tokens_est, wall_seconds_in_tool FROM task_tool_class WHERE task_id = ?').all(row.task_id)
  for (const cls of sortedBy(classes, c => TOOL_CLASS_ORDER.indexOf(c.tool_class))) {
    lines.push(`${cls.tool_class} | ${cls.calls} | ${cls.result_tokens_est} | ${seconds(cls.wall_seconds_in_tool)}`)
  }
  lines.push('TOOL | CLASS | CALLS | RESULT BYTES | RESULT TOK EST | WALL S')
  const tools = db.prepare('SELECT tool_name, tool_class, calls, result_bytes, result_tokens_est, wall_seconds_in_tool FROM task_tool_usage WHERE task_id = ? ORDER BY result_tokens_est DESC, tool_name, tool_class').all(row.task_id)
  for (const tool of tools) {
    lines.push(`${tool.tool_name} | ${tool.tool_class} | ${tool.calls} | ${tool.result_bytes} | ${tool.result_tokens_est} | ${seconds(tool.wall_seconds_in_tool)}`)
  }
  lines.push('LARGEST RESULTS | RANK | TOOL | CLASS | TOK EST | COMMAND OR INPUT (first 120 chars)')
  for (const result of db.prepare('SELECT rank, tool_name, tool_class, tokens_est, command_or_input_head FROM task_largest_results WHERE task_id = ? ORDER BY rank').all(row.task_id)) {
    lines.push(`${result.rank} | ${result.tool_name} | ${result.tool_class} | ${result.tokens_est} tok est | ${result.command_or_input_head}`)
  }
  const timeline = db.prepare('SELECT turn_index, context_tokens, tool_name, tool_class FROM task_turn_timeline WHERE task_id = ? ORDER BY turn_index').all(row.task_id)
  const at = fraction => timeline[Math.max(1, Math.ceil(timeline.length * fraction)) - 1]
  const sample = turn => (turn.context_tokens === null ? '-' : String(turn.context_tokens))
  const quarters = [0.25, 0.5, 0.75, 1].map(fraction => {
    const turn = at(fraction)
    return `@${Math.round(fraction * 100)}% (turn ${turn.turn_index}) ${sample(turn)}`
  })
  lines.push(`TIMELINE ${timeline.length} turns | ctx@1 ${sample(timeline[0])} | ${quarters.join(' | ')}`)
  // A jump is the growth from one request's prompt to the next, attributed to
  // the turn whose results landed in that next prompt. Compactions shrink the
  // prompt and are not jumps.
  const jumps = []
  for (let index = 0; index + 1 < timeline.length; index += 1) {
    const from = timeline[index]
    const to = timeline[index + 1]
    if (from.context_tokens === null || to.context_tokens === null) continue
    const jump = to.context_tokens - from.context_tokens
    if (jump > 0) jumps.push({jump, from, to})
  }
  jumps.sort((a, b) => b.jump - a.jump || a.from.turn_index - b.from.turn_index)
  lines.push('LARGEST JUMPS | TOK | TURNS | TOOL (CLASS)')
  for (const {jump, from, to} of jumps.slice(0, 5)) {
    const tool = from.tool_name === null ? 'no tool' : `${from.tool_name} (${from.tool_class})`
    lines.push(`+${jump} | turn ${from.turn_index} -> ${to.turn_index} | ${tool}`)
  }
  return lines
}

function report(dbPath, taskId) {
  if (!fs.existsSync(dbPath)) return null
  const db = new DatabaseSync(dbPath, {readOnly: true})
  const filter = taskId ? 'WHERE task_id = ?' : ''
  const statement = db.prepare(`
    SELECT task_id, launch_to_pr_seconds, notional_cost_usd, tokens_in, tokens_out,
      outcome, peak_context_tokens, compactions, restarts,
      turns, tool_calls, tool_result_tokens_est, assistant_output_tokens, base_prompt_tokens_est,
      (SELECT group_concat(model, ', ') FROM (
        SELECT model FROM task_model WHERE task_model.task_id = task.task_id ORDER BY provider, model
      )) AS actual_models,
      (SELECT group_concat(tool_class || ' ' || result_tokens_est, ', ') FROM (
        SELECT tool_class, result_tokens_est FROM task_tool_class WHERE task_tool_class.task_id = task.task_id
        ORDER BY CASE tool_class ${TOOL_CLASS_ORDER.map((cls, index) => `WHEN '${cls}' THEN ${index}`).join(' ')} END
      )) AS class_split
    FROM task ${filter}
    ORDER BY task_id
  `)
  const ciStatement = db.prepare(`
    SELECT runner_seconds, queue_seconds, runs, runs_cancelled, runs_failed, landing, cards_moved_claimed
    FROM task_ci JOIN task USING (task_id) WHERE task_id = ?
  `)
  const rows = taskId ? statement.all(taskId) : statement.all()
  const lines = [REPORT_HEADER]
  for (const row of rows) {
    const ci = ciColumn(ciStatement.get(row.task_id) ?? null)
    const cost = row.notional_cost_usd === null ? '-' : `$${Number(row.notional_cost_usd).toFixed(4)}`
    const tokens = row.tokens_in === null || row.tokens_out === null ? '-' : `${row.tokens_in} in / ${row.tokens_out} out`
    const context = row.peak_context_tokens === null || row.compactions === null || row.restarts === null
      ? '-' : `${row.peak_context_tokens} peak / ${row.compactions} compactions / ${row.restarts} restarts`
    const usage = row.turns === null ? '-'
      : `${row.turns} turns / ${row.tool_calls} calls / ${row.tool_result_tokens_est} result tok est / ${row.assistant_output_tokens} out tok / ${row.peak_context_tokens ?? '-'} peak ctx`
    const classes = row.turns === null ? '-' : (row.class_split || 'no tool calls')
    lines.push(`${row.task_id} | ${durationText(row.launch_to_pr_seconds)} | ${cost} | ${tokens} | ${row.actual_models || '-'} | ${row.outcome || '-'} | ${context} | ${usage} | ${classes} | ${ci}`)
  }
  if (taskId) {
    for (const row of rows) lines.push(...taskUsageLines(db, row), ...taskCiLines(db, row))
  }
  if (!taskId) {
    // Outcome by compaction bucket: the correlation the signal exists for. A
    // task with no captured count is its own bucket so an older row never
    // reads as "never compacted".
    const buckets = db.prepare(`
      SELECT CASE WHEN compactions IS NULL THEN 'unknown'
                  WHEN compactions = 0 THEN '0'
                  WHEN compactions = 1 THEN '1'
                  ELSE '2+' END AS bucket,
        COALESCE(outcome, 'none') AS outcome, COUNT(*) AS tasks
      FROM task
      GROUP BY bucket, outcome
      ORDER BY bucket, outcome
    `).all()
    const byBucket = new Map([['0', []], ['1', []], ['2+', []], ['unknown', []]])
    for (const row of buckets) byBucket.get(row.bucket).push(row)
    const bucketText = [...byBucket].map(([bucket, rows]) => {
      const total = rows.reduce((sum, row) => sum + row.tasks, 0)
      const outcomes = rows.map(row => `${row.outcome} ${row.tasks}`).join(', ')
      return `${bucket}: ${total} task${total === 1 ? '' : 's'}${outcomes ? ` (${outcomes})` : ''}`
    })
    lines.push(`COMPACTIONS ${bucketText.join(' | ')}`)
    const aggregate = db.prepare(`
      SELECT COUNT(*) AS tasks,
        COUNT(launch_to_pr_seconds) AS pr_tasks,
        AVG(launch_to_pr_seconds) AS average_pr,
        COUNT(notional_cost_usd) AS cost_tasks,
        SUM(notional_cost_usd) AS cost,
        COUNT(tokens_in) AS token_tasks,
        SUM(tokens_in) AS tokens_in,
        SUM(tokens_out) AS tokens_out
      FROM task
    `).get()
    const cost = aggregate.cost_tasks === 0 ? '-' : `$${Number(aggregate.cost).toFixed(4)}`
    const tokens = aggregate.token_tasks === 0 ? '-' : `${aggregate.tokens_in ?? 0} in / ${aggregate.tokens_out ?? 0} out`
    lines.push(`TOTAL ${aggregate.tasks} tasks | avg ${durationText(aggregate.average_pr)} (${aggregate.pr_tasks} PR) | ${cost} | ${tokens}`)
    lines.push(...ciAggregateLines(db))
    const projects = db.prepare(`
      SELECT project_path, COUNT(*) AS tasks, COUNT(notional_cost_usd) AS measured_tasks,
        SUM(notional_cost_usd) AS cost
      FROM task
      GROUP BY project_path
      ORDER BY project_path IS NULL, project_path
    `).all()
    for (const project of projects) {
      const projectName = project.project_path || '(unassigned)'
      lines.push(`PROJECT ${projectName} | unavailable | ${project.measured_tasks}/${project.tasks} known tasks have cost evidence; historical population completeness is unproven`)
    }
  }
  db.close()
  return `${lines.join('\n')}\n`
}

// --- fingerprint ------------------------------------------------------------
//
// A canonical dump rather than the file bytes: SQLite is free to lay pages out
// differently for identical logical content, and it is the content the rebuild
// contract is about.

function fingerprint(dbPath) {
  if (!fs.existsSync(dbPath)) return null
  const db = new DatabaseSync(dbPath, {readOnly: true})
  const hash = crypto.createHash('sha256')
  const tables = db.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
  ).all()
  for (const {name} of tables) {
    hash.update(['table', name].join(KEY_SEPARATOR) + '\n')
    const columns = db.prepare(`PRAGMA table_info(${name})`).all().map(column => column.name)
    hash.update(['columns', ...columns].join(KEY_SEPARATOR) + '\n')
    const order = columns.map(column => `"${column}"`).join(', ')
    for (const row of db.prepare(`SELECT * FROM ${name} ORDER BY ${order}`).all()) {
      hash.update(columns.map(column => (row[column] === null ? NULL_MARKER : String(row[column]))).join(KEY_SEPARATOR))
      hash.update('\n')
    }
  }
  db.close()
  return hash.digest('hex')
}

// --- annotate ---------------------------------------------------------------

function annotate(file, record) {
  fs.mkdirSync(path.dirname(file), {recursive: true})
  const existing = readTextFile(file)
  const prefix = existing !== null && existing !== '' && !existing.endsWith('\n') ? '\n' : ''
  fs.appendFileSync(file, `${prefix}${JSON.stringify(record)}\n`)
}

// --- annotation arguments ---------------------------------------------------
//
// Values are recorded exactly as given. Nothing here infers a round reason or a
// failure mode from any other field: the whole point of these two is that they
// are answers, not measurements.

const TEXT_FLAGS = {
  '--title': 'title',
  '--branch': 'branch',
  '--pr-url': 'pr_url',
  '--backend': 'backend',
  '--project': 'project',
  '--kind': 'kind',
}

function parseAnnotation(taskId, argv) {
  const record = {task: taskId}
  const rounds = []
  const commits = []
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i]
    const value = argv[i + 1]
    const needsValue = () => {
      if (value === undefined) throw new Error(`${flag} needs a value`)
      i += 1
      return value
    }
    if (flag === '--failure-mode') {
      const mode = needsValue()
      if (!FAILURE_MODES.has(mode)) throw new Error("--failure-mode must be 'loudly' or 'quietly'")
      record.failure_mode = mode
    } else if (flag === '--round') {
      // <index>:<reason>[:<note>] - the note may itself contain colons.
      const spec = needsValue()
      const first = spec.indexOf(':')
      const second = spec.indexOf(':', first + 1)
      if (first < 0) throw new Error('--round needs <n>:<discovery|churn>[:<note>]')
      const index = Number(spec.slice(0, first))
      const reason = second < 0 ? spec.slice(first + 1) : spec.slice(first + 1, second)
      const note = second < 0 ? undefined : spec.slice(second + 1)
      if (!Number.isInteger(index) || index < 1) throw new Error('--round index must be a positive integer')
      if (!ROUND_REASONS.has(reason)) throw new Error("--round reason must be 'discovery' or 'churn'")
      rounds.push(note === undefined ? {round: index, reason} : {round: index, reason, note})
    } else if (flag === '--commit') {
      commits.push(needsValue())
    } else if (flag === '--reverted') {
      const reverted = needsValue()
      if (reverted !== 'yes' && reverted !== 'no') throw new Error("--reverted must be 'yes' or 'no'")
      record.reverted = reverted === 'yes' ? 1 : 0
    } else if (TEXT_FLAGS[flag] !== undefined) {
      record[TEXT_FLAGS[flag]] = needsValue()
    } else {
      throw new Error(`unknown annotation option '${flag}'`)
    }
  }
  if (rounds.length > 0) record.round_reasons = sortedBy(rounds, round => String(round.round).padStart(6, '0'))
  if (commits.length > 0) record.commits = commits
  return record
}

// --- entry point ------------------------------------------------------------

const [command, configPath, argvPath] = process.argv.slice(2)
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))
const argv = argvPath && fs.existsSync(argvPath)
  ? fs.readFileSync(argvPath, 'utf8').split('\0').slice(0, -1)
  : []

if (command === 'rebuild' || command === 'ingest') {
  config.fullRebuild = command === 'rebuild'
  if (argv.length > 0) {
    warn(`rebuild takes no extra arguments; got '${argv[0]}'`)
    process.exit(2)
  }
  const result = rebuild(config)
  process.stdout.write(`rebuilt ${result.tasks} tasks into ${config.dbPath}\n`)
  if (result.issues > 0) {
    process.stdout.write(`${result.issues} ingest issues recorded in ingest_issue\n`)
  }
} else if (command === 'current') {
  process.exit(storeCurrent(config) ? 0 : 1)
} else if (command === 'fingerprint') {
  const value = fingerprint(config.dbPath)
  if (value === null) {
    warn('no store to fingerprint; run rebuild first')
    process.exit(1)
  }
  process.stdout.write(`${value}\n`)
} else if (command === 'backfill-codeburn') {
  let result
  try {
    result = backfillCodeburn(config, argv)
  } catch (error) {
    warn(error.message)
    process.exit(2)
  }
  const attributedRecords = [...result.assigned.values()]
    .reduce((total, aggregation) => total + aggregation.records, 0)
  const attributedCost = [...result.assigned.values()]
    .reduce((total, aggregation) => total + aggregation.cost_usd, 0)
  process.stdout.write(`codeburn export ${result.period}: ${result.records} calls / $${result.summary_cost_usd.toFixed(4)} summary\n`)
  process.stdout.write(`record ledger: ${result.records} records / $${result.cost_usd.toFixed(4)}; per-record rounding delta $${(result.cost_usd - result.summary_cost_usd).toFixed(4)}\n`)
  process.stdout.write(`attributed ${attributedRecords} records / $${attributedCost.toFixed(4)} to ${result.assigned.size} tasks\n`)
  for (const [kind, summary] of result.classifications) {
    process.stdout.write(`${kind}: ${summary.records} records / $${summary.cost_usd.toFixed(4)}\n`)
    if (kind === 'incomplete-export-window') {
      for (const missing of summary.missing) process.stdout.write(`  missing coverage ${missing}\n`)
    }
  }
  process.stdout.write(`export sha256: ${result.exportHash}\n`)
  const rebuilt = rebuild(config)
  process.stdout.write(`rebuilt ${rebuilt.tasks} tasks into ${config.dbPath}\n`)
  if (rebuilt.issues > 0) process.stdout.write(`${rebuilt.issues} ingest issues recorded in ingest_issue\n`)
} else if (command === 'annotate') {
  let record
  try {
    record = parseAnnotation(config.taskId, argv)
  } catch (error) {
    warn(error.message)
    process.exit(2)
  }
  annotate(config.annotationsFile, record)
  process.stdout.write(`recorded ${config.taskId} in ${config.annotationsFile}\n`)
} else if (command === 'capture') {
  try {
    capture(config, config.taskId, argv)
  } catch (error) {
    warn(error.message)
    process.exit(2)
  }
  process.stdout.write(`captured ${config.taskId}; ingestion queued by lifecycle entry point\n`)
} else if (command === 'capture-ci') {
  let outcome
  try {
    outcome = captureCi(config, config.taskId, argv)
  } catch (error) {
    warn(error.message)
    process.exit(2)
  }
  if (outcome.captured.length > 0) {
    process.stdout.write(`captured run ledger for ${outcome.captured.join(', ')}; ingestion queued by lifecycle entry point\n`)
  }
  if (outcome.kept.length > 0) process.stdout.write(`kept existing run ledger for ${outcome.kept.join(', ')}; pass --replace-existing to read it again\n`)
  if (outcome.skipped.length > 0) process.stdout.write(`kept existing member ledgers: ${outcome.skipped.join(', ')}\n`)
  for (const failure of outcome.failed) process.stdout.write(`member not captured ${failure.task}: ${failure.reason}\n`)
} else if (command === 'backfill-ci') {
  let outcome
  try {
    outcome = backfillCi(config, argv)
  } catch (error) {
    warn(error.message)
    process.exit(2)
  }
  process.stdout.write(`run ledgers: captured ${outcome.captured.length} | skipped ${outcome.skippedExisting.length} existing`
    + ` | skipped ${outcome.skippedNotLanded.length} not landed | failed ${outcome.failed.length}\n`)
  for (const failure of outcome.failed) process.stdout.write(`failed ${failure.task}: ${failure.reason}\n`)
  const rebuilt = rebuild(config)
  process.stdout.write(`rebuilt ${rebuilt.tasks} tasks into ${config.dbPath}\n`)
  if (rebuilt.issues > 0) process.stdout.write(`${rebuilt.issues} ingest issues recorded in ingest_issue\n`)
} else if (command === 'report') {
  const output = pendingReport(config) ?? report(config.dbPath, config.taskId)
  if (output === null) {
    warn('no store to report; lifecycle capture or rebuild has not run yet')
    process.exit(1)
  }
  if (config.taskId && output.split('\n').filter(Boolean).length === 1) {
    warn(`task '${config.taskId}' is absent from the effort store`)
    process.exit(1)
  }
  process.stdout.write(output)
} else {
  warn(`unknown internal command '${command}'`)
  process.exit(2)
}
