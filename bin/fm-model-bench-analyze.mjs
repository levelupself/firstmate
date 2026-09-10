#!/usr/bin/env node
// fm-model-bench-analyze.mjs - the arithmetic behind bin/fm-model-bench.sh.
//
// Four read-only modes; session, independence, and render print one JSON object
// or one table on stdout, and newest-record prints one path:
//
//   fm-model-bench-analyze.mjs session --harness <codex|claude> --workspace <abs>
//       (--record <file>)... | (--sessions-root <dir> [--launched-at <iso>] [--prior <file>]...)
//       [--milestone <iso>] [--at <iso>]
//
//     Reads an arm's OWN session records and reports the running model, the
//     active working time, and the consumption, all sliced at one point.
//     Every record must carry the arm's exact worktree as its cwd; a record
//     for any other directory is refused (exit 2), never silently dropped,
//     because a wrong match would attribute another worker's numbers to the
//     arm. With --sessions-root the records are discovered under the harness's
//     own layout (codex: <root>/YYYY/MM/DD/rollout-*.jsonl whose session_meta
//     names the workspace; claude: <root>/<workspace with [^A-Za-z0-9] as "-">/
//     *.jsonl whose records name the workspace, plus each matched session's
//     <session>/subagents/*.jsonl sidechain transcripts), skipping any file
//     listed as --prior and any session that began before --launched-at. A
//     sidechain transcript contributes consumption only: its requests are the
//     arm's spend, but its model is reported under sidechain_models rather
//     than deciding confirmation, and it has no turn brackets of its own.
//
//     Active time is the sum of the arm's own turn brackets: codex brackets a
//     turn with event_msg task_started and task_complete|turn_aborted (the
//     close carries duration_ms), and claude closes each turn with a
//     system/turn_duration record (durationMs). Wall clock is reported beside
//     it but never used, so an operator pause, a restart, or a machine outage
//     between turns does not penalise the arm. A turn with no close is
//     reported as open and contributes nothing.
//
//     Consumption comes from the record, never from the worker: codex's
//     cumulative event_msg token_count info.total_token_usage read at the slice,
//     and claude's per-request assistant message.usage summed once per
//     requestId (claude writes one row per content block, all carrying the
//     same usage). The normalised shape is {input, cached_input, cache_write,
//     output, total}: codex input already includes cached input and total is
//     input+output; claude input is input_tokens + cache_creation + cache_read
//     and total is input+output likewise.
//
//     --milestone <iso> is the completion moment (the terminal status line);
//     the slice is the close of the turn that contains it, so the final
//     response of that turn counts and nothing after it does. --at <iso> sets
//     the slice directly. With neither, everything in the records counts.
//
//     model_confirmed is true only when exactly one distinct model appears in
//     the sliced records (codex: turn_context.payload.model; claude:
//     assistant.message.model, ignoring "<synthetic>" rows). The requested
//     model is deliberately not an input here: the caller compares.
//
//   fm-model-bench-analyze.mjs independence <arm>=<dir> [<arm>=<dir>]...
//
//     Byte-compares every file under each arm directory against the same
//     relative path in every other arm. A byte-identical pair means one arm
//     copied the other: the arm whose copy is later (file mtime, which the
//     caller sets to the content's first-appearance time) is void, the earlier
//     one keeps its result and records who copied it, and a tie voids both
//     because nothing orders them. Output: {arms:{<arm>:{files, verdict:
//     "independent"|"void", copied_by:[...], matches:[{path, other, this_at,
//     other_at}]}}, pairs:[...], void_arms:[...]}. Verdicts are data: the exit
//     status is 0 whenever the comparison ran, 2 on a usage error.
//
//   fm-model-bench-analyze.mjs newest-record --harness <codex|claude> --sessions-root <dir>
//
//     Prints the path of the most recently modified session record under the
//     harness's own layout, or nothing (exit 1) when there is none. The reader
//     self-check in bin/fm-model-bench.sh uses it to prove, before any arm
//     launches, that this reader and the records the harness writes on this
//     machine agree.
//
//   fm-model-bench-analyze.mjs render <report.json>
//
//     Prints the comparison table for a fm-model-bench-report.v1 document
//     (written by bin/fm-model-bench.sh report): one row per arm with the
//     requested and confirmed models, active time, tokens, completion state,
//     independence verdict, and branch, then the per-arm source repositories,
//     then a VOID banner for every void arm and a warning block. Numbers for
//     an arm whose model is not confirmed are withheld, not blanked quietly:
//     the row says UNCONFIRMED and the reason follows the table.

