#!/usr/bin/env node
// Ingestion and schema for the derived agentic-effort store.
//
// This module owns the derived layer only. The raw layer -
// data/cost-attribution.tsv, appended at teardown by bin/fm-teardown.sh - is
// irreplaceable and is never written here. Everything in the database is
// recomputed from three joined sources plus one recorded-by-hand source, so the
// file is safe to delete at any time and `rebuild` restores it exactly.
//
//   raw         data/cost-attribution.tsv       identity, dispatch axes, window
//   codeburn    codeburn export --format json   effort tokens and notional cost
//   git         the project clone               structure, time, durability
//   annotation  data/effort-annotations.jsonl   the posterior nobody can derive
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
// Determinism: no wall-clock value is ever written to the database, so two
// rebuilds over the same inputs produce identical content and `fingerprint`
// can prove it.
//
// bin/fm-effort-store.sh is the entry point and owns the CLI contract; run it
// with --help. This file is invoked by that script and not directly.

const IDLE_GAP_SECONDS = 300
const SCHEMA_VERSION = 'fm-effort-store.v1'
const CLASSIFIER_VERSION = 'fm-effort-classifier.v1'
const V2_MARKER = '# schema=firstmate-effort-attribution-v2'
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
const os = await import('node:os')
const crypto = await import('node:crypto')
const { spawnSync } = await import('node:child_process')

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
// the row. bin/fm-teardown.sh's header owns that contract; this is its inverse.
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

function git(repo, args, {timeoutMs = 20000} = {}) {
  const result = spawnSync('git', ['-C', repo, ...args], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    timeout: timeoutMs,
  })
  if (result.error || result.status !== 0) return null
  return result.stdout
}

// --- source 1: the raw capture ---------------------------------------------
//
// The file is a sequence of sections, each opened by its own `# schema=` line.
// Only the v2 join section is parseable here; a preserved-legacy section or a
// hand-written region above the first marker carries an unknown schema, so its
// lines are surfaced as issues instead of being coerced into a shape they may
// not have.

