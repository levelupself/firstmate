#!/usr/bin/env bash
# Behavior tests for generated Lavish decision surfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GENERATOR="$ROOT/bin/fm-decision-surface.mjs"
TMP_ROOT=$(fm_test_tmproot fm-decision-surface)
SNAPSHOT="$TMP_ROOT/snapshot.json"
INPUT="$TMP_ROOT/input.json"
OUTPUT="$TMP_ROOT/board.html"

cat > "$SNAPSHOT" <<'JSON'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-08-31T15:00:00Z",
  "fm_home": "/example/main",
  "backlog": {
    "records": [
      {
        "id": "alpha-decision-route",
        "state": "queued",
        "structured": true,
        "title": "Choose the rollout route",
        "repo": "alpha",
        "kind": "captain",
        "hold_kind": "captain",
        "hold_reason": "The release cannot start until one route is chosen.",
        "captain_actionable": true,
        "captain_decision": {"origin": "alpha", "key": "route"}
      },
      {
        "id": "alpha-decision-blocked",
        "state": "queued",
        "structured": true,
        "title": "Blocked decision",
        "kind": "captain",
        "hold_kind": "captain",
        "hold_reason": "A dependency is still open.",
        "captain_actionable": false
      }
    ]
  },
  "secondmate_current": {
    "records": [
      {
        "id": "games-mate",
        "home": "/example/games",
        "provenance": {"selected": "structured-home"},
        "decisions_open": [
          {
            "id": "beta-decision-scope",
            "key": "beta-decision-scope",
            "verb": "captain-hold",
            "summary": "Choose the engine scope",
            "reason": "The architecture changes with this boundary.",
            "source": "backlog"
          }
        ]
      }
    ]
  }
}
JSON

cat > "$INPUT" <<'JSON'
{
  "schema": "fm-decision-surface-input.v1",
  "board": {
    "eyebrow": "Captain's calls · 31 August 2026",
    "title": "Two things waiting on you",
    "introduction": "Each question includes the evidence needed to act.",
    "footer": "Answer either or both."
  },
  "groups": [
    {"id": "blocking", "title": "Blocking work", "description": "These stop active work."},
    {"id": "direction", "title": "Direction", "description": "This sets the next boundary."}
  ],
  "decisions": [
    {
      "hold": {"owner": "main", "id": "alpha-decision-route"},
      "group": "blocking",
      "context": "alpha · release route",
      "priority": "blocking",
      "evidence": [
        {"kind": "paragraph", "text": "The old route executes <script>alert('unsafe')</script> before validation."},
        {"kind": "schematic", "title": "Observed flow", "lines": ["request -> old route -> side effect", "request -> guarded route -> validation"]},
        {"kind": "facts", "title": "Measured consequences", "rows": [
          {"label": "Old route", "value": "One write before validation"},
          {"label": "Guarded route", "value": "Zero writes before validation"}
        ]},
        {"kind": "callout", "tone": "warning", "label": "Risk", "text": "The old route can publish an invalid release."}
      ],
      "recommendation": {"label": "Recommendation", "text": "Use the guarded route because it preserves the validation boundary."},
      "options": [
        {"label": "Use the guarded route", "answer": "use the guarded route for the release", "consequence": "Adds one validation step and prevents premature writes."},
        {"label": "Keep the old route", "answer": "keep the old route for the release", "consequence": "Ships sooner but retains the premature-write risk."}
      ],
      "note_placeholder": "Optional constraints or a different route"
    },
    {
      "hold": {"owner": "games-mate", "id": "beta-decision-scope"},
      "group": "direction",
      "context": "beta · engine architecture",
      "evidence": [
        {"kind": "paragraph", "text": "The narrow model handles the measured cases; the wide model adds two unsolved states."}
      ],
      "recommendation": null,
      "options": [
        {"label": "Narrow scope", "answer": "ship the narrow engine scope", "consequence": "Covers measured cases with one model."},
        {"label": "Wide scope", "answer": "ship the wide engine scope", "consequence": "Adds two states that still need design work."}
      ]
    }
  ]
}
JSON

node "$GENERATOR" --input "$INPUT" --snapshot "$SNAPSHOT" --output "$OUTPUT"

OUTPUT="$OUTPUT" node <<'JS'
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(process.env.OUTPUT, 'utf8');
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

