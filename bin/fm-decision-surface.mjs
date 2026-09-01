#!/usr/bin/env node
// fm-decision-surface.mjs - render a Lavish decision board from durable holds.
//
// Usage:
//   fm-decision-surface.mjs --input <brief.json> --output <board.html>
//                           [--snapshot <fleet-snapshot.json>]
//
// Without --snapshot, the command reads fresh structured state from
// bin/fm-fleet-snapshot.sh --json in the selected FM_HOME.
// It never parses reports, review artifacts, chat, terminal output, or backlog
// prose. The fleet snapshot owns each decision's title, hold reason, and
// durable identity; the input owns presentation judgement only.
//
// Input schema `fm-decision-surface-input.v1`:
//   board: {eyebrow,title,introduction,footer?}
//   groups[]: {id,title,description?}
//   decisions[]: {
//     hold:{owner,id}, group, context, priority?:"normal"|"blocking",
//     evidence:[
//       {kind:"paragraph",text},
//       {kind:"schematic",title?,lines:[...]},
//       {kind:"facts",title?,rows:[{label,value},...]},
//       {kind:"callout",tone:"note"|"warning",label?,text}
//     ],
//     recommendation:null|{label?,text},
//     options:[{label,answer,consequence},...],
//     note_placeholder?
//   }
// `hold.owner` is `main` or a registered secondmate id from
// secondmate_current.records[].id. Every referenced hold must be actionable
// structured state in the supplied snapshot. Option `answer` text becomes the
// actionable queued prompt; it must therefore say what to do, not merely name
// an option. The output is a self-contained HTML file except for the same
// Google Fonts stylesheet used by Firstmate's existing Lavish boards.

import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(SCRIPT_DIR);

function usage(stream = process.stderr) {
  stream.write(`usage: fm-decision-surface.mjs --input <brief.json> --output <board.html> [--snapshot <fleet-snapshot.json>]\n`);
}

function fail(message) {
  process.stderr.write(`fm-decision-surface: ${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = { input: null, output: null, snapshot: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '-h' || argument === '--help') {
      usage(process.stdout);
      process.exit(0);
    }
    if (!['--input', '--output', '--snapshot'].includes(argument)) {
      usage();
      fail(`unknown argument: ${argument}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      usage();
      fail(`${argument} requires a path`);
    }
    options[argument.slice(2)] = value;
    index += 1;
  }
  if (!options.input || !options.output) {
    usage();
    fail('--input and --output are required');
  }
  return options;
}