function readRawCapture(file, issues) {
  const text = readTextFile(file)
  if (text === null) {
    // An empty store and an unreadable raw layer look the same from the outside,
    // so say which one happened.
    issues.push({source: 'raw', task_id: null, kind: 'capture-unreadable', detail: file})
    return {rows: []}
  }
  const rows = []
  let section = 'legacy'
  let columns = null
  for (const line of text.split('\n')) {
    if (line === '') continue
    if (line.startsWith('# schema=')) {
      section = line.trim() === V2_MARKER ? 'v2' : 'legacy'
      columns = null
      continue
    }
    if (section !== 'v2') {
      issues.push({source: 'raw', task_id: null, kind: 'unparsed-legacy-line', detail: line})
      continue
    }
    const fields = line.split('\t').map(unescapeRawValue)
    if (columns === null) {
      if (fields[0] === 'task' && fields[1] === 'worktree') {
        columns = fields
        continue
      }
      issues.push({source: 'raw', task_id: null, kind: 'v2-row-before-header', detail: line})
      continue
    }
    if (fields.length !== columns.length) {
      issues.push({source: 'raw', task_id: fields[0] || null, kind: 'v2-column-count', detail: line})
      continue
    }
    const row = {}
    columns.forEach((name, index) => { row[name] = fields[index] })
    if (!row.task) {
      issues.push({source: 'raw', task_id: null, kind: 'v2-row-without-task', detail: line})
      continue
    }
    rows.push(row)
  }
  return {rows}
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

// --- source 2: codeburn ----------------------------------------------------
//
// One export covers every task window; per-record timestamps then window each
// task exactly, which is what makes a pooled worktree attributable to the task
// that actually held it. Matching is tiered because codeburn's project key is
// not always the literal worktree path: it can drop the leading separator and
// re-split a directory name that contains a dash. A tier is only allowed to
// match when it maps to exactly one codeburn project, so an ambiguous
// normalization records missing rather than attributing spend to a guess.

function normalizeProjectKey(value) {
  return value.replace(/^\/+/, '').replace(/[-/_]+/g, '/').replace(/\/+$/, '').toLowerCase()
}

function runCodeburn(from, to, timeoutSeconds) {
  const bin = process.env.FM_CODEBURN_BIN || 'codeburn'
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fm-effort-store-'))
  const outFile = path.join(outDir, 'codeburn.json')
  try {
    const result = spawnSync(bin, [
      '--timezone', 'UTC', 'export', '--format', 'json',
      '--from', from, '--to', to, '-o', outFile,
    ], {encoding: 'utf8', timeout: timeoutSeconds * 1000, maxBuffer: 16 * 1024 * 1024})
    if (result.error || result.status !== 0) {
      return {ok: false, detail: `codeburn export failed (${result.error ? result.error.code : `exit ${result.status}`})`}
    }
    const text = readTextFile(outFile)
    if (text === null) return {ok: false, detail: 'codeburn export produced no file'}
    return {ok: true, data: JSON.parse(text)}
  } catch (error) {
    return {ok: false, detail: `codeburn export unreadable: ${error.message}`}
  } finally {
    fs.rmSync(outDir, {recursive: true, force: true})
  }
}

function indexCodeburnRecords(records) {
  const byProject = new Map()
  const byNormalized = new Map()
  for (const record of records) {
    const project = typeof record.project === 'string' ? record.project : ''
    if (!project) continue
    if (!byProject.has(project)) byProject.set(project, [])
    byProject.get(project).push(record)
    const normalized = normalizeProjectKey(project)
    if (!byNormalized.has(normalized)) byNormalized.set(normalized, new Set())
    byNormalized.get(normalized).add(project)
  }
  for (const list of byProject.values()) {
    list.sort((a, b) => String(a.timestamp).localeCompare(String(b.timestamp)))
  }
  return {byProject, byNormalized}
}

function matchCodeburnProject(index, worktree) {
  if (index.byProject.has(worktree)) return {project: worktree, match: 'exact'}
  const normalized = normalizeProjectKey(worktree)
  const candidates = index.byNormalized.get(normalized)
  if (!candidates || candidates.size === 0) return {project: null, match: 'none'}
  if (candidates.size > 1) return {project: null, match: 'ambiguous'}
  return {project: [...candidates][0], match: 'normalized'}
}

// Active time is the walked span with idle stretches removed, so a task left
// parked overnight does not read as an overnight of effort.
function summarizeCodeburnRecords(records) {
  const totals = {
    tokens_in: 0, tokens_out: 0, tokens_reasoning: 0,
    tokens_cached_read: 0, tokens_cached_write: 0,
    notional_cost_usd: 0, api_calls: 0, agent_active_seconds: 0,
  }
  const models = new Map()
  let previous = null
  for (const record of records) {
    totals.tokens_in += Number(record.inputTokens || 0)
    totals.tokens_out += Number(record.outputTokens || 0)
    totals.tokens_reasoning += Number(record.reasoningTokens || 0)
    totals.tokens_cached_read += Number(record.cacheReadTokens || 0)
    totals.tokens_cached_write += Number(record.cacheWriteTokens || 0)
    totals.notional_cost_usd += Number(record.cost || 0)
    totals.api_calls += 1
    const at = Date.parse(record.timestamp)
    if (previous !== null && Number.isFinite(at)) {
      const gap = (at - previous) / 1000
      if (gap > 0 && gap <= IDLE_GAP_SECONDS) totals.agent_active_seconds += gap
    }
    if (Number.isFinite(at)) previous = at
    const key = [record.provider || '', record.model || ''].join(KEY_SEPARATOR)
    if (!models.has(key)) {
      models.set(key, {
        provider: record.provider || '', model: record.model || '',
        tokens_in: 0, tokens_out: 0, tokens_reasoning: 0,
        tokens_cached_read: 0, tokens_cached_write: 0,
        notional_cost_usd: 0, api_calls: 0,
      })
    }
    const model = models.get(key)
    model.tokens_in += Number(record.inputTokens || 0)
    model.tokens_out += Number(record.outputTokens || 0)
    model.tokens_reasoning += Number(record.reasoningTokens || 0)
    model.tokens_cached_read += Number(record.cacheReadTokens || 0)
    model.tokens_cached_write += Number(record.cacheWriteTokens || 0)
    model.notional_cost_usd += Number(record.cost || 0)
    model.api_calls += 1
  }
  totals.agent_active_seconds = Math.round(totals.agent_active_seconds)
  totals.notional_cost_usd = Math.round(totals.notional_cost_usd * 1e6) / 1e6
  for (const model of models.values()) {
    model.notional_cost_usd = Math.round(model.notional_cost_usd * 1e6) / 1e6
  }
  return {totals, models: sortedBy([...models.values()], m => [m.provider, m.model].join(KEY_SEPARATOR))}
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
      if (!ref.endsWith(`/${branch}`) && !ref.includes(taskId)) continue
      const args = ['rev-list', ref]
      if (defaultTip) args.push(`^${defaultTip.sha}`)
      const list = git(repo, args)
      if (!list) continue
      for (const sha of list.split('\n').filter(Boolean)) add(sha, 'branch-ref')
    }
  }

  for (const commit of commits.values()) {
    const haystack = `${commit.subject}\n${commit.body}`
    if (haystack.includes(branch) || haystack.includes(taskId)) add(commit.sha, 'commit-message')
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
  merged_at           TEXT,
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
  outcome             TEXT CHECK (outcome IN ('merged', 'abandoned')),
  reverted            INTEGER CHECK (reverted IN (0, 1))
);