assert((html.match(/<form\b/g) || []).length === 2, 'expected one form per decision');
assert((html.match(/<textarea\b/g) || []).length === 2, 'expected one free-text box per decision');
assert((html.match(/<button type="submit"/g) || []).length === 2, 'expected one queue control per decision');
assert(html.includes('Choose the rollout route'), 'main hold title did not come from the snapshot');
assert(html.includes('The release cannot start until one route is chosen.'), 'main hold reason is absent');
assert(html.includes('Choose the engine scope'), 'secondmate hold title did not come from the snapshot');
assert(html.includes('The architecture changes with this boundary.'), 'secondmate hold reason is absent');
assert(html.includes('&lt;script&gt;alert(&#39;unsafe&#39;)&lt;/script&gt;'), 'evidence text was not escaped');
assert(!html.includes("<script>alert('unsafe')</script>"), 'untrusted evidence became executable markup');
assert(html.includes('Observed flow') && html.includes('Measured consequences'), 'schematic or fact evidence is absent');
assert((html.match(/class="recommendation"/g) || []).length === 1, 'explicit no-recommendation decision rendered a recommendation');

const runtime = html.match(/<script id="fm-decision-surface-runtime">([\s\S]*?)<\/script>/);
assert(runtime, 'generated board has no executable decision runtime');

const listeners = {};
const queueCalls = [];
const document = {
  addEventListener(type, handler) { listeners[type] = handler; }
};
const window = {
  lavish: {
    queuePrompt(message, options) { queueCalls.push({message, options}); }
  }
};
class FakeFormData {
  constructor(form) { this.form = form; }
  get(name) { return this.form.values[name] ?? null; }
}
const selectedText = {textContent: ''};
const selectedBox = {classList: {toggle() {}}};
const queuedText = {textContent: ''};
const queuedBox = {classList: {add() {}}};
const form = {
  dataset: {
    lavishQuestion: 'main__alpha-decision-route',
    queueKey: 'decision:main:alpha-decision-route',
    decisionTitle: 'Choose the rollout route'
  },
  values: {answer: 'use the guarded route for the release', note: 'Keep the audit log.'},
  closest(selector) { return selector === 'form[data-lavish-question]' ? this : null; },
  querySelector(selector) {
    return {
      '.selected': selectedBox,
      '.selected-text': selectedText,
      '.queued': queuedBox,
      '.queued-text': queuedText
    }[selector];
  }
};
const event = {target: form, preventDefault() { this.prevented = true; }};

vm.runInNewContext(runtime[1], {window, document, FormData: FakeFormData});
listeners.change(event);
assert(queueCalls.length === 0, 'changing a radio queued a prompt before submit');
assert(selectedText.textContent.includes('use the guarded route'), 'local selected state was not displayed');

listeners.submit(event);
assert(queueCalls.length === 1, 'one submit did not queue exactly one prompt');
assert(queueCalls[0].message.includes('use the guarded route for the release'), 'queued prompt omitted the actionable answer text');
assert(queueCalls[0].message.includes('Keep the audit log.'), 'queued prompt omitted the free-text note');
assert(queueCalls[0].options.queueKey === 'decision:main:alpha-decision-route', 'queued prompt omitted the durable replacement key');
assert(queueCalls[0].options.data.answer === 'use the guarded route for the release', 'structured queued data omitted the answer');
assert(queuedText.textContent.includes('use the guarded route'), 'queued state was not displayed separately');

form.values.answer = 'keep the old route for the release';
listeners.change(event);
assert(queueCalls.length === 1, 'changing a queued answer enqueued a second prompt');
assert(selectedText.textContent.includes('keep the old route'), 'changed local selection was not shown');
assert(queuedText.textContent.includes('use the guarded route'), 'queued state changed before resubmission');

listeners.submit(event);
assert(queueCalls.length === 2, 'resubmitting did not make exactly one replacement call');
assert(queueCalls[1].options.queueKey === queueCalls[0].options.queueKey, 're-answer did not reuse queueKey');
JS

if node "$GENERATOR" --input "$INPUT" --snapshot "$TMP_ROOT/missing.json" --output "$OUTPUT" \
  >"$TMP_ROOT/missing.out" 2>&1; then
  fail "generator accepted a missing fleet snapshot"
fi
assert_grep "cannot read snapshot" "$TMP_ROOT/missing.out" \
  "missing snapshot failure should be actionable"

jq '.decisions[0].hold.id = "alpha-decision-blocked"' "$INPUT" > "$TMP_ROOT/blocked.json"
if node "$GENERATOR" --input "$TMP_ROOT/blocked.json" --snapshot "$SNAPSHOT" --output "$OUTPUT" \
  >"$TMP_ROOT/blocked.out" 2>&1; then
  fail "generator accepted a non-actionable captain hold"
fi
assert_grep "not an actionable structured captain hold" "$TMP_ROOT/blocked.out" \
  "non-actionable hold failure should explain the source contract"

pass "decision surfaces render durable holds and queue one complete answer per submit"
