#!/usr/bin/env bash
# Opt-in real-CLI stamp creation check. Empty private homes and invalid auth
# deliberately prevent paid calls; the assertion concerns persisted creation
# metadata only, not successful inference, billing, or descendant inheritance.
set -u
if [ "${FM_TASK_SESSION_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_TASK_SESSION_LIVE_E2E=1 to verify real CLI session stamps'
  exit 0
fi
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-task-session-live)
export FM_HOME="$LAB/home"
export CODEX_HOME="$LAB/codex"
export CLAUDE_CONFIG_DIR="$LAB/claude"
mkdir -p "$LAB/project" "$FM_HOME/data" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
SESSION="$ROOT/bin/fm-task-session.mjs"
node "$SESSION" init live 2026-09-13T00:00:00Z || fail 'init live identity'
checked=0
for harness in claude codex; do
  if ! command -v "$harness" >/dev/null; then
    echo "skip: $harness not installed"
    continue
  fi
  version=$("$harness" --version)
  stamp=$(node "$SESSION" register live "$harness" "$LAB/project") || fail "$harness registration"
  if [ "$harness" = claude ]; then
    (cd "$LAB/project" && env -u CLAUDECODE ANTHROPIC_API_KEY=stamp-test-invalid ANTHROPIC_BASE_URL=http://127.0.0.1:1 timeout 25 claude -p --session-id "$stamp" --max-turns 1 'Reply OK without tools.') >"$LAB/claude-output" 2>&1 || true
  else
    (cd "$LAB/project" && env -u OPENAI_API_KEY CODEX_INTERNAL_ORIGINATOR_OVERRIDE="$stamp" timeout 25 codex exec --skip-git-repo-check -c 'model_reasoning_effort="low"' 'Reply OK without tools.' </dev/null) >"$LAB/codex-output" 2>&1 || true
  fi
  node --input-type=module - "$SESSION" live "$stamp" "$harness" <<'JS' || fail "$harness $version did not persist a readable creation stamp"
const [moduleFile,id,stamp,harness]=process.argv.slice(2)
const {index}=await import(moduleFile)
const sessions=index(id)
if(!sessions.some(row=>row.stamp===stamp&&row.provider===harness))process.exit(1)
JS
  checked=$((checked+1))
  pass "$version persisted exact stamp and directory before the unauthenticated call failed"
done
[ "$checked" -gt 0 ] || fail 'no installed stamping runtime checked'