import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';

function usage() {
  const src = readFileSync(new URL(import.meta.url), 'utf8').split('\n');
  const lines = [];
  for (const line of src.slice(1)) {
    if (!line.startsWith('//')) break;
    lines.push(line.replace(/^\/\/ ?/, ''));
  }
  return lines.join('\n');
}

function die(message, code = 2) {
  process.stderr.write(`fm-model-bench-analyze: ${message}\n`);
  process.exit(code);
}

function parseIso(value, label) {
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) die(`${label} is not an ISO-8601 timestamp: ${value}`);
  return ms;
}

function iso(ms) {
  return new Date(ms).toISOString();
}

// --- record loading ---------------------------------------------------------

function readJsonl(file) {
  const rows = [];
  const text = readFileSync(file, 'utf8');
  let lineNo = 0;
  for (const line of text.split('\n')) {
    lineNo += 1;
    if (!line.trim()) continue;
    try {
      rows.push(JSON.parse(line));
    } catch {
      // A torn final line is the normal state of a live record; a torn line
      // anywhere else is still not evidence, so both are skipped rather than
      // guessed at. The count is reported so a reader can see it happened.
      rows.push({ __malformed: true, __line: lineNo });
    }
  }
  return rows;
}

function claudeProjectDir(workspace) {
  return workspace.replace(/[^a-zA-Z0-9]/g, '-');
}

function discoverRecords(harness, workspace, root, launchedAtMs, priorSet) {
  const found = [];
  if (harness === 'codex') {
    if (!existsSync(root)) return found;
    const fromDay = launchedAtMs === null ? null : iso(launchedAtMs - 86400000).slice(0, 10).replace(/-/g, '/');
    for (const y of safeList(root)) {
      for (const m of safeList(join(root, y))) {
        for (const d of safeList(join(root, y, m))) {
          const day = `${y}/${m}/${d}`;
          if (fromDay !== null && day < fromDay) continue;
          for (const f of safeList(join(root, y, m, d))) {
            if (!/^rollout-.*\.jsonl$/.test(f)) continue;
            const file = join(root, y, m, d, f);
            if (priorSet.has(file)) continue;
            const first = firstLine(file);
            if (!first || first.type !== 'session_meta') continue;
            const p = first.payload || {};
            if (p.cwd !== workspace || p.originator !== 'codex-tui' || p.source !== 'cli') continue;
            found.push(file);
          }
        }
      }
    }
  } else {
    const encoded = claudeProjectDir(workspace);
    const candidates = [];
    if (existsSync(join(root, encoded))) candidates.push(join(root, encoded));
    // Claude truncates an encoded name past 200 characters and appends a hash
    // this reader cannot reproduce, so a long workspace is matched by prefix
    // and then by the cwd inside each record.
    if (encoded.length > 200) {
      const prefix = encoded.slice(0, 200) + '-';
      for (const d of safeList(root)) {
        if (d.startsWith(prefix)) candidates.push(join(root, d));
      }
    }
    for (const dir of candidates) {
      for (const f of safeList(dir)) {
        if (!f.endsWith('.jsonl')) continue;
        const file = join(dir, f);
        if (priorSet.has(file)) continue;
        if (!statSync(file).isFile()) continue;
        const rows = readJsonl(file);
        const firstCwd = rows.find((r) => r && typeof r.cwd === 'string');
        if (!firstCwd || firstCwd.cwd !== workspace) continue;
        found.push(file);
      }
    }
  }
  let kept = found;
  if (launchedAtMs !== null) {
    kept = found.filter((file) => {
      const start = sessionStartMs(harness, readJsonl(file));
      // A session that began before the arm launched belongs to an earlier
      // occupant of the same directory. One minute of tolerance absorbs clock
      // skew between the record and this host.
      return start === null || start >= launchedAtMs - 60000;
    });
  }
  if (harness === 'claude') {
    const withSidechains = [];
    for (const file of kept) {
      withSidechains.push(file);
      const sub = join(file.slice(0, -'.jsonl'.length), 'subagents');
      for (const f of safeList(sub)) {
        if (!f.endsWith('.jsonl')) continue;
        const sfile = join(sub, f);
        if (priorSet.has(sfile)) continue;
        withSidechains.push(sfile);
      }
    }
    return withSidechains;
  }
  return kept;
}

