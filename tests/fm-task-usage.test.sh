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
cat "$FM_USAGE_FIXTURE"
STUB
chmod +x "$FM_CODEBURN_BIN"
for task in a b; do
  fm_write_meta "$FM_HOME/state/$task.meta" "worktree=$TMP_ROOT/pool" 'harness=codex' 'spawned_at=2026-09-13T00:00:00Z' 'kind=ship'
done
SESSION="$ROOT/bin/fm-task-session.mjs"
USAGE="$ROOT/bin/fm-task-usage.sh"
node "$SESSION" init a 2026-09-13T00:00:00Z || fail 'initialize measured task identity'
node "$SESSION" init b 2026-09-13T00:00:00Z || exit 1
stamp_a=$(node "$SESSION" register a codex "$TMP_ROOT/pool") || exit 1
stamp_b=$(node "$SESSION" register b codex "$TMP_ROOT/pool") || exit 1
export stamp_a stamp_b
node - "$CODEX_HOME/sessions" "$TMP_ROOT/pool" "$FM_USAGE_FIXTURE" <<'JS'
const fs=require('fs'); const [dir,cwd,out]=process.argv.slice(2)
const records=[]
for(const [id,stamp,cost] of [['a1',process.env.stamp_a,2],['b1',process.env.stamp_b,7],['unstamped','',99],['outside',process.env.stamp_a,100]]) {
 fs.writeFileSync(`${dir}/${id}.jsonl`,JSON.stringify({type:'session_meta',payload:{id,originator:stamp,cwd:id==='outside'?`${cwd}-other`:cwd,timestamp:'1900-01-01',forked_from_id:'a1'}})+'\n')
 records.push({sessionId:id,provider:'codex',models:['GPT-5'],calls:1,cost,inputTokens:10,outputTokens:20,cacheReadTokens:30,cacheWriteTokens:0})
}
fs.writeFileSync(out,JSON.stringify(records))
JS
json=$("$USAGE" a --json) || exit 1
node -e 'const x=JSON.parse(process.argv[1]); if(x.cost_usd!==2||x.sessions!==1||x.correlation.attribution!=="session-stamp")process.exit(1)' "$json" || fail 'task a attribution'
pass 'exact stamp and directory containment exclude sequential owner and outside copy'
json=$("$USAGE" b --json) || exit 1
node -e 'if(JSON.parse(process.argv[1]).cost_usd!==7)process.exit(1)' "$json" || fail 'task b attribution'
pass 'second task reports only its own spend'
cp "$FM_HOME/data/a/sessions/identity.json" "$TMP_ROOT/original-identity.json"
cp "$FM_HOME/data/a/sessions/launches.jsonl" "$TMP_ROOT/original-launches.jsonl"
"$USAGE" a --snapshot >/dev/null || exit 1
cp "$FM_HOME/data/a/usage.json" "$TMP_ROOT/original-usage.json"
node "$SESSION" init a 2026-09-14T00:00:00Z || fail 'repeat initialization preserves task identity'
cmp "$FM_HOME/data/a/sessions/identity.json" "$TMP_ROOT/original-identity.json" || fail 'retry changed identity'
cmp "$FM_HOME/data/a/sessions/launches.jsonl" "$TMP_ROOT/original-launches.jsonl" || fail 'retry changed receipts before activation'
cmp "$FM_HOME/data/a/usage.json" "$TMP_ROOT/original-usage.json" || fail 'retry changed measured spend'
relaunch=$(node "$SESSION" register a codex "$TMP_ROOT/pool") || exit 1
node - "$FM_HOME/data/a/sessions/launches.jsonl" "$stamp_a" "$relaunch" <<'JS' || fail 'two incarnations retain original receipt'
const fs=require('fs');const [file,original,next]=process.argv.slice(2)
const rows=fs.readFileSync(file,'utf8').trim().split('\n').map(JSON.parse)
if(rows.length!==2||rows[0].stamp!==original||rows[1].stamp!==next||original===next)process.exit(1)
JS
node - "$CODEX_HOME/sessions/relaunch.jsonl" "$TMP_ROOT/pool" "$relaunch" "$FM_USAGE_FIXTURE" <<'JS'
const fs=require('fs');const [file,cwd,stamp,out]=process.argv.slice(2)
fs.writeFileSync(file,JSON.stringify({type:'session_meta',payload:{id:'relaunch',cwd,originator:stamp}})+'\n')
const x=JSON.parse(fs.readFileSync(out));x.push({sessionId:'relaunch',provider:'codex',models:['GPT-5','GPT-6'],calls:1,cost:1.004,inputTokens:1,outputTokens:1,cacheReadTokens:0,cacheWriteTokens:0});fs.writeFileSync(out,JSON.stringify(x))
JS
json=$("$USAGE" a --json) || exit 1
node -e 'const x=JSON.parse(process.argv[1]);if(x.cost_usd!==3.004||x.sessions!==2)process.exit(1)' "$json" || fail 'relaunch whole spend'
pass 'same-runtime relaunch includes both incarnations'
node "$SESSION" init a 2026-09-15T00:00:00Z || fail 'runtime switch preserves task identity'
stamp_a2=$(node "$SESSION" register a claude "$TMP_ROOT/pool") || exit 1
export stamp_a2
node - "$CLAUDE_CONFIG_DIR/projects/opaque" "$TMP_ROOT/pool" "$FM_USAGE_FIXTURE" <<'JS'
const fs=require('fs'); const [dir,cwd,out]=process.argv.slice(2); const stamp=process.env.stamp_a2
fs.writeFileSync(`${dir}/${stamp}.jsonl`,JSON.stringify({sessionId:stamp,cwd})+'\n')
fs.mkdirSync(`${dir}/${stamp}/subagents`,{recursive:true})
fs.writeFileSync(`${dir}/${stamp}/subagents/agent-child.jsonl`,JSON.stringify({sessionId:stamp,cwd})+'\n')
const x=JSON.parse(fs.readFileSync(out));
for (const [sessionId,cost] of [[stamp,3],['agent-child',5]]) x.push({sessionId,provider:'claude',models:['Opus 5'],calls:1,cost,inputTokens:1,outputTokens:2,cacheReadTokens:3,cacheWriteTokens:4})
fs.writeFileSync(out,JSON.stringify(x))
JS
"$USAGE" a --snapshot >/dev/null || exit 1
json=$("$USAGE" a --json) || exit 1
node -e 'const x=JSON.parse(process.argv[1]); if(x.cost_usd!==11.004||x.sessions!==4||x.actual_models.join()!==x.models.map(m=>m.name).join())process.exit(1)' "$json" || fail 'whole spend'
pass 'runtime switch retains whole spend and structural Claude descendants'
node -e 'const x=JSON.parse(process.argv[1]);if(x.models.find(m=>m.name==="GPT-5").cost_usd!==null||x.models.find(m=>m.name==="Opus 5").cost_usd!==8)process.exit(1)' "$json" || fail 'mixed model costs must remain unknown'
node --input-type=module - "$FM_HOME/data/effort-store.sqlite" <<'JS' || fail 'effort store rejected stamped mixed-model totals'
const {DatabaseSync}=await import('node:sqlite')
const db=new DatabaseSync(process.argv[2],{readOnly:true})
const task=db.prepare("SELECT notional_cost_usd FROM task WHERE task_id='a'").get()
const models=db.prepare("SELECT model,notional_cost_usd FROM task_model WHERE task_id='a'").all()
if(task?.notional_cost_usd!==11.004||models.find(x=>x.model==='GPT-5')?.notional_cost_usd!==null||models.find(x=>x.model==='Opus 5')?.notional_cost_usd!==8)process.exit(1)
JS
pass 'precise task cost survives the effort-store join with unknown mixed-model amounts'