function readJson(path, label) {
  let raw;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (error) {
    fail(`cannot read ${label} ${path}: ${error.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    fail(`cannot parse ${label} ${path} as JSON: ${error.message}`);
  }
}

function freshSnapshot() {
  const command = join(SCRIPT_DIR, 'fm-fleet-snapshot.sh');
  const result = spawnSync(command, ['--json'], {
    cwd: ROOT,
    encoding: 'utf8',
    env: process.env,
    maxBuffer: 16 * 1024 * 1024
  });
  if (result.error) fail(`cannot run fleet snapshot: ${result.error.message}`);
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim();
    fail(`fleet snapshot failed${detail ? `: ${detail}` : ''}`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    fail(`fleet snapshot returned invalid JSON: ${error.message}`);
  }
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requireRecord(value, path) {
  if (!isRecord(value)) fail(`${path} must be an object`);
  return value;
}

function requireArray(value, path, { min = 0, max = 100 } = {}) {
  if (!Array.isArray(value)) fail(`${path} must be an array`);
  if (value.length < min) fail(`${path} must contain at least ${min} item${min === 1 ? '' : 's'}`);
  if (value.length > max) fail(`${path} must contain at most ${max} items`);
  return value;
}

function requireString(value, path, { optional = false, max = 10000 } = {}) {
  if (optional && value === undefined) return '';
  if (typeof value !== 'string' || value.trim() === '') fail(`${path} must be a non-empty string`);
  if (value.length > max) fail(`${path} must contain at most ${max} characters`);
  return value;
}

function requireSlug(value, path) {
  const text = requireString(value, path, { max: 160 });
  if (!/^[A-Za-z0-9._-]+$/.test(text)) fail(`${path} must be a privacy-safe slug`);
  return text;
}

function validateEvidence(block, path) {
  requireRecord(block, path);
  const kind = requireString(block.kind, `${path}.kind`, { max: 30 });
  if (kind === 'paragraph') {
    requireString(block.text, `${path}.text`);
    return;
  }
  if (kind === 'schematic') {
    if (block.title !== undefined) requireString(block.title, `${path}.title`, { max: 200 });
    requireArray(block.lines, `${path}.lines`, { min: 1, max: 100 }).forEach((line, index) => {
      requireString(line, `${path}.lines[${index}]`, { max: 1000 });
    });
    return;
  }
  if (kind === 'facts') {
    if (block.title !== undefined) requireString(block.title, `${path}.title`, { max: 200 });
    requireArray(block.rows, `${path}.rows`, { min: 1, max: 50 }).forEach((row, index) => {
      requireRecord(row, `${path}.rows[${index}]`);
      requireString(row.label, `${path}.rows[${index}].label`, { max: 300 });
      requireString(row.value, `${path}.rows[${index}].value`, { max: 2000 });
    });
    return;
  }
  if (kind === 'callout') {
    if (!['note', 'warning'].includes(block.tone)) fail(`${path}.tone must be note or warning`);
    if (block.label !== undefined) requireString(block.label, `${path}.label`, { max: 200 });
    requireString(block.text, `${path}.text`);
    return;
  }
  fail(`${path}.kind is unsupported: ${kind}`);
}

function validateInput(input) {
  requireRecord(input, 'input');
  if (input.schema !== 'fm-decision-surface-input.v1') {
    fail('input.schema must be fm-decision-surface-input.v1');
  }
  const board = requireRecord(input.board, 'input.board');
  requireString(board.eyebrow, 'input.board.eyebrow', { max: 300 });
  requireString(board.title, 'input.board.title', { max: 300 });
  requireString(board.introduction, 'input.board.introduction', { max: 2000 });
  if (board.footer !== undefined) requireString(board.footer, 'input.board.footer', { max: 1000 });

  const groupIds = new Set();
  requireArray(input.groups, 'input.groups', { min: 1, max: 30 }).forEach((group, index) => {
    const path = `input.groups[${index}]`;
    requireRecord(group, path);
    const id = requireSlug(group.id, `${path}.id`);
    if (groupIds.has(id)) fail(`${path}.id is duplicated: ${id}`);
    groupIds.add(id);
    requireString(group.title, `${path}.title`, { max: 300 });
    if (group.description !== undefined) requireString(group.description, `${path}.description`, { max: 1000 });
  });

  const references = new Set();
  requireArray(input.decisions, 'input.decisions', { min: 1, max: 100 }).forEach((decision, index) => {
    const path = `input.decisions[${index}]`;
    requireRecord(decision, path);
    const hold = requireRecord(decision.hold, `${path}.hold`);
    const owner = requireSlug(hold.owner, `${path}.hold.owner`);
    const id = requireSlug(hold.id, `${path}.hold.id`);
    const reference = `${owner}:${id}`;
    if (references.has(reference)) fail(`${path}.hold duplicates ${reference}`);
    references.add(reference);
    const group = requireSlug(decision.group, `${path}.group`);
    if (!groupIds.has(group)) fail(`${path}.group does not name an input group: ${group}`);
    requireString(decision.context, `${path}.context`, { max: 500 });
    if (decision.priority !== undefined && !['normal', 'blocking'].includes(decision.priority)) {
      fail(`${path}.priority must be normal or blocking`);
    }
    requireArray(decision.evidence, `${path}.evidence`, { min: 1, max: 30 }).forEach((block, evidenceIndex) => {
      validateEvidence(block, `${path}.evidence[${evidenceIndex}]`);
    });
    if (decision.recommendation !== null && decision.recommendation !== undefined) {
      const recommendation = requireRecord(decision.recommendation, `${path}.recommendation`);
      if (recommendation.label !== undefined) requireString(recommendation.label, `${path}.recommendation.label`, { max: 200 });
      requireString(recommendation.text, `${path}.recommendation.text`);
    }
    const answers = new Set();
    requireArray(decision.options, `${path}.options`, { min: 2, max: 8 }).forEach((option, optionIndex) => {
      const optionPath = `${path}.options[${optionIndex}]`;
      requireRecord(option, optionPath);
      requireString(option.label, `${optionPath}.label`, { max: 300 });
      const answer = requireString(option.answer, `${optionPath}.answer`, { max: 2000 });
      if (answers.has(answer)) fail(`${optionPath}.answer is duplicated within the decision`);
      answers.add(answer);
      requireString(option.consequence, `${optionPath}.consequence`, { max: 3000 });
    });
    if (decision.note_placeholder !== undefined) {
      requireString(decision.note_placeholder, `${path}.note_placeholder`, { max: 500 });
    }
  });
  return input;
}

function collectHolds(snapshot) {
  requireRecord(snapshot, 'snapshot');
  if (snapshot.schema !== 'fm-fleet-snapshot.v1') {
    fail('snapshot.schema must be fm-fleet-snapshot.v1');
  }
  const holds = new Map();
  const add = (owner, id, title, reason, repository, origin, key) => {
    const reference = `${owner}:${id}`;
    if (holds.has(reference)) fail(`snapshot contains duplicate actionable hold ${reference}`);
    holds.set(reference, { owner, id, title, reason, repository, origin, key });
  };

  const backlog = isRecord(snapshot.backlog) && Array.isArray(snapshot.backlog.records)
    ? snapshot.backlog.records
    : [];
  for (const record of backlog) {
    if (!isRecord(record) || record.structured !== true || record.kind !== 'captain' ||
        record.hold_kind !== 'captain' || record.captain_actionable !== true) continue;
    const id = requireSlug(record.id, 'snapshot.backlog.records[].id');
    const title = requireString(record.title, `snapshot hold ${id}.title`, { max: 500 });
    const reason = requireString(record.hold_reason, `snapshot hold ${id}.hold_reason`, { max: 3000 });
    const decision = isRecord(record.captain_decision) ? record.captain_decision : {};
    add('main', id, title, reason, record.repo ?? null, decision.origin ?? null, decision.key ?? null);
  }

  const mates = isRecord(snapshot.secondmate_current) && Array.isArray(snapshot.secondmate_current.records)
    ? snapshot.secondmate_current.records
    : [];
  for (const mate of mates) {
    if (!isRecord(mate) || mate.provenance?.selected !== 'structured-home') continue;
    const owner = requireSlug(mate.id, 'snapshot.secondmate_current.records[].id');
    const decisions = Array.isArray(mate.decisions_open) ? mate.decisions_open : [];
    for (const decision of decisions) {
      if (!isRecord(decision) || decision.verb !== 'captain-hold' || decision.source !== 'backlog') continue;
      const id = requireSlug(decision.id, `snapshot secondmate ${owner} decision id`);
      const title = requireString(decision.summary, `snapshot hold ${owner}:${id}.summary`, { max: 500 });
      const reason = requireString(decision.reason, `snapshot hold ${owner}:${id}.reason`, { max: 3000 });
      add(owner, id, title, reason, null, null, null);
    }
  }
  return holds;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function renderEvidence(block) {
  if (block.kind === 'paragraph') return `      <p>${escapeHtml(block.text)}</p>`;
  if (block.kind === 'schematic') {
    const title = block.title ? `      <p class="evidence-label">${escapeHtml(block.title)}</p>\n` : '';
    return `${title}      <pre>${escapeHtml(block.lines.join('\n'))}</pre>`;
  }
  if (block.kind === 'facts') {
    const title = block.title ? `      <p class="evidence-label">${escapeHtml(block.title)}</p>\n` : '';
    const rows = block.rows.map((row) =>
      `        <tr><th scope="row">${escapeHtml(row.label)}</th><td>${escapeHtml(row.value)}</td></tr>`
    ).join('\n');
    return `${title}      <div class="fact-scroll"><table class="facts"><tbody>\n${rows}\n      </tbody></table></div>`;
  }
  const label = block.label ? `<b>${escapeHtml(block.label)}.</b> ` : '';
  return `      <div class="callout ${escapeHtml(block.tone)}">${label}${escapeHtml(block.text)}</div>`;
}

function renderDecision(decision, hold, index) {
  const question = `${hold.owner}__${hold.id}`;
  const queueKey = `decision:${hold.owner}:${hold.id}`;
  const formClass = decision.priority === 'blocking' ? 'q blocking' : 'q';
  const evidence = decision.evidence.map(renderEvidence).join('\n');
  const recommendation = decision.recommendation
    ? `\n      <div class="recommendation"><b>${escapeHtml(decision.recommendation.label || 'Recommendation')}.</b> ${escapeHtml(decision.recommendation.text)}</div>`
    : '';
  const options = decision.options.map((option) => `
        <label class="option">
          <input type="radio" name="answer" value="${escapeHtml(option.answer)}">
          <span class="option-label">${escapeHtml(option.label)}</span>
          <span class="option-consequence">${escapeHtml(option.consequence)}</span>
        </label>`).join('');
  const placeholder = decision.note_placeholder || 'Optional - context, constraints, or a different answer entirely';
  const repository = hold.repository ? ` · ${escapeHtml(hold.repository)}` : '';
  return `
  <!-- Decision ${index + 1}: ${escapeHtml(queueKey)} -->
  <form class="${formClass}" data-lavish-question="${escapeHtml(question)}" data-queue-key="${escapeHtml(queueKey)}" data-decision-title="${escapeHtml(hold.title)}" data-hold-owner="${escapeHtml(hold.owner)}" data-hold-id="${escapeHtml(hold.id)}">
    <div class="question-heading">
      <p class="context">${escapeHtml(decision.context)}${repository}</p>
      <h3>${escapeHtml(hold.title)}</h3>
      <p class="hold-reason">Why this needs a decision: ${escapeHtml(hold.reason)}</p>
    </div>
    <div class="question-body">
${evidence}${recommendation}
      <fieldset>
        <legend>Choose one</legend>${options}
      </fieldset>
      <p class="note-label"><label for="note-${escapeHtml(question)}">Anything else</label></p>
      <textarea id="note-${escapeHtml(question)}" name="note" placeholder="${escapeHtml(placeholder)}"></textarea>
      <div class="selected" aria-live="polite"><b>Selected locally.</b> <span class="selected-text"></span></div>
      <button type="submit" class="queue">Queue this answer</button>
      <div class="queued" aria-live="polite"><b>Queued for the agent.</b> <span class="queued-text"></span></div>
    </div>
  </form>`;
}

function renderBoard(input, holds) {
  const decisionsByGroup = new Map(input.groups.map((group) => [group.id, []]));
  input.decisions.forEach((decision, index) => {
    const reference = `${decision.hold.owner}:${decision.hold.id}`;
    const hold = holds.get(reference);
    if (!hold) fail(`input.decisions[${index}].hold ${reference} is not an actionable structured captain hold in the fleet snapshot`);
    decisionsByGroup.get(decision.group).push({ decision, hold, index });
  });
  const sections = input.groups.map((group) => {
    const items = decisionsByGroup.get(group.id);
    if (items.length === 0) return '';
    const description = group.description ? `\n  <p class="group-description">${escapeHtml(group.description)}</p>` : '';
    return `
  <section aria-labelledby="group-${escapeHtml(group.id)}">
    <h2 class="group-title" id="group-${escapeHtml(group.id)}">${escapeHtml(group.title)}</h2>${description}
${items.map(({ decision, hold, index }) => renderDecision(decision, hold, index)).join('\n')}
  </section>`;
  }).join('\n');
  const footer = input.board.footer || `${input.decisions.length} open decision${input.decisions.length === 1 ? '' : 's'} · answer any subset · nothing sends until Send to Agent`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(input.board.title)}</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;0,700;1,400&amp;family=IBM+Plex+Mono:wght@400;500;600&amp;display=swap">
<style>
:root{
  --bg:#fdf6e3;--bg2:#f4f0d9;--bg3:#efebd4;--line:#e0dcc7;
  --fg:#4a545a;--dim:#77857a;--faint:#a2ad9c;--red:#e14a47;
  --orange:#e07020;--green:#7d9000;--blue:#3387b5;
}
*{box-sizing:border-box;min-width:0}
body{margin:0;background:var(--bg);color:var(--fg);font-family:'IBM Plex Sans',system-ui,sans-serif;font-size:15px;line-height:1.6;-webkit-font-smoothing:antialiased}
.wrap{max-width:920px;margin:0 auto;padding:36px 24px 90px}
.top{border-bottom:2px solid var(--fg);padding-bottom:18px;margin-bottom:14px}
.eyebrow,.context,.evidence-label,.note-label,legend{font-family:'IBM Plex Mono',monospace;text-transform:uppercase;letter-spacing:.12em}
.eyebrow{font-size:11px;letter-spacing:.16em;color:var(--dim);margin:0 0 6px}
.top h1{margin:0;font-size:31px;font-weight:600;letter-spacing:-.02em;line-height:1.25}
.top .intro{margin:9px 0 0;color:var(--dim);max-width:68ch}
.howto{border:1px solid var(--line);background:var(--bg2);padding:13px 17px;margin:20px 0 34px;font-size:13.5px}
.group-title{font-family:'IBM Plex Mono',monospace;font-size:12px;letter-spacing:.15em;text-transform:uppercase;color:var(--dim);margin:46px 0 4px;border-bottom:1px solid var(--line);padding-bottom:7px}
.group-description{color:var(--dim);font-size:13.5px;margin:0 0 20px;max-width:70ch}
.q{border:1px solid var(--line);background:var(--bg2);margin:0 0 18px}
.q.blocking{border-color:var(--red)}
.question-heading{padding:14px 20px;border-bottom:1px solid var(--line);background:var(--bg3)}
.context{font-size:10px;color:var(--dim);margin:0 0 4px}
.blocking .context{color:var(--red)}
.question-heading h3{margin:0;font-size:17px;font-weight:600;letter-spacing:-.01em;line-height:1.35}
.hold-reason{margin:7px 0 0;color:var(--dim);font-size:13px;max-width:76ch}
.question-body{padding:16px 20px}
.question-body>p{margin:0 0 12px;max-width:78ch}
.evidence-label{font-size:10.5px;color:var(--faint);margin:14px 0 5px!important}
pre{font-family:'IBM Plex Mono',monospace;font-size:12.5px;line-height:1.6;background:var(--bg);border:1px solid var(--line);padding:12px 14px;overflow:auto;margin:0 0 13px;white-space:pre-wrap;overflow-wrap:anywhere}
.fact-scroll{overflow:auto;margin:0 0 13px}
.facts{border-collapse:collapse;width:100%;font-size:13px;background:var(--bg)}
.facts th,.facts td{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top;overflow-wrap:anywhere}
.facts th{width:28%;font-family:'IBM Plex Mono',monospace;font-size:11px;color:var(--dim);font-weight:500;background:var(--bg3)}
.callout,.recommendation{padding:9px 13px;margin:12px 0;font-size:13.5px}
.callout.note{border-left:3px solid var(--blue);background:#eef4f8}
.callout.warning{border-left:3px solid var(--orange);background:#fbf1e6}
.recommendation{border-left:3px solid var(--green);background:#f6f7e8}
.recommendation b{color:var(--green)}
fieldset{border:0;margin:16px 0 0;padding:0}
legend{font-size:10.5px;color:var(--faint);margin:0 0 7px;padding:0}
.option{display:block;border:1px solid var(--line);background:var(--bg);padding:11px 14px;margin:0 0 7px;cursor:pointer;font-size:14px;overflow-wrap:anywhere}
.option:hover{border-color:var(--blue)}
.option input{margin-right:9px}
.option-label{font-weight:600}
.option-consequence{display:block;margin-left:24px;color:var(--dim);font-size:13px;margin-top:2px}
.option:has(input:checked){border-color:var(--green);background:#f6f7e8;box-shadow:inset 3px 0 0 var(--green)}
textarea{width:100%;font:14px 'IBM Plex Sans',sans-serif;padding:9px 11px;border:1px solid var(--line);background:var(--bg);color:var(--fg);min-height:68px;resize:vertical;margin:0}
textarea:focus,.option input:focus-visible,button:focus-visible{outline:2px solid var(--blue);outline-offset:2px}
.note-label{font-size:10.5px;color:var(--faint);margin:14px 0 5px!important}
button.queue{font:600 14px 'IBM Plex Sans',sans-serif;padding:9px 20px;border:1px solid var(--fg);background:var(--fg);color:var(--bg);cursor:pointer;margin-top:12px}
button.queue:hover{background:var(--blue);border-color:var(--blue)}
.selected,.queued{display:none;margin-top:11px;padding:9px 13px;font-size:13.5px;overflow-wrap:anywhere}
.selected.on{display:block;border-left:3px solid var(--green);background:#f6f7e8}
.selected b{color:var(--green)}
.queued.on{display:block;border-left:3px solid var(--blue);background:#eef4f8}
.queued b{color:var(--blue)}
footer{margin-top:44px;padding-top:15px;border-top:1px solid var(--line);color:var(--faint);font-size:12px;font-family:'IBM Plex Mono',monospace}
@media(max-width:600px){.wrap{padding:24px 14px 64px}.top h1{font-size:27px}.question-heading,.question-body{padding-left:14px;padding-right:14px}.facts th{width:38%}}
</style>
</head>
<body>
<main class="wrap">
  <header class="top">
    <p class="eyebrow">${escapeHtml(input.board.eyebrow)}</p>
    <h1>${escapeHtml(input.board.title)}</h1>
    <p class="intro">${escapeHtml(input.board.introduction)}</p>
  </header>
  <div class="howto"><b>How this works.</b> Pick an option, add anything useful in the box, then press <b>Queue this answer</b>. Selection stays local until that button is pressed. Queued answers are still not sent until <b>Send to Agent</b> is pressed in the Lavish bar. Re-queueing the same question replaces its prior unsent answer.</div>
${sections}
  <footer>${escapeHtml(footer)}</footer>
</main>
<script id="fm-decision-surface-runtime">
(function () {
  function decisionForm(target) {
    return target && typeof target.closest === 'function'
      ? target.closest('form[data-lavish-question]')
      : null;
  }
  function values(form) {
    var data = new FormData(form);
    return {
      answer: (data.get('answer') || '').toString(),
      note: (data.get('note') || '').toString().trim()
    };
  }
  function summary(answer, note) {
    if (answer && note) return answer + ' - plus a note.';
    if (answer) return answer;
    if (note) return 'A note without an option.';
    return '';
  }
  document.addEventListener('change', function (event) {
    var form = decisionForm(event.target);
    if (!form) return;
    var draft = values(form);
    var box = form.querySelector('.selected');
    form.querySelector('.selected-text').textContent = summary(draft.answer, draft.note);
    box.classList.toggle('on', Boolean(draft.answer || draft.note));
  });
  document.addEventListener('submit', function (event) {
    var form = decisionForm(event.target);
    if (!form) return;
    event.preventDefault();
    var draft = values(form);
    if (!draft.answer && !draft.note) return;
    var title = form.dataset.decisionTitle;
    var message = title + ': ' + (draft.answer || '(no option selected)');
    if (draft.note) message += ' - additional note: ' + draft.note;
    window.lavish.queuePrompt(message, {
      tag: 'decision',
      text: title + (draft.answer ? ' -> ' + draft.answer : '') + (draft.note ? ' + note' : ''),
      element: form,
      queueKey: form.dataset.queueKey,
      data: {
        question: form.dataset.lavishQuestion,
        holdOwner: form.dataset.holdOwner,
        holdId: form.dataset.holdId,
        answer: draft.answer || null,
        note: draft.note || null
      }
    });
    form.querySelector('.queued-text').textContent = summary(draft.answer, draft.note);
    form.querySelector('.queued').classList.add('on');
  });
}());
</script>
</body>
</html>
`;
}

function writeAtomically(path, content) {
  const parent = dirname(path);
  mkdirSync(parent, { recursive: true });
  const temporary = join(parent, `.${fileURLToPath(import.meta.url).split('/').at(-1)}.${process.pid}.tmp`);
  try {
    writeFileSync(temporary, content, { encoding: 'utf8', mode: 0o600 });
    renameSync(temporary, path);
  } catch (error) {
    rmSync(temporary, { force: true });
    fail(`cannot write output ${path}: ${error.message}`);
  }
}

const options = parseArgs(process.argv.slice(2));
const input = validateInput(readJson(options.input, 'input'));
const snapshot = options.snapshot ? readJson(options.snapshot, 'snapshot') : freshSnapshot();
const holds = collectHolds(snapshot);
const html = renderBoard(input, holds);
writeAtomically(options.output, html);
process.stdout.write(`${options.output}\n`);