function safeList(dir) {
  try {
    return readdirSync(dir).sort();
  } catch {
    return [];
  }
}

function firstLine(file) {
  try {
    const text = readFileSync(file, 'utf8');
    const nl = text.indexOf('\n');
    const line = nl === -1 ? text : text.slice(0, nl);
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function sessionStartMs(harness, rows) {
  for (const r of rows) {
    if (!r || r.__malformed) continue;
    if (harness === 'codex' && r.type === 'session_meta') {
      const ms = Date.parse(r.timestamp || (r.payload && r.payload.timestamp) || '');
      return Number.isFinite(ms) ? ms : null;
    }
    if (harness === 'claude' && typeof r.timestamp === 'string') {
      const ms = Date.parse(r.timestamp);
      if (Number.isFinite(ms)) return ms;
    }
  }
  return null;
}

// --- per-harness folds ------------------------------------------------------

// Each fold returns {session_id, cwd, turns:[{started_ms, ended_ms|null,
// duration_ms|null, kind}], usage_points:[{ms, usage}], models:[{ms, model}],
// first_ms, last_ms, malformed}. usage_points are cumulative for codex and
// per-request for claude; the slicer knows which.

function foldCodex(rows, file) {
  const meta = rows.find((r) => r && r.type === 'session_meta');
  if (!meta || !meta.payload) die(`${file}: no session_meta record; not a codex rollout`);
  const cwd = meta.payload.cwd;
  const turns = new Map();
  const order = [];
  const usagePoints = [];
  const models = [];
  let firstMs = null;
  let lastMs = null;
  let malformed = 0;
  for (const r of rows) {
    if (!r) continue;
    if (r.__malformed) { malformed += 1; continue; }
    const ms = Date.parse(r.timestamp || '');
    if (Number.isFinite(ms)) {
      if (firstMs === null || ms < firstMs) firstMs = ms;
      if (lastMs === null || ms > lastMs) lastMs = ms;
    }
    if (r.type === 'turn_context' && r.payload && typeof r.payload.model === 'string') {
      models.push({ ms, model: r.payload.model });
      continue;
    }
    if (r.type !== 'event_msg' || !r.payload || typeof r.payload.type !== 'string') continue;
    const p = r.payload;
    if (p.type === 'task_started') {
      const id = p.turn_id || `anon-${order.length}`;
      const started = Number.isFinite(p.started_at) ? p.started_at * 1000 : ms;
      turns.set(id, { id, started_ms: started, ended_ms: null, duration_ms: null, kind: 'open' });
      order.push(id);
    } else if (p.type === 'task_complete' || p.type === 'turn_aborted') {
      const id = p.turn_id;
      let t = id ? turns.get(id) : null;
      if (!t) {
        // A close with no matching open (a record that began mid-turn) still
        // brackets real work when it carries its own start.
        const started = Number.isFinite(p.started_at) ? p.started_at * 1000 : null;
        if (started === null) continue;
        t = { id: id || `anon-${order.length}`, started_ms: started, ended_ms: null, duration_ms: null, kind: 'open' };
        turns.set(t.id, t);
        order.push(t.id);
      }
      t.ended_ms = Number.isFinite(p.completed_at) ? p.completed_at * 1000 : ms;
      t.duration_ms = Number.isFinite(p.duration_ms) ? p.duration_ms : Math.max(0, t.ended_ms - t.started_ms);
      t.kind = p.type === 'task_complete' ? 'complete' : 'aborted';
      // The close record's own timestamp is what a slice compares against: it
      // is the moment the record says the turn ended.
      t.closed_at_ms = Number.isFinite(ms) ? ms : t.ended_ms;
    } else if (p.type === 'token_count') {
      const total = p.info && p.info.total_token_usage;
      if (!total || !Number.isFinite(ms)) continue;
      usagePoints.push({ ms, usage: normaliseCodexUsage(total) });
    }
  }
  return {
    file,
    session_id: meta.payload.session_id || meta.payload.id || null,
    cwd,
    turns: order.map((id) => turns.get(id)),
    usage_points: usagePoints,
    models,
    first_ms: firstMs,
    last_ms: lastMs,
    malformed,
  };
}

function normaliseCodexUsage(u) {
  const input = num(u.input_tokens);
  const output = num(u.output_tokens);
  return {
    input,
    cached_input: num(u.cached_input_tokens),
    cache_write: num(u.cache_write_input_tokens),
    output,
    reasoning_output: num(u.reasoning_output_tokens),
    total: Number.isFinite(u.total_tokens) ? u.total_tokens : input + output,
  };
}

function num(v) {
  return Number.isFinite(v) ? v : 0;
}

function claudeIsPrompt(r) {
  if (r.type !== 'user' || r.isMeta === true || !r.message) return false;
  const c = r.message.content;
  if (typeof c === 'string') return true;
  if (!Array.isArray(c)) return false;
  if (c.some((b) => b && b.type === 'tool_result')) return false;
  return c.some((b) => b && b.type === 'text');
}

function foldClaude(rows, file) {
  const firstCwd = rows.find((r) => r && typeof r.cwd === 'string');
  if (!firstCwd) die(`${file}: no record carries a cwd; not a claude session transcript`);
  const cwd = firstCwd.cwd;
  const sessionRow = rows.find((r) => r && typeof r.sessionId === 'string');
  // A sidechain (subagent) transcript is the arm's spend but not its turn
  // structure or its running model: every row carries isSidechain true.
  const sidechain = rows.some((r) => r && r.isSidechain === true) && !rows.some((r) => r && r.isSidechain === false);
  const turns = [];
  const usagePoints = [];
  const models = [];
  const seenRequests = new Set();
  let open = null;
  let firstMs = null;
  let lastMs = null;
  let malformed = 0;
  for (const r of rows) {
    if (!r) continue;
    if (r.__malformed) { malformed += 1; continue; }
    const ms = Date.parse(r.timestamp || '');
    if (Number.isFinite(ms)) {
      if (firstMs === null || ms < firstMs) firstMs = ms;
      if (lastMs === null || ms > lastMs) lastMs = ms;
    }
    if (sidechain && (claudeIsPrompt(r) || (r.type === 'system' && r.subtype === 'turn_duration'))) continue;
    if (claudeIsPrompt(r) && Number.isFinite(ms)) {
      if (open) turns.push(open);
      open = { id: r.uuid || `prompt-${turns.length}`, started_ms: ms, ended_ms: null, duration_ms: null, kind: 'open' };
      continue;
    }
    if (r.type === 'system' && r.subtype === 'turn_duration' && Number.isFinite(ms)) {
      const duration = Number.isFinite(r.durationMs) ? r.durationMs : null;
      const t = open || { id: r.uuid || `turn-${turns.length}`, started_ms: duration === null ? ms : ms - duration, ended_ms: null, duration_ms: null, kind: 'open' };
      t.ended_ms = ms;
      t.closed_at_ms = ms;
      t.duration_ms = duration === null ? Math.max(0, ms - t.started_ms) : duration;
      t.kind = 'complete';
      turns.push(t);
      open = null;
      continue;
    }
    if (r.type === 'assistant' && r.message && typeof r.message === 'object') {
      const model = r.message.model;
      if (typeof model !== 'string' || model === '<synthetic>') continue;
      if (Number.isFinite(ms)) models.push({ ms, model });
      const key = r.requestId || r.message.id || r.uuid;
      if (!key || seenRequests.has(key)) continue;
      seenRequests.add(key);
      const u = r.message.usage;
      if (!u || !Number.isFinite(ms)) continue;
      usagePoints.push({ ms, usage: normaliseClaudeUsage(u) });
    }
  }
  if (open) turns.push(open);
  return {
    file,
    session_id: sessionRow ? sessionRow.sessionId : null,
    cwd,
    sidechain,
    turns,
    usage_points: usagePoints,
    models: sidechain ? [] : models,
    sidechain_models: sidechain ? models : [],
    first_ms: firstMs,
    last_ms: lastMs,
    malformed,
  };
}

function normaliseClaudeUsage(u) {
  const fresh = num(u.input_tokens);
  const write = num(u.cache_creation_input_tokens);
  const read = num(u.cache_read_input_tokens);
  const output = num(u.output_tokens);
  const input = fresh + write + read;
  return { input, cached_input: read, cache_write: write, output, reasoning_output: 0, total: input + output };
}

// --- slicing ----------------------------------------------------------------

function zeroUsage() {
  return { input: 0, cached_input: 0, cache_write: 0, output: 0, reasoning_output: 0, total: 0 };
}

function addUsage(a, b) {
  for (const k of Object.keys(a)) a[k] += num(b[k]);
}

function sessionCommand(argv) {
  let harness = null;
  let workspace = null;
  let root = null;
  let launchedAt = null;
  let milestone = null;
  let at = null;
  const records = [];
  const prior = [];
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) die(`${a} requires a value`);
      i += 1;
      return argv[i];
    };
    switch (a) {
      case '--harness': harness = next(); break;
      case '--workspace': workspace = next(); break;
      case '--record': records.push(next()); break;
      case '--sessions-root': root = next(); break;
      case '--launched-at': launchedAt = next(); break;
      case '--prior': prior.push(next()); break;
      case '--milestone': milestone = next(); break;
      case '--at': at = next(); break;
      default: die(`unknown session option: ${a}`);
    }
  }
  if (harness !== 'codex' && harness !== 'claude') die(`--harness must be codex or claude (got ${harness || 'nothing'})`);
  if (!workspace) die('--workspace is required');
  if (records.length === 0 && !root) die('pass --record <file> or --sessions-root <dir>');
  if (records.length > 0 && root) die('--record and --sessions-root are exclusive');
  const launchedAtMs = launchedAt === null ? null : parseIso(launchedAt, '--launched-at');
  const milestoneMs = milestone === null ? null : parseIso(milestone, '--milestone');
  const atMs = at === null ? null : parseIso(at, '--at');
  if (milestoneMs !== null && atMs !== null) die('--milestone and --at are exclusive');

  const files = records.length > 0
    ? records.map((f) => resolve(f))
    : discoverRecords(harness, workspace, resolve(root), launchedAtMs, new Set(prior.map((p) => resolve(p))));
  const sessions = [];
  for (const file of files) {
    if (!existsSync(file)) die(`record not found: ${file}`);
    const rows = readJsonl(file);
    const folded = harness === 'codex' ? foldCodex(rows, file) : foldClaude(rows, file);
    if (folded.cwd !== workspace) {
      die(`${file}: record cwd is '${folded.cwd}', not the arm's worktree '${workspace}'; refusing to attribute another directory's session to this arm`);
    }
    sessions.push(folded);
  }

  // Slice resolution. The milestone names a moment inside (or just after) the
  // turn that produced the terminal report; that turn's close is the slice.
  let sliceMs = atMs;
  let sliceNote = null;
  if (milestoneMs !== null) {
    let close = null;
    let open = false;
    for (const s of sessions) {
      for (const t of s.turns) {
        if (t.started_ms > milestoneMs) continue;
        if (t.closed_at_ms === undefined || t.closed_at_ms === null) {
          open = true;
          continue;
        }
        if (t.closed_at_ms >= milestoneMs && (close === null || t.closed_at_ms < close)) close = t.closed_at_ms;
      }
    }
    if (close === null) {
      sliceMs = milestoneMs;
      sliceNote = open
        ? 'turn containing the milestone is still open; sliced at the milestone itself'
        : 'no turn contains the milestone; sliced at the milestone itself';
    } else {
      sliceMs = close;
    }
  }
  const within = (ms) => sliceMs === null || ms <= sliceMs;

  const turns = [];
  let activeMs = 0;
  let openTurns = 0;
  let openTurnMs = 0;
  const usage = zeroUsage();
  let requests = 0;
  const modelSet = new Map();
  const sidechainModels = new Map();
  let firstMs = null;
  let lastMs = null;
  let malformed = 0;
  for (const s of sessions) {
    malformed += s.malformed;
    if (s.first_ms !== null && (firstMs === null || s.first_ms < firstMs)) firstMs = s.first_ms;
    for (const t of s.turns) {
      const closed = t.closed_at_ms !== undefined && t.closed_at_ms !== null && within(t.closed_at_ms);
      if (closed) {
        activeMs += t.duration_ms;
        turns.push({
          session: s.session_id,
          started_at: iso(t.started_ms),
          ended_at: iso(t.ended_ms),
          duration_ms: t.duration_ms,
          kind: t.kind,
        });
        if (lastMs === null || t.ended_ms > lastMs) lastMs = t.ended_ms;
      } else if (sliceMs === null || t.started_ms <= sliceMs) {
        openTurns += 1;
        const bound = sliceMs === null ? s.last_ms : Math.min(s.last_ms, sliceMs);
        if (bound !== null && bound > t.started_ms) openTurnMs += bound - t.started_ms;
      }
    }
    if (harness === 'codex') {
      let last = null;
      for (const p of s.usage_points) {
        if (within(p.ms) && (last === null || p.ms >= last.ms)) last = p;
      }
      if (last) addUsage(usage, last.usage);
    } else {
      for (const p of s.usage_points) {
        if (!within(p.ms)) continue;
        addUsage(usage, p.usage);
        requests += 1;
      }
    }
    for (const m of s.models) {
      if (!within(m.ms)) continue;
      modelSet.set(m.model, (modelSet.get(m.model) || 0) + 1);
    }
    for (const m of s.sidechain_models || []) {
      if (!within(m.ms)) continue;
      sidechainModels.set(m.model, (sidechainModels.get(m.model) || 0) + 1);
    }
  }
  if (lastMs === null) {
    for (const s of sessions) if (s.last_ms !== null && (lastMs === null || s.last_ms > lastMs)) lastMs = s.last_ms;
  }
  const models = [...modelSet.keys()];
  let modelReason;
  const mainSessions = sessions.filter((s) => !s.sidechain).length;
  if (mainSessions === 0) modelReason = 'no session record matched the arm worktree';
  else if (models.length === 0) modelReason = 'the session record names no model yet';
  else if (models.length > 1) modelReason = `the session record names ${models.length} different models`;
  else modelReason = 'exactly one model appears in the sliced session record';
  const hasUsage = harness === 'codex'
    ? sessions.some((s) => s.usage_points.some((p) => within(p.ms)))
    : requests > 0;
  const out = {
    schema: 'fm-model-bench-session.v1',
    harness,
    workspace,
    records: sessions.map((s) => ({ file: s.file, session_id: s.session_id, sidechain: s.sidechain === true, malformed_lines: s.malformed })),
    models,
    sidechain_models: [...sidechainModels.keys()],
    model_confirmed: mainSessions > 0 && models.length === 1,
    model_reason: modelReason,
    milestone: milestoneMs === null ? null : iso(milestoneMs),
    slice_at: sliceMs === null ? null : iso(sliceMs),
    slice_note: sliceNote,
    turns,
    active_ms: activeMs,
    open_turns: openTurns,
    open_turn_ms: openTurnMs,
    first_record_at: firstMs === null ? null : iso(firstMs),
    last_record_at: lastMs === null ? null : iso(lastMs),
    wall_ms: firstMs === null || lastMs === null ? null : Math.max(0, lastMs - firstMs),
    usage: hasUsage ? { ...usage, requests: harness === 'claude' ? requests : undefined } : null,
    usage_source: harness === 'codex'
      ? 'codex rollout event_msg token_count info.total_token_usage at the slice'
      : 'claude transcript assistant message.usage summed once per requestId up to the slice',
    malformed_lines: malformed,
  };
  process.stdout.write(`${JSON.stringify(out)}\n`);
}