-- Which sources were consulted for each task and what came back. A task absent
-- from a source is recorded here, never dropped from the store.
CREATE TABLE task_source (
  task_id TEXT NOT NULL,
  source  TEXT NOT NULL CHECK (source IN ('raw', 'codeburn', 'git', 'annotation')),
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
  tokens_in           INTEGER NOT NULL,
  tokens_out          INTEGER NOT NULL,
  tokens_reasoning    INTEGER NOT NULL,
  tokens_cached_read  INTEGER NOT NULL,
  tokens_cached_write INTEGER NOT NULL,
  notional_cost_usd   REAL NOT NULL,
  api_calls           INTEGER NOT NULL,
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

// --- rebuild ----------------------------------------------------------------

function isoSecondsBetween(from, to) {
  const a = Date.parse(from)
  const b = Date.parse(to)
  if (!Number.isFinite(a) || !Number.isFinite(b)) return null
  return Math.max(0, Math.round((b - a) / 1000))
}

function rebuild(options) {
  const issues = []
  const raw = readRawCapture(options.rawFile, issues)
  const annotations = readAnnotations(options.annotationsFile, issues)

  // A task can enter the store from the raw layer or from an annotation alone,
  // so work that never reached teardown is still visible as a task with its raw
  // source recorded missing.
  const taskIds = new Set([...raw.rows.map(row => row.task), ...annotations.byTask.keys()])
  const rawByTask = new Map()
  for (const row of raw.rows) {
    const existing = rawByTask.get(row.task)
    // Repeated ids can only come from a reused id; the latest window wins and
    // the superseded one is surfaced rather than silently discarded.
    if (existing) {
      issues.push({source: 'raw', task_id: row.task, kind: 'duplicate-task-row', detail: `${existing.started_at || ''}..${existing.ended_at || ''}`})
    }
    rawByTask.set(row.task, row)
  }

  const tasks = sortedBy([...taskIds], id => id).map(taskId => ({
    taskId,
    raw: rawByTask.get(taskId) || null,
    annotation: annotations.byTask.get(taskId) || null,
  }))

  const codeburn = collectCodeburn(tasks, options, issues)
  const gitResults = collectGit(tasks, options, issues)

  const db = createDatabase(options.dbPath)
  db.exec('BEGIN')
  try {
    const metaInsert = insert(db, 'store_meta', ['key', 'value'])
    for (const [key, value] of [
      ['schema_version', SCHEMA_VERSION],
      ['classifier_version', CLASSIFIER_VERSION],
      ['idle_gap_seconds', String(IDLE_GAP_SECONDS)],
    ]) metaInsert.run(key, value)

    writeTasks(db, tasks, codeburn, gitResults)
    writeDurability(db, gitResults)
    writeIssues(db, issues)
    db.exec('COMMIT')
  } catch (error) {
    db.exec('ROLLBACK')
    db.close()
    throw error
  }
  db.close()

  return {tasks: tasks.length, issues: issues.length}
}

function collectCodeburn(tasks, options, issues) {
  const windows = tasks.map(task => task.raw).filter(Boolean)
    .map(row => [row.started_at, row.ended_at]).flat().filter(Boolean)
    .map(value => String(value).slice(0, 10)).filter(value => /^\d{4}-\d{2}-\d{2}$/.test(value))
  if (windows.length === 0) {
    return {available: false, detail: 'no dated task windows in the raw capture', index: null}
  }
  const from = windows.reduce((a, b) => (a < b ? a : b))
  const to = windows.reduce((a, b) => (a > b ? a : b))
  const result = runCodeburn(from, to, options.codeburnTimeoutSeconds)
  if (!result.ok) {
    issues.push({source: 'codeburn', task_id: null, kind: 'export-unavailable', detail: result.detail})
    return {available: false, detail: result.detail, index: null}
  }
  const records = Array.isArray(result.data?.records) ? result.data.records : null
  if (records === null) {
    const detail = 'codeburn export carried no records array'
    issues.push({source: 'codeburn', task_id: null, kind: 'export-shape', detail})
    return {available: false, detail, index: null}
  }
  return {available: true, detail: null, index: indexCodeburnRecords(records), from, to}
}

function codeburnForTask(codeburn, task) {
  if (!codeburn.available) return {status: 'missing', detail: codeburn.detail}
  const row = task.raw
  if (!row || !row.worktree) return {status: 'missing', detail: 'no worktree recorded in the raw capture'}
  if (!row.started_at || !row.ended_at) return {status: 'missing', detail: 'no task window recorded in the raw capture'}
  const matched = matchCodeburnProject(codeburn.index, row.worktree)
  if (matched.match === 'none') return {status: 'missing', detail: 'no codeburn project matched this worktree'}
  if (matched.match === 'ambiguous') return {status: 'missing', detail: 'more than one codeburn project matched this worktree'}
  const start = Date.parse(row.started_at)
  const end = Date.parse(row.ended_at)
  if (!Number.isFinite(start) || !Number.isFinite(end)) {
    return {status: 'missing', detail: 'unparsable task window in the raw capture'}
  }
  const records = codeburn.index.byProject.get(matched.project)
    .filter(record => {
      const at = Date.parse(record.timestamp)
      return Number.isFinite(at) && at >= start && at <= end
    })
  const summary = summarizeCodeburnRecords(records)
  return {
    status: 'present',
    detail: `${matched.match} project match, ${records.length} records in window`,
    totals: summary.totals,
    models: summary.models,
  }
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

function writeTasks(db, tasks, codeburn, gitResults) {
  const taskInsert = insert(db, 'task', [
    'task_id', 'title', 'repo', 'project_path', 'kind', 'branch', 'pr_url',
    'harness', 'model', 'effort', 'backend', 'worktree', 'dispatched_at',
    'started_at', 'ended_at', 'wall_clock_seconds', 'agent_active_seconds',
    'first_commit_at', 'pr_opened_at', 'merged_at',
    'files_changed', 'prod_src_files', 'distinct_areas', 'adds', 'dels',
    'import_in_degree', 'import_out_degree',
    'findings', 'review_rounds', 'ask_user_count', 'gate_failures', 'failure_mode',
    'tokens_in', 'tokens_out', 'tokens_reasoning', 'tokens_cached_read',
    'tokens_cached_write', 'notional_cost_usd', 'api_calls',
    'outcome', 'reverted',
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
    const burn = codeburnForTask(codeburn, task)
    const gitResult = gitResults.results.get(task.taskId) || {status: 'missing', detail: 'git source not consulted'}
    const structure = gitResult.status === 'present' ? gitResult.structure : null
    const totals = burn.status === 'present' ? burn.totals : null

    taskInsert.run(
      task.taskId,
      bind(annotation?.title),
      bind(gitResult.status === 'present' ? gitResult.repo : null),
      bind(row?.project),
      bind(row?.kind ?? annotation?.kind),
      bind(annotation?.branch),
      bind(annotation?.pr_url),
      bind(row?.harness),
      bind(row?.model),
      bind(row?.effort),
      bind(annotation?.backend),
      bind(row?.worktree),
      bind(row?.started_at),
      bind(row?.started_at),
      bind(row?.ended_at),
      bind(row?.started_at && row?.ended_at ? isoSecondsBetween(row.started_at, row.ended_at) : null),
      bind(totals ? totals.agent_active_seconds : null),
      bind(gitResult.status === 'present' ? gitResult.first_commit_at : null),
      bind(annotation?.pr_opened_at),
      bind(annotation?.merged_at ?? (gitResult.status === 'present' ? gitResult.merged_at : null)),
      bind(structure?.files_changed),
      bind(structure?.prod_src_files),
      bind(structure?.distinct_areas),
      bind(structure?.adds),
      bind(structure?.dels),
      bind(structure?.import_in_degree),
      bind(structure?.import_out_degree),
      bind(annotation?.findings),
      bind(annotation?.review_rounds),
      bind(annotation?.ask_user_count),
      bind(annotation?.gate_failures),
      bind(annotation?.failure_mode),
      bind(totals?.tokens_in),
      bind(totals?.tokens_out),
      bind(totals?.tokens_reasoning),
      bind(totals?.tokens_cached_read),
      bind(totals?.tokens_cached_write),
      bind(totals?.notional_cost_usd),
      bind(totals?.api_calls),
      bind(annotation?.outcome ?? (gitResult.status === 'present' ? gitResult.outcome : null)),
      bind(annotation?.reverted ?? (gitResult.status === 'present' ? gitResult.reverted : null)),
    )

    sourceInsert.run(task.taskId, 'raw', row ? 'present' : 'missing',
      row ? null : 'no teardown row in the raw capture')
    sourceInsert.run(task.taskId, 'annotation', annotation ? 'present' : 'missing',
      annotation ? null : 'nothing recorded by hand for this task')
    sourceInsert.run(task.taskId, 'codeburn', burn.status, bind(burn.detail))
    sourceInsert.run(task.taskId, 'git', gitResult.status, bind(gitResult.detail))

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
    if (burn.status === 'present') {
      for (const model of burn.models) {
        modelInsert.run(task.taskId, model.provider, model.model, model.tokens_in,
          model.tokens_out, model.tokens_reasoning, model.tokens_cached_read,
          model.tokens_cached_write, model.notional_cost_usd, model.api_calls)
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

const COUNT_FLAGS = {
  '--findings': 'findings',
  '--review-rounds': 'review_rounds',
  '--ask-user': 'ask_user_count',
  '--gate-failures': 'gate_failures',
}
const TEXT_FLAGS = {
  '--title': 'title',
  '--branch': 'branch',
  '--pr-url': 'pr_url',
  '--backend': 'backend',
  '--pr-opened-at': 'pr_opened_at',
  '--merged-at': 'merged_at',
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
    } else if (flag === '--outcome') {
      const outcome = needsValue()
      if (outcome !== 'merged' && outcome !== 'abandoned') throw new Error("--outcome must be 'merged' or 'abandoned'")
      record.outcome = outcome
    } else if (flag === '--reverted') {
      const reverted = needsValue()
      if (reverted !== 'yes' && reverted !== 'no') throw new Error("--reverted must be 'yes' or 'no'")
      record.reverted = reverted === 'yes' ? 1 : 0
    } else if (COUNT_FLAGS[flag] !== undefined) {
      const count = Number(needsValue())
      if (!Number.isInteger(count) || count < 0) throw new Error(`${flag} needs a non-negative integer`)
      record[COUNT_FLAGS[flag]] = count
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

if (command === 'rebuild') {
  if (argv.length > 0) {
    warn(`rebuild takes no extra arguments; got '${argv[0]}'`)
    process.exit(2)
  }
  const result = rebuild(config)
  process.stdout.write(`rebuilt ${result.tasks} tasks into ${config.dbPath}\n`)
  if (result.issues > 0) {
    process.stdout.write(`${result.issues} ingest issues recorded in ingest_issue\n`)
  }
} else if (command === 'fingerprint') {
  const value = fingerprint(config.dbPath)
  if (value === null) {
    warn('no store to fingerprint; run rebuild first')
    process.exit(1)
  }
  process.stdout.write(`${value}\n`)
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
} else {
  warn(`unknown internal command '${command}'`)
  process.exit(2)
}