mv "$CODEX_HOME/sessions" "$CODEX_HOME/saved"
if "$USAGE" a --json >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'missing previous store refused'; else
  assert_contains "$(cat "$TMP_ROOT/err")" "$CODEX_HOME/sessions" 'error names previous runtime store'
fi
mv "$CODEX_HOME/saved" "$CODEX_HOME/sessions"
rm "$CODEX_HOME/sessions/a1.jsonl"
if "$USAGE" a --json >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'lost measured session refused'; else
  assert_contains "$(cat "$TMP_ROOT/err")" "$CODEX_HOME/sessions/a1.jsonl" 'error names lost session'
fi
fm_write_meta "$FM_HOME/state/legacy.meta" "worktree=$TMP_ROOT/pool" 'harness=codex' 'spawned_at=2026-09-13T00:00:00Z'
if "$USAGE" legacy --json >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'legacy attribution refused'; else pass 'unmeasured task has no inferred backfill'; fi
pass 'unreadable stores and lost measured sessions refuse by name'
for missing in identity.json launches.jsonl; do
  node "$SESSION" init damaged 2026-09-13T00:00:00Z || exit 1
  mv "$FM_HOME/data/damaged/sessions/$missing" "$TMP_ROOT/$missing"
  if node "$SESSION" init damaged 2026-09-14T00:00:00Z >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail "retry accepted missing $missing"
  fi
  [ ! -e "$FM_HOME/data/damaged/sessions/$missing" ] || fail "retry recreated missing $missing"
  mv "$TMP_ROOT/$missing" "$FM_HOME/data/damaged/sessions/$missing"
done
pass 'retry refuses incomplete coverage without recreating missing files'