// --- independence -----------------------------------------------------------

function walkFiles(dir, base = dir, out = []) {
  for (const name of safeList(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) walkFiles(p, base, out);
    else if (st.isFile()) out.push({ rel: relative(base, p), path: p, mtime_ms: st.mtimeMs });
  }
  return out;
}

function independenceCommand(argv) {
  if (argv.length < 2) die('independence needs at least two <arm>=<dir> arguments');
  const arms = [];
  for (const spec of argv) {
    const eq = spec.indexOf('=');
    if (eq <= 0) die(`expected <arm>=<dir>, got ${spec}`);
    const name = spec.slice(0, eq);
    const dir = resolve(spec.slice(eq + 1));
    if (arms.some((a) => a.name === name)) die(`arm ${name} given twice`);
    if (!existsSync(dir) || !statSync(dir).isDirectory()) die(`${name}: not a directory: ${dir}`);
    const files = new Map();
    for (const f of walkFiles(dir)) {
      const hash = createHash('sha256').update(readFileSync(f.path)).digest('hex');
      files.set(f.rel, { hash, mtime_ms: Math.round(f.mtime_ms) });
    }
    arms.push({ name, dir, unavailable: existsSync(`${dir}.unavailable`), files, matches: [], copied_by: new Set(), void: false });
  }
  const pairs = [];
  for (let i = 0; i < arms.length; i += 1) {
    for (let j = i + 1; j < arms.length; j += 1) {
      const a = arms[i];
      const b = arms[j];
      for (const [rel, fa] of a.files) {
        const fb = b.files.get(rel);
        if (!fb || fb.hash !== fa.hash) continue;
        const pair = { path: rel, sha256: fa.hash, arms: [a.name, b.name], at: [iso(fa.mtime_ms), iso(fb.mtime_ms)] };
        let later;
        if (fa.mtime_ms > fb.mtime_ms) later = a;
        else if (fb.mtime_ms > fa.mtime_ms) later = b;
        else later = null;
        if (later === null) {
          a.void = true;
          b.void = true;
          pair.verdict = 'tie: both void';
        } else {
          const earlier = later === a ? b : a;
          later.void = true;
          earlier.copied_by.add(later.name);
          pair.verdict = `${later.name} void: identical to ${earlier.name}, which wrote it first`;
        }
        a.matches.push({ path: rel, other: b.name, this_at: iso(fa.mtime_ms), other_at: iso(fb.mtime_ms) });
        b.matches.push({ path: rel, other: a.name, this_at: iso(fb.mtime_ms), other_at: iso(fa.mtime_ms) });
        pairs.push(pair);
      }
    }
  }
  const out = { schema: 'fm-model-bench-independence.v1', arms: {}, pairs, void_arms: [] };
  for (const a of arms) {
    out.arms[a.name] = {
      dir: a.dir,
      files: a.files.size,
      verdict: a.void ? 'void' : arms.some((arm) => arm.unavailable) ? 'unchecked' : 'independent',
      copied_by: [...a.copied_by].sort(),
      matches: a.matches,
    };
    if (a.void) out.void_arms.push(a.name);
  }
  process.stdout.write(`${JSON.stringify(out)}\n`);
}

