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
//     Each session also reports the context signal the record carries:
//     context_tokens is the prompt size of the last request at the slice
//     (claude: input_tokens + cache_creation + cache_read of the last assistant
//     usage; codex: last_token_usage.input_tokens of the last token_count),
//     context_peak_tokens is the largest such figure seen, and compactions
//     counts context compactions (claude: rows with isCompactSummary true;
//     codex: rollout items of type compacted). A compaction clears current
//     context to null until another usage row arrives, preserving the peak.
//     The same fold
//     (foldContext) is exported for bin/fm-context-watch.mjs, which reads
//     only the tail of a live record, so both readers share one parser.
//
//   fm-model-bench-analyze.mjs independence <arm>=<dir> [<arm>=<dir>]...
//
//     Byte-compares every file under each arm directory against the same
//     relative path in every other arm. A byte-identical pair means one arm
//     copied the other: the arm whose copy is later (file mtime, which the
//     caller sets to the content's first-appearance time) is void, the earlier
//     one keeps its result and records who copied it, and a tie voids both
//     because nothing orders them. Output: {arms:{<arm>:{files, verdict:
//     "independent"|"void"|"unchecked", copied_by:[...], matches:[{path, other, this_at,
//     other_at}]}}, pairs:[...], void_arms:[...]}. Verdicts are data: the exit
//     status is 0 whenever the comparison ran, 2 on a usage error.
//     A sibling <dir>.unavailable marker means comparison evidence is missing;
//     every otherwise non-void arm is then unchecked, with numbers withheld
//     by the report.
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
//
//   Shared folds for other readers (no command of their own)
//
//     foldContext (above) and foldTurns are exported for bin/fm-context-watch.mjs
//     so the live context reader, the usage breakdown, and the bench slice
//     share one per-harness row parser. foldTurns answers "where did the
//     tokens go": one turn per model request (claude: one per distinct
//     requestId; codex: one per event_msg token_count whose cumulative
//     total_token_usage advanced, which lands after that response's tool
//     outputs), each carrying its timestamp, prompt size (context_tokens),
//     output_tokens, and the tool calls it issued. Calls are claude tool_use
//     blocks paired with tool_result blocks by tool_use_id, and codex
//     function_call / custom_tool_call items paired with their *_output items
//     by call_id. A result's result_bytes is the UTF-8 length of the text that
//     entered the context (a string, or the text blocks of an array, with a
//     non-text block counted as its JSON). Every token figure derived from
//     bytes is an estimate under one rule, tokens_est = ceil(bytes / 4), and
//     is named *_est wherever it appears. wall_seconds is the gap between the
//     call row and its result row, null when either lacks a timestamp.
//     base_prompt_tokens_est is the first turn's prompt size: it estimates the
//     fixed base (system prompt, instructions, launch brief) because the first
//     request also carries the first user message.
//
//     Tool class taxonomy (classifyTool). A call's class comes from the tool
//     name first, then from its command text for command-running tools:
//       claude  Read -> read; Grep, Glob -> search; Edit, Write, MultiEdit,
//               NotebookEdit -> edit; Bash -> by command text; else other.
//       codex   read_file, view_image -> read; grep_files, list_dir -> search;
//               apply_patch -> edit; shell, shell_command, exec_command,
//               local_shell, container.exec -> by the command argument (a
//               ["bash", "-lc", script] array is the script); exec -> by
//               every cmd:"..." string in its script; else other.
//     Command text is split into segments on newlines, &&, ||, ;, and |
//     outside single and double quotes (a separator inside a quoted string,
//     such as the | in jq 'a | b', does not split); a # comment runs to the
//     end of its line and a heredoc body (<<TAG, <<'TAG', <<\TAG, <<-TAG
//     through the TAG line; << inside $((...)) is not an opener) is skipped,
//     so neither drives a class nor opens a quote. The
//     first segment whose class is not other decides. A segment's first
//     word (after leading VAR=value assignments, sudo, time, command, nice,
//     the control words if, elif, while, until, then, else, do, {, (, and
//     !, a case WORD in head and its pattern), and an interpreter such as
//     bash or node followed by a script path) selects, in this order; a for
//     or select header runs no command and is other, so the loop body
//     decides; python/python3 -m <module> selects by the
//     module, and bash/sh/zsh/dash -c <script> by the one script argument
//     (its quoted string or bare word), which is split into its own segments;
//     operands and redirects after it belong to the outer segment:
//       differential  diff, cmp, comm, colordiff, delta, git diff/range-diff/difftool
//       git           git, gh, gh-axi, glab
//       test          pytest, unittest, jest, vitest, mocha, bats, playwright, go test,
//                     cargo test, npm/pnpm/yarn/bun test or run test*, npx of
//                     those runners, node --test, bin/fm-test-run.sh, any
//                     path under tests/ or ending in .test.<ext>
//       build         make, cmake, tsc, esbuild, vite, webpack, rollup,
//                     shellcheck, eslint, prettier, ruff, mypy, black, gofmt,
//                     cargo build/check/clippy, go build/vet/mod,
//                     npm/pnpm/yarn/bun run build, ci, install, i, bin/fm-lint.sh
//       search        rg, grep, egrep, fgrep, ag, ack, ast-grep, find, fd,
//                     fdfind, locate, which, whereis, type
//       read          cat, head, tail, less, more, ls, wc, stat, file, tree,
//                     pwd, du, df, readlink, realpath, jq, sqlite3, nl, od,
//                     xxd, hexdump, strings, cut, sort, uniq, tr, awk,
//                     sed without -i
//       edit          sed -i, tee, cp, mv, rm, mkdir, touch, chmod, chown,
//                     ln, patch, truncate, rsync, git apply
//     A read, search, or other segment that redirects to a file outside its
//     quoted strings (>, >>, or the combined &> and &>> to anything but
//     /dev/null; descriptor duplications such as 2>&1 and >&2 do not count)
//     is edit, because the effect is a write. Anything else is other.

