#!/usr/bin/env bash
# Synthetic-only behavioral coverage for deterministic offload proposals.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-offload-candidates)
HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$HOME_FIXTURE/data" "$HOME_FIXTURE/.agents/skills/tracked" "$HOME_FIXTURE/.agents/skills/local"
git init -q "$HOME_FIXTURE"
cat > "$HOME_FIXTURE/.agents/skills/tracked/SKILL.md" <<'SKILL'
---
name: tracked
description: Use before astronomy telescope calibration.
---
SKILL
git -C "$HOME_FIXTURE" add .agents/skills/tracked
cat > "$HOME_FIXTURE/.agents/skills/local/SKILL.md" <<'SKILL'
---
name: local
description: >-
  Use before astronomy telescope calibration.
---
SKILL
cat > "$HOME_FIXTURE/data/captain.md" <<'MEMORY'
# Preferences
<!-- memory tiers: see the stow skill -->
- Default preference without marker.
- Astronomy preference. <!--a:2026-10-01-->
MEMORY
cat > "$HOME_FIXTURE/data/captain-shared.md" <<'MEMORY'
# Shared
A shared preference paragraph.
MEMORY
cat > "$HOME_FIXTURE/data/learnings.md" <<'MEMORY'
# Learnings
## Optics
- Astronomy telescope calibration for observatory requires several steps. <!--a:2026-10-01-->
  Continuation and nested content:
  - Keep the nested list with its parent.

  Final continuation paragraph.
- Temporary astronomy condition. <!--p:2026-10-02-->
- Explicit safety boundary. <!--P-->
- Legacy grace entry. <!--g-->
- Unmarked legacy entry.

## Notes
Paragraph first line.
Second line with é.

```text
# This is fenced content, not a section
- This is fenced content, not a new entry
```
MEMORY
cat > "$HOME_FIXTURE/data/projects.md" <<'REGISTRY'
# Projects
- observatory [no-mistakes +yolo] - Synthetic optics project (added 2026-10-01)
- absent [local-only] - Unmentioned project (added 2026-10-01)
REGISTRY
HELPER="$ROOT/bin/fm-memory-offload-candidates.sh"
FM_HOME="$HOME_FIXTURE" "$HELPER" --json > "$TMP_ROOT/one.json" || fail "candidate helper must run"
FM_HOME="$HOME_FIXTURE" "$HELPER" --json > "$TMP_ROOT/two.json"
cmp -s "$TMP_ROOT/one.json" "$TMP_ROOT/two.json" || fail "identical inputs changed JSON bytes"
FM_HOME="$HOME_FIXTURE" "$HELPER" > "$TMP_ROOT/one.tsv"
FM_HOME="$HOME_FIXTURE" "$HELPER" > "$TMP_ROOT/two.tsv"
cmp -s "$TMP_ROOT/one.tsv" "$TMP_ROOT/two.tsv" || fail "identical inputs changed table bytes"
node --input-type=module - "$TMP_ROOT/one.json" "$HOME_FIXTURE" "$TMP_ROOT/one.tsv" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
const rows = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const table = fs.readFileSync(process.argv[4], 'utf8').trimEnd().split('\n').map(line => line.split('\t'));
assert.deepEqual(table[0], ['id', 'file', 'section', 'tier', 'marker', 'estimated_tokens', 'skills', 'projects']);
assert.deepEqual(table.slice(1).map(row => row[0]), rows.map(row => row.id));
assert.equal(rows.length, 10, 'headings/comments excluded; nested lists and fences stay within entries');
const optics = rows.find(r => r.projects.includes('observatory'));
assert.ok(optics);
assert.equal(optics.section, 'Learnings / Optics');
assert.equal(optics.tier, 'aging');
assert.equal(optics.marker, '<!--a:2026-10-01-->');
assert.deepEqual(optics.skills, ['local']);
assert.ok(rows.every(r => !r.skills.includes('tracked')));
const source = fs.readFileSync(`${process.argv[3]}/data/learnings.md`, 'utf8');
const text = source.slice(source.indexOf('- Astronomy'), source.indexOf('- Temporary')).trimEnd();
assert.equal(optics.estimated_tokens, Math.ceil(Buffer.byteLength(text) / 3));
const first = text.split('\n')[0];
assert.equal(optics.id, `data/learnings.md:${crypto.createHash('sha256').update(first).digest('hex')}`);
assert.equal(rows.find(r => r.marker === '<!--P-->').tier, 'pinned');
assert.equal(rows.find(r => r.marker === '<!--p:2026-10-02-->').tier, 'perishable');
assert.equal(rows.find(r => r.marker === '<!--g-->').tier, 'aging');
assert.equal(rows.filter(r => r.file === 'data/captain.md' && r.marker === '').every(r => r.tier === 'pinned'), true);
assert.ok(rows.some(r => r.file === 'data/learnings.md' && r.marker === '' && r.tier === 'aging'));
for (let i = 1; i < rows.length; i++) {
  assert.ok(rows[i - 1].estimated_tokens >= rows[i].estimated_tokens);
  if (rows[i - 1].estimated_tokens === rows[i].estimated_tokens) assert.ok(rows[i - 1].id <= rows[i].id);
}
JS
pass "stable ranked proposals parse entries, tiers, token estimates, and private-owner hints"
# Metadata errors must not silently omit input or follow unsafe files.
rm "$HOME_FIXTURE/data/learnings.md"
ln -s "$HOME_FIXTURE/data/captain.md" "$HOME_FIXTURE/data/learnings.md"
if FM_HOME="$HOME_FIXTURE" "$HELPER" --json > /dev/null 2> "$TMP_ROOT/error"; then
  fail "symlinked memory must reject proposals"
fi
assert_contains "$(<"$TMP_ROOT/error")" 'ordinary regular file' "unsafe file diagnostic missing"
pass "unsafe memory is rejected without proposing an incomplete sweep"
rm "$HOME_FIXTURE/data/learnings.md" "$HOME_FIXTURE/data/captain.md" "$HOME_FIXTURE/data/captain-shared.md" "$HOME_FIXTURE/data/projects.md"
FM_HOME="$HOME_FIXTURE" "$HELPER" --json > "$TMP_ROOT/empty.json"
[ "$(<"$TMP_ROOT/empty.json")" = '[]' ] || fail "absent memory should propose nothing"
pass "absent memory and registry are empty inputs"
