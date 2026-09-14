#!/usr/bin/env bash
# Session-stamped attribution through the launch receipt and usage interfaces.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-usage)
export FM_HOME="$TMP_ROOT/home"
export CODEX_HOME="$TMP_ROOT/codex"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude"
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$CODEX_HOME/sessions" "$CLAUDE_CONFIG_DIR/projects/opaque" "$TMP_ROOT/pool"
export FM_CODEBURN_BIN="$TMP_ROOT/codeburn"
export FM_USAGE_FIXTURE="$TMP_ROOT/export.json"
cat > "$FM_CODEBURN_BIN" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then cp "$FM_USAGE_FIXTURE" "$2"; exit; fi
  shift
done
exit 2
STUB
chmod +x "$FM_CODEBURN_BIN"
for task in a b; do
  fm_write_meta "$FM_HOME/state/$task.meta" "worktree=$TMP_ROOT/pool" 'harness=codex' 'spawned_at=2026-09-13T00:00:00Z' 'kind=ship'
done
SESSION="$ROOT/bin/fm-task-session.mjs"
USAGE="$ROOT/bin/fm-task-usage.sh"
node "$SESSION" init a 2026-09-13T00:00:00Z || { fail 'initialize measured task identity'; exit 1; }
node "$SESSION" init b 2026-09-13T00:00:00Z || exit 1
stamp_a=$(node "$SESSION" register a codex "$TMP_ROOT/pool") || exit 1
stamp_b=$(node "$SESSION" register b codex "$TMP_ROOT/pool") || exit 1
export stamp_a stamp_b
node - "$CODEX_HOME/sessions" "$TMP_ROOT/pool" "$FM_USAGE_FIXTURE" <<'JS'
const fs=require('fs'); const [dir,cwd,out]=process.argv.slice(2)
const records=[]
for(const [id,stamp,cost] of [['a1',process.env.stamp_a,2],['b1',process.env.stamp_b,7],['unstamped','',99],['outside',process.env.stamp_a,100]]) {
 fs.writeFileSync(`${dir}/${id}.jsonl`,JSON.stringify({type:'session_meta',payload:{id,originator:stamp,cwd:id==='outside'?`${cwd}-other`:cwd,timestamp:'1900-01-01',forked_from_id:'a1'}})+'\n')
 records.push({sessionId:id,provider:'codex',model:'GPT-5',cost,inputTokens:10,outputTokens:20,cacheReadTokens:30,cacheWriteTokens:0})
}
fs.writeFileSync(out,JSON.stringify({schema:'codeburn.export.v2',currency:{code:'USD',rate:1},records}))
JS
json=$("$USAGE" a --json) || exit 1
node -e 'const x=JSON.parse(process.argv[1]); if(x.cost_usd!==2||x.sessions!==1||x.correlation.attribution!=="session-stamp")process.exit(1)' "$json" && pass 'exact stamp and directory containment exclude sequential owner and outside copy' || fail 'task a attribution'
json=$("$USAGE" b --json) || exit 1
node -e 'if(JSON.parse(process.argv[1]).cost_usd!==7)process.exit(1)' "$json" && pass 'second task reports only its own spend' || fail 'task b attribution'
stamp_a2=$(node "$SESSION" register a claude "$TMP_ROOT/pool") || exit 1
export stamp_a2
node - "$CLAUDE_CONFIG_DIR/projects/opaque" "$TMP_ROOT/pool" "$FM_USAGE_FIXTURE" <<'JS'
const fs=require('fs'); const [dir,cwd,out]=process.argv.slice(2); const stamp=process.env.stamp_a2
fs.writeFileSync(`${dir}/${stamp}.jsonl`,JSON.stringify({sessionId:stamp,cwd})+'\n')
fs.mkdirSync(`${dir}/${stamp}/subagents`,{recursive:true})
fs.writeFileSync(`${dir}/${stamp}/subagents/agent-child.jsonl`,JSON.stringify({sessionId:stamp,cwd})+'\n')
const x=JSON.parse(fs.readFileSync(out));
for (const [sessionId,cost] of [[stamp,3],['agent-child',5]]) x.records.push({sessionId,provider:'claude',model:'Opus 5',cost,inputTokens:1,outputTokens:2,cacheReadTokens:3,cacheWriteTokens:4})
fs.writeFileSync(out,JSON.stringify(x))
JS
"$USAGE" a --snapshot >/dev/null || exit 1
json=$("$USAGE" a --json) || exit 1
node -e 'const x=JSON.parse(process.argv[1]); if(x.cost_usd!==10||x.sessions!==3||x.actual_models.join()!==x.models.map(m=>m.name).join())process.exit(1)' "$json" && pass 'runtime switch retains whole spend and structural Claude descendants' || fail 'whole spend'
mv "$CODEX_HOME/sessions" "$CODEX_HOME/saved"
if "$USAGE" a --json >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'missing previous store refused'; else
  assert_contains 'error names previous runtime store' "$(cat "$TMP_ROOT/err")" "$CODEX_HOME/sessions"
fi
mv "$CODEX_HOME/saved" "$CODEX_HOME/sessions"
rm "$CODEX_HOME/sessions/a1.jsonl"
if "$USAGE" a --json >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'lost measured session refused'; else
  assert_contains 'error names lost session' "$(cat "$TMP_ROOT/err")" "$CODEX_HOME/sessions/a1.jsonl"
fi
fm_write_meta "$FM_HOME/state/legacy.meta" "worktree=$TMP_ROOT/pool" 'harness=codex' 'spawned_at=2026-09-13T00:00:00Z'
if "$USAGE" legacy --json >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'legacy attribution refused'; else pass 'unmeasured task has no inferred backfill'; fi
summary