import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

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

export function readJsonl(file) {
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

export function claudeProjectDir(workspace) {
  return workspace.replace(/[^a-zA-Z0-9]/g, '-');
}

export function discoverRecords(harness, workspace, root, launchedAtMs, priorSet) {
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

export function foldCodex(rows, file) {
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

export function normaliseCodexUsage(u) {
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

export function foldClaude(rows, file) {
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

export function normaliseClaudeUsage(u) {
  const fresh = num(u.input_tokens);
  const write = num(u.cache_creation_input_tokens);
  const read = num(u.cache_read_input_tokens);
  const output = num(u.output_tokens);
  const input = fresh + write + read;
  return { input, cached_input: read, cache_write: write, output, reasoning_output: 0, total: input + output };
}

// --- context fold -----------------------------------------------------------
//
// The per-row context signal shared by the session fold above and the live
// tail reader (bin/fm-context-watch.mjs). A row either carries the prompt size
// of one request, marks a compaction, or is irrelevant. The fold is
// incremental: pass the previous result as the seed to continue it over a
// record's newly appended rows.

export function contextRow(harness, r) {
  if (!r || r.__malformed) return null;
  if (harness === 'claude') {
    if (r.type !== 'assistant' || !r.message || typeof r.message !== 'object') return null;
    const u = r.message.usage;
    if (!u || typeof u !== 'object') return null;
    return normaliseClaudeUsage(u).input;
  }
  if (r.type !== 'event_msg' || !r.payload || r.payload.type !== 'token_count') return null;
  const last = r.payload.info && r.payload.info.last_token_usage;
  if (!last || typeof last !== 'object') return null;
  return num(last.input_tokens);
}

export function isCompactionRow(harness, r) {
  if (!r || r.__malformed) return false;
  if (harness === 'claude') return r.isCompactSummary === true;
  return r.type === 'compacted';
}

export function foldContext(harness, rows, seed) {
  const out = {
    context: seed && Number.isFinite(seed.context) ? seed.context : null,
    peak: seed && Number.isFinite(seed.peak) ? seed.peak : 0,
    compactions: seed && Number.isFinite(seed.compactions) ? seed.compactions : 0,
    malformed: 0,
  };
  for (const r of rows) {
    if (r && r.__malformed) { out.malformed += 1; continue; }
    if (isCompactionRow(harness, r)) { out.compactions += 1; out.context = null; continue; }
    const context = contextRow(harness, r);
    if (context === null) continue;
    out.context = context;
    if (context > out.peak) out.peak = context;
  }
  return out;
}

// --- turn and tool fold -----------------------------------------------------
//
// Where the tokens went, per model request. The header documents the turn
// definition, the byte and estimate rules, and the tool class taxonomy;
// bin/fm-context-watch.mjs usage binds a task's records and rolls this up.

export const TOOL_CLASSES = ['read', 'search', 'edit', 'build', 'test', 'differential', 'git', 'other'];
const CLASS_RANK = new Map(TOOL_CLASSES.map((c, i) => [c, i]));
export const HEAD_CHARS = 120;

export function tokensEst(bytes) {
  return Math.ceil(num(bytes) / 4);
}

const DIFFERENTIAL_WORDS = new Set(['diff', 'cmp', 'comm', 'colordiff', 'delta']);
const GIT_WORDS = new Set(['git', 'gh', 'gh-axi', 'glab']);
const TEST_WORDS = new Set(['pytest', 'unittest', 'jest', 'vitest', 'mocha', 'bats', 'playwright']);
const BUILD_WORDS = new Set(['make', 'cmake', 'tsc', 'esbuild', 'vite', 'webpack', 'rollup', 'shellcheck', 'eslint', 'prettier', 'ruff', 'mypy', 'black', 'gofmt']);
const SEARCH_WORDS = new Set(['rg', 'grep', 'egrep', 'fgrep', 'ag', 'ack', 'ast-grep', 'find', 'fd', 'fdfind', 'locate', 'which', 'whereis', 'type']);
const READ_WORDS = new Set(['cat', 'head', 'tail', 'less', 'more', 'ls', 'wc', 'stat', 'file', 'tree', 'pwd', 'du', 'df', 'readlink', 'realpath', 'jq', 'sqlite3', 'nl', 'od', 'xxd', 'hexdump', 'strings', 'cut', 'sort', 'uniq', 'tr', 'awk']);
const EDIT_WORDS = new Set(['tee', 'cp', 'mv', 'rm', 'mkdir', 'touch', 'chmod', 'chown', 'ln', 'patch', 'truncate', 'rsync']);
const PACKAGE_RUNNERS = new Set(['npm', 'pnpm', 'yarn', 'bun']);
const PREFIX_WORDS = new Set(['sudo', 'time', 'command', 'nice', 'if', 'elif', 'while', 'until', 'then', 'else', 'do', '{', '(', '!']);
const HEADER_WORDS = new Set(['for', 'select']);
const INTERPRETERS = new Set(['bash', 'sh', 'zsh', 'dash', 'node', 'python', 'python3', 'perl', 'ruby']);
const SHELLS = new Set(['bash', 'sh', 'zsh', 'dash']);
const PYTHONS = new Set(['python', 'python3']);

const isTestPath = (word) => /(^|\/)tests\/|\.test\.[A-Za-z0-9]+$/.test(word) || word.endsWith('bin/fm-test-run.sh');

function classifySegment(segment) {
  const trimmed = segment.trim();
  const words = trimmed.split(/\s+/).filter(Boolean);
  const total = words.length;
  if (words[0] === 'case') {
    if (words[2] !== 'in') return 'other';
    words.splice(0, 3);
  }
  if (words.length && /^\(?[^()\s]+\)$/.test(words[0])) words.shift();
  if (words.length && words[0].length > 1 && words[0].startsWith('(')) words[0] = words[0].slice(1);
  if (words.length && words[words.length - 1].length > 1 && words[words.length - 1].endsWith(')')) words[words.length - 1] = words[words.length - 1].slice(0, -1);
  while (words.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0]) || PREFIX_WORDS.has(words[0]))) words.shift();
  if (words.length && HEADER_WORDS.has(words[0])) return 'other';
  // `bash tests/x.test.sh` is the test, not bash: an interpreter followed by
  // a script path is classified by the script, `python -m pytest` by the
  // module, and `bash -c '<script>'` by the script text.
  const interpreter = words.length > 1 ? words[0].replace(/^.*\//, '') : '';
  let cls;
  if (SHELLS.has(interpreter) && /^-[a-z]*c[a-z]*$/.test(words[1])) {
    cls = classifyCommand(scriptArgument(dropWords(trimmed, total - words.length + 2)));
  } else {
    if (PYTHONS.has(interpreter) && words[1] === '-m' && words.length > 2) words.splice(0, 2);
    else if (INTERPRETERS.has(interpreter) && !words[1].startsWith('-')) words.shift();
    cls = classifyWords(words);
  }
  if ((cls === 'read' || cls === 'search' || cls === 'other') && redirectsToFile(segment)) cls = 'edit';
  return cls;
}

function classifyWords(words) {
  if (!words.length) return 'other';
  const [first, second = '', third = ''] = words;
  const base = first.replace(/^.*\//, '');
  if (DIFFERENTIAL_WORDS.has(base) || (base === 'git' && ['diff', 'range-diff', 'difftool'].includes(second))) return 'differential';
  if (base === 'git' && second === 'apply') return 'edit';
  if (GIT_WORDS.has(base)) return 'git';
  if (TEST_WORDS.has(base) || (base === 'go' && second === 'test') || (base === 'cargo' && second === 'test')
    || (PACKAGE_RUNNERS.has(base) && (second === 'test' || (second === 'run' && third.startsWith('test'))))
    || (base === 'npx' && TEST_WORDS.has(second)) || (base === 'node' && second === '--test')
    || isTestPath(first)) return 'test';
  if (BUILD_WORDS.has(base) || (base === 'cargo' && ['build', 'check', 'clippy'].includes(second))
    || (base === 'go' && ['build', 'vet', 'mod'].includes(second))
    || (PACKAGE_RUNNERS.has(base) && ((second === 'run' && third === 'build') || ['ci', 'install', 'i'].includes(second)))
    || first.endsWith('bin/fm-lint.sh')) return 'build';
  if (SEARCH_WORDS.has(base)) return 'search';
  if (base === 'sed') return words.some((w) => /^-[a-zA-Z]*i/.test(w) || w === '--in-place') ? 'edit' : 'read';
  if (READ_WORDS.has(base)) return 'read';
  if (EDIT_WORDS.has(base)) return 'edit';
  return 'other';
}

function dropWords(text, count) {
  let rest = text;
  for (let i = 0; i < count; i += 1) rest = rest.replace(/^\S+\s*/, '');
  return rest;
}

function scriptArgument(text) {
  const word = /^(?:'([^']*)'|"((?:[^"\\]|\\.)*)"|(\S+))/.exec(text);
  if (!word) return '';
  if (word[1] !== undefined) return word[1];
  if (word[2] !== undefined) return word[2].replace(/\\(.)/g, '$1');
  return word[3];
}

function redirectsToFile(segment) {
  const stripped = segment.replace(/'[^']*'|"(?:[^"\\]|\\.)*"|\$?\(\([\s\S]*?\)\)/g, (opaque) => opaque.replace(/>/g, '_'))
    .replace(/\d?>&\d/g, '').replace(/&?>>?\s*\/dev\/null/g, '');
  return /(^|[^<>])&?>>?\s*[^\s&|;>]/.test(stripped);
}

// Segments of a command text, split on newlines, &&, ||, ;, and | that sit
// outside single or double quotes; a backslash escapes the next character
// outside single quotes. A # comment runs to the end of its line, arithmetic
// $((...)) is opaque, and the body of each heredoc a line opens (<<TAG,
// <<'TAG', <<"TAG", <<\TAG, <<-TAG) is skipped through its terminator line;
// a body with no terminator is scanned as ordinary lines.
function splitSegments(text) {
  const segments = [];
  let quote = null;
  let start = 0;
  let current = '';
  let heredocs = [];
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (quote) {
      if (ch === '\\' && quote === '"') i += 1;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '\\') { i += 1; continue; }
    if (ch === "'" || ch === '"') { quote = ch; continue; }
    if (ch === '#' && (i === 0 || /[\s;|&]/.test(text[i - 1]))) {
      const end = text.indexOf('\n', i);
      current += text.slice(start, i);
      start = end === -1 ? text.length : end;
      i = start - 1;
      continue;
    }
    if (text.startsWith('$((', i) || (text.startsWith('((', i) && (i === 0 || /[\s;|&]/.test(text[i - 1])))) {
      const end = text.indexOf('))', i + 2);
      i = end === -1 ? text.length - 1 : end + 1;
      continue;
    }
    if (ch === '<' && text[i + 1] === '<' && text[i + 2] !== '<') {
      const tag = /^<<-?\s*(?:'([^']*)'|"([^"]*)"|\\?([A-Za-z0-9_.-]+))/.exec(text.slice(i));
      if (tag) {
        heredocs.push(tag[1] ?? tag[2] ?? tag[3]);
        i += tag[0].length - 1;
        continue;
      }
    }
    const pair = text.slice(i, i + 2);
    if (ch === '\n') {
      segments.push(current + text.slice(start, i));
      current = '';
      let pos = i + 1;
      for (const tag of heredocs) {
        let cursor = pos;
        let closed = false;
        while (cursor < text.length && !closed) {
          const end = text.indexOf('\n', cursor);
          const line = end === -1 ? text.slice(cursor) : text.slice(cursor, end);
          cursor = end === -1 ? text.length : end + 1;
          closed = line.trim() === tag;
        }
        if (!closed) break;
        pos = cursor;
      }
      heredocs = [];
      start = pos;
      i = pos - 1;
    } else if (ch === ';' || ch === '|' || pair === '&&') {
      segments.push(current + text.slice(start, i));
      current = '';
      if (pair === '&&' || pair === '||') i += 1;
      start = i + 1;
    }
  }
  segments.push(current + text.slice(start));
  return segments;
}

export function classifyCommand(text) {
  if (typeof text !== 'string' || !text.trim()) return 'other';
  for (const segment of splitSegments(text)) {
    const cls = classifySegment(segment);
    if (cls !== 'other') return cls;
  }
  return 'other';
}

const CLAUDE_TOOL_CLASS = { Read: 'read', Grep: 'search', Glob: 'search', Edit: 'edit', Write: 'edit', MultiEdit: 'edit', NotebookEdit: 'edit' };
const CODEX_TOOL_CLASS = { read_file: 'read', view_image: 'read', grep_files: 'search', list_dir: 'search', apply_patch: 'edit' };
const CODEX_SHELL_TOOLS = new Set(['shell', 'shell_command', 'exec_command', 'local_shell', 'container.exec']);

// The command text a call ran, or null for a tool that runs no command.
export function commandTextOf(harness, name, input) {
  if (harness === 'claude') {
    return name === 'Bash' && input && typeof input.command === 'string' ? input.command : null;
  }
  if (CODEX_SHELL_TOOLS.has(name)) {
    const args = parseArguments(input);
    const command = args && (args.command ?? args.cmd);
    if (Array.isArray(command)) {
      // ["bash", "-lc", "<script>"] is the script, not bash.
      const [shell = '', flag = ''] = command.map(String);
      if (command.length >= 3 && /^(bash|sh|zsh|dash)$/.test(shell.replace(/^.*\//, '')) && /^-[a-z]*c[a-z]*$/.test(flag)) {
        return command.slice(2).map(String).join(' ');
      }
      return command.map(String).join(' ');
    }
    return typeof command === 'string' ? command : (typeof input === 'string' ? input : null);
  }
  if (name === 'exec' && typeof input === 'string') {
    const commands = [];
    for (const m of input.matchAll(/cmd\s*:\s*"((?:[^"\\]|\\.)*)"/g)) commands.push(m[1].replace(/\\n/g, '\n').replace(/\\(.)/g, '$1'));
    return commands.length ? commands.join('\n') : null;
  }
  return null;
}

function parseArguments(input) {
  if (input && typeof input === 'object') return input;
  if (typeof input !== 'string') return null;
  try { return JSON.parse(input); } catch { return null; }
}

export function classifyTool(harness, name, input) {
  const fixed = harness === 'claude' ? CLAUDE_TOOL_CLASS[name] : CODEX_TOOL_CLASS[name];
  if (fixed) return fixed;
  const command = commandTextOf(harness, name, input);
  return command === null ? 'other' : classifyCommand(command);
}

// The first HEAD_CHARS characters, whitespace collapsed, of what the call ran:
// the command text, else the file, pattern, or path it named, else its input.
export function inputHeadOf(harness, name, input) {
  let text = commandTextOf(harness, name, input);
  if (text === null) {
    if (input && typeof input === 'object') {
      const named = ['file_path', 'path', 'pattern', 'notebook_path', 'url', 'prompt'].find((k) => typeof input[k] === 'string');
      text = named ? input[named] : JSON.stringify(input);
    } else {
      text = input === undefined || input === null ? '' : String(input);
    }
  }
  return text.replace(/\s+/g, ' ').trim().slice(0, HEAD_CHARS);
}

// The bytes a result put into the context: a string as is, an array by its
// text blocks (claude text / codex input_text) with any other block as JSON.
export function resultBytesOf(content) {
  if (content === undefined || content === null) return 0;
  if (typeof content === 'string') return Buffer.byteLength(content, 'utf8');
  if (Array.isArray(content)) {
    let bytes = 0;
    for (const block of content) {
      if (block && typeof block.text === 'string' && (block.type === 'text' || block.type === 'input_text' || block.type === 'output_text')) bytes += Buffer.byteLength(block.text, 'utf8');
      else bytes += Buffer.byteLength(JSON.stringify(block ?? null), 'utf8');
    }
    return bytes;
  }
  return Buffer.byteLength(JSON.stringify(content), 'utf8');
}

function newTurn(index, ms, ts, context, output) {
  return { index, ms, ts, context_tokens: context, output_tokens: output, tools: [] };
}

function newCall(turn, name, cls, head, ms) {
  const call = { turn, name, tool_class: cls, head, issued_ms: ms, result_ms: null, result_bytes: null };
  turn.tools.push(call);
  return call;
}

function settleCall(call, ms, content) {
  call.result_ms = Number.isFinite(ms) ? ms : null;
  call.result_bytes = resultBytesOf(content);
}

// Returns {turns:[{index, ts, context_tokens, output_tokens, tools:[{name,
// tool_class, head, issued_ms, result_ms, result_bytes}]}], orphan_results,
// malformed}. A call with no result yet keeps result_bytes null and counts as
// a call with zero result bytes in roll-ups.
export function foldTurns(harness, rows) {
  const turns = [];
  const calls = new Map();
  let orphanResults = 0;
  let malformed = 0;
  if (harness === 'claude') {
    const byRequest = new Map();
    for (const r of rows) {
      if (!r) continue;
      if (r.__malformed) { malformed += 1; continue; }
      if (r.isSidechain === true) continue;
      const ms = Date.parse(r.timestamp || '');
      const message = r.message && typeof r.message === 'object' ? r.message : null;
      if (r.type === 'assistant' && message) {
        if (message.model === '<synthetic>') continue;
        const u = message.usage;
        if (!u || typeof u !== 'object') continue;
        const key = r.requestId || message.id || r.uuid;
        if (!key) continue;
        let turn = byRequest.get(key);
        if (!turn) {
          const usage = normaliseClaudeUsage(u);
          turn = newTurn(turns.length + 1, ms, typeof r.timestamp === 'string' ? r.timestamp : null, usage.input, usage.output);
          byRequest.set(key, turn);
          turns.push(turn);
        }
        for (const block of Array.isArray(message.content) ? message.content : []) {
          if (!block || block.type !== 'tool_use' || typeof block.name !== 'string') continue;
          const call = newCall(turn, block.name, classifyTool('claude', block.name, block.input), inputHeadOf('claude', block.name, block.input), Number.isFinite(ms) ? ms : null);
          if (typeof block.id === 'string') calls.set(block.id, call);
        }
        continue;
      }
      if (r.type === 'user' && message && Array.isArray(message.content)) {
        for (const block of message.content) {
          if (!block || block.type !== 'tool_result') continue;
          const call = calls.get(block.tool_use_id);
          if (!call) { orphanResults += 1; continue; }
          settleCall(call, ms, block.content);
        }
      }
    }
  } else {
    let pending = [];
    let previousTotal = null;
    for (const r of rows) {
      if (!r) continue;
      if (r.__malformed) { malformed += 1; continue; }
      const ms = Date.parse(r.timestamp || '');
      const p = r.payload;
      if (!p || typeof p !== 'object') continue;
      if (r.type === 'response_item') {
        if (p.type === 'function_call' || p.type === 'custom_tool_call') {
          const name = typeof p.name === 'string' ? p.name : p.type;
          const input = p.type === 'function_call' ? p.arguments : p.input;
          const call = { name, tool_class: classifyTool('codex', name, input), head: inputHeadOf('codex', name, input), issued_ms: Number.isFinite(ms) ? ms : null, result_ms: null, result_bytes: null };
          pending.push(call);
          if (typeof p.call_id === 'string') calls.set(p.call_id, call);
        } else if (p.type === 'function_call_output' || p.type === 'custom_tool_call_output') {
          const call = calls.get(p.call_id);
          if (!call) { orphanResults += 1; continue; }
          settleCall(call, ms, p.output);
        }
        continue;
      }
      if (r.type !== 'event_msg' || p.type !== 'token_count') continue;
      const total = p.info && p.info.total_token_usage;
      const last = p.info && p.info.last_token_usage;
      if (!total || !last || typeof last !== 'object') continue;
      const cumulative = Number.isFinite(total.total_tokens) ? total.total_tokens : num(total.input_tokens) + num(total.output_tokens);
      if (previousTotal !== null && cumulative <= previousTotal) continue;
      previousTotal = cumulative;
      const turn = newTurn(turns.length + 1, ms, typeof r.timestamp === 'string' ? r.timestamp : null, num(last.input_tokens), num(last.output_tokens));
      for (const call of pending) { call.turn = turn; turn.tools.push(call); }
      pending = [];
      turns.push(turn);
    }
    // Calls issued after the last closing token_count belong to an open turn
    // the record has not closed; they are not attributed to any turn.
  }
  return { turns, orphan_results: orphanResults, malformed };
}

// Roll a task's folded records (in launch order) into the fm-task-tool-usage.v1
// shape: totals, per-tool and per-class rows, the five largest results, and
// the turn timeline with indexes continuing across records.
export function rollUpTurns(folds) {
  const tools = new Map();
  const classes = new Map();
  const results = [];
  const timeline = [];
  let toolCalls = 0;
  let resultBytes = 0;
  let outputTokens = 0;
  let basePrompt = null;
  for (const fold of folds) {
    for (const turn of fold.turns) {
      const index = timeline.length + 1;
      if (basePrompt === null) basePrompt = turn.context_tokens;
      outputTokens += num(turn.output_tokens);
      let turnBytes = 0;
      for (const call of turn.tools) {
        toolCalls += 1;
        const bytes = num(call.result_bytes);
        turnBytes += bytes;
        resultBytes += bytes;
        const wall = call.issued_ms !== null && call.result_ms !== null ? Math.max(0, call.result_ms - call.issued_ms) : null;
        for (const [map, key] of [[tools, `${call.name}\0${call.tool_class}`], [classes, call.tool_class]]) {
          const row = map.get(key) || { tool_name: call.name, tool_class: call.tool_class, calls: 0, result_bytes: 0, wall_ms: 0, timed: 0 };
          row.calls += 1;
          row.result_bytes += bytes;
          if (wall !== null) { row.wall_ms += wall; row.timed += 1; }
          map.set(key, row);
        }
        results.push({ tool_name: call.name, tool_class: call.tool_class, command_or_input_head: call.head, result_bytes: bytes, order: results.length });
      }
      const first = turn.tools[0] || null;
      timeline.push({
        turn_index: index,
        ts: turn.ts,
        context_tokens: turn.context_tokens,
        output_tokens: turn.output_tokens,
        tool_name: first ? first.name : null,
        tool_class: first ? first.tool_class : null,
        tool_result_tokens_est: tokensEst(turnBytes),
      });
    }
  }
  const finish = (row) => ({
    tool_name: row.tool_name,
    tool_class: row.tool_class,
    calls: row.calls,
    result_bytes: row.result_bytes,
    result_tokens_est: tokensEst(row.result_bytes),
    // Partial timing would understate the total, so the sum is reported only
    // when every call of the row was timed.
    wall_seconds_in_tool: row.timed === row.calls ? Math.round(row.wall_ms) / 1000 : null,
  });
  const byName = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const toolRows = [...tools.values()].sort((a, b) => byName(a.tool_name, b.tool_name) || byName(a.tool_class, b.tool_class)).map(finish);
  const classRows = [...classes.values()].sort((a, b) => CLASS_RANK.get(a.tool_class) - CLASS_RANK.get(b.tool_class)).map((row) => {
    const out = finish(row);
    delete out.tool_name;
    return out;
  });
  const largest = results.sort((a, b) => b.result_bytes - a.result_bytes || a.order - b.order).slice(0, 5)
    .map((row, i) => ({ rank: i + 1, tool_name: row.tool_name, tool_class: row.tool_class, command_or_input_head: row.command_or_input_head, tokens_est: tokensEst(row.result_bytes) }));
  return {
    turns: timeline.length,
    tool_calls: toolCalls,
    tool_result_bytes: resultBytes,
    tool_result_tokens_est: tokensEst(resultBytes),
    assistant_output_tokens: outputTokens,
    base_prompt_tokens_est: basePrompt,
    tools: toolRows,
    classes: classRows,
    largest,
    timeline,
  };
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
    folded.rows = rows;
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
  // The context signal is a property of the main transcript: a sidechain has
  // its own context window and never compacts the arm's. Sessions are folded
  // in record order, so the last main record's final request is the context.
  let contextFold = null;
  for (const s of sessions) {
    if (s.sidechain) continue;
    const sliced = s.rows.filter((r) => {
      if (!r || r.__malformed) return false;
      const ms = Date.parse(r.timestamp || '');
      return !Number.isFinite(ms) || within(ms);
    });
    contextFold = foldContext(harness, sliced, contextFold);
  }
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
    context_tokens: contextFold ? contextFold.context : null,
    context_peak_tokens: contextFold ? contextFold.peak : null,
    compactions: contextFold ? contextFold.compactions : null,
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
//
// Runs only when invoked directly; an importer (bin/fm-context-watch.mjs)
// gets the exported folds without a CLI dispatch.

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
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
}