// --- newest record ----------------------------------------------------------

function newestRecordCommand(argv) {
  let harness = null;
  let root = null;
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--harness' && i + 1 < argv.length) { harness = argv[i += 1]; continue; }
    if (a === '--sessions-root' && i + 1 < argv.length) { root = argv[i += 1]; continue; }
    die(`unknown newest-record option: ${a}`);
  }
  if (harness !== 'codex' && harness !== 'claude') die('--harness must be codex or claude');
  if (!root) die('--sessions-root is required');
  let best = null;
  const consider = (file) => {
    let st;
    try { st = statSync(file); } catch { return; }
    if (!st.isFile()) return;
    if (best === null || st.mtimeMs > best.mtimeMs) best = { file, mtimeMs: st.mtimeMs };
  };
  if (harness === 'codex') {
    for (const y of safeList(root)) for (const m of safeList(join(root, y))) for (const d of safeList(join(root, y, m))) {
      for (const f of safeList(join(root, y, m, d))) if (/^rollout-.*\.jsonl$/.test(f)) consider(join(root, y, m, d, f));
    }
  } else {
    for (const p of safeList(root)) for (const f of safeList(join(root, p))) if (f.endsWith('.jsonl')) consider(join(root, p, f));
  }
  if (best === null) process.exit(1);
  process.stdout.write(`${best.file}\n`);
}

// --- render -----------------------------------------------------------------

function fmtDuration(ms) {
  if (ms === null || ms === undefined) return '-';
  const s = Math.round(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, '0')}m ${String(sec).padStart(2, '0')}s`;
  if (m > 0) return `${m}m ${String(sec).padStart(2, '0')}s`;
  return `${sec}s`;
}

function fmtInt(n) {
  return Number(n).toLocaleString('en-US');
}

function table(rows) {
  const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => String(r[i]).length)));
  return rows.map((r) => r.map((c, i) => String(c).padEnd(widths[i])).join('  ').trimEnd()).join('\n');
}

function renderCommand(argv) {
  if (argv.length !== 1) die('render takes exactly one <report.json>');
  const report = JSON.parse(readFileSync(argv[0], 'utf8'));
  if (report.schema !== 'fm-model-bench-report.v1') die(`${argv[0]}: not a fm-model-bench-report.v1 document`);
  const lines = [];
  lines.push(`Model gut-check ${report.run_id}: ${report.project_name} at ${String(report.base_sha).slice(0, 12)} (${report.base_branch})`);
  lines.push(`feasibility (asserted by the caller, not checked): ${report.feasibility}`);
  if (report.effort) lines.push(`effort: ${report.effort} (every arm)`);
  const envKeys = Object.keys(report.env || {});
  if (envKeys.length > 0) lines.push(`environment carried into every arm: ${envKeys.join(', ')}`);
  lines.push('');
  const rows = [['arm', 'harness', 'requested', 'confirmed', 'active', 'tokens (in/cached/out)', 'state', 'independence', 'branch']];
  const notes = [];
  for (const a of report.arms) {
    const s = a.session;
    const confirmed = s && s.model_confirmed;
    const isVoid = a.independence && a.independence.verdict === 'void';
    let confirmedCell;
    if (confirmed) confirmedCell = s.models[0] === a.model ? s.models[0] : `${s.models[0]} (MISMATCH)`;
    else confirmedCell = 'UNCONFIRMED';
    if (!confirmed) notes.push(`${a.arm}: model not confirmed - ${s ? s.model_reason : 'no session analysis'}${s && s.models.length > 1 ? ` (${s.models.join(', ')})` : ''}; numbers withheld`);
    else if (s.models[0] !== a.model) notes.push(`${a.arm}: ran ${s.models[0]}, not the requested ${a.model}; numbers belong to the confirmed model`);
    if (s && (s.sidechain_models || []).length > 0) notes.push(`${a.arm}: subagent requests on ${s.sidechain_models.join(', ')} are included in its tokens`);
    const unchecked = !a.independence || a.independence.verdict === 'unchecked';
    if (unchecked) notes.push(`${a.arm}: independence evidence unavailable; numbers withheld`);
    const withhold = Boolean(a.withheld_reason) || !confirmed || isVoid || unchecked;
    const active = withhold || !s ? '-' : fmtDuration(s.active_ms) + (s.open_turns > 0 ? ` (+${fmtDuration(s.open_turn_ms)} open)` : '');
    const tokens = withhold || !s || !s.usage ? '-' : `${fmtInt(s.usage.total)} (${fmtInt(s.usage.input)}/${fmtInt(s.usage.cached_input)}/${fmtInt(s.usage.output)})`;
    let indep;
    if (isVoid) indep = `VOID (identical to ${[...new Set(a.independence.matches.map((m) => m.other))].join(',')})`;
    else if (unchecked) indep = 'UNCHECKED';
    else if (a.independence && a.independence.copied_by.length > 0) indep = `independent (copied by ${a.independence.copied_by.join(',')})`;
    else if (a.independence) indep = a.independence.verdict;
    else indep = 'unchecked';
    rows.push([a.arm, a.harness, a.model, confirmedCell, active, tokens, a.state, indep, a.branch]);
  }
  lines.push(table(rows));
  lines.push('');
  for (const a of report.arms) {
    lines.push(`${a.arm}: branch ${a.branch} in ${a.source_git}${a.worktree ? ` (worktree ${a.worktree})` : ''}${a.milestone ? `; completed ${a.milestone}` : ''}${a.parked_at ? `; parked ${a.parked} at ${a.parked_at}` : ''}${a.state_line ? `; last status: ${a.state_line}` : ''}`);
  }
  for (const n of notes) lines.push(`note: ${n}`);
  for (const v of report.void_arms || []) {
    const a = report.arms.find((x) => x.arm === v);
    const paths = a ? [...new Set(a.independence.matches.map((m) => m.path))] : [];
    lines.push('');
    lines.push(`!!!!! VOID: arm ${v} is excluded from the comparison !!!!!`);
    lines.push(`!!!!! its changed files are byte-identical to another arm's: ${paths.join(', ')} !!!!!`);
  }
  if ((report.warnings || []).length > 0) {
    lines.push('');
    for (const w of report.warnings) lines.push(`WARNING: ${w}`);
  }
  process.stdout.write(`${lines.join('\n')}\n`);
}

// --- main -------------------------------------------------------------------

const [mode, ...rest] = process.argv.slice(2);
switch (mode) {
  case 'session': sessionCommand(rest); break;
  case 'independence': independenceCommand(rest); break;
  case 'newest-record': newestRecordCommand(rest); break;
  case 'render': renderCommand(rest); break;
  case '-h':
  case '--help':
  case undefined:
    process.stdout.write(`${usage()}\n`);
    process.exit(mode === undefined ? 2 : 0);
    break;
  default: die(`unknown mode: ${mode}`);
}
