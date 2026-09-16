# shellcheck shell=bash
fm_assert_task_launch() {
  local command=$1 binary=$2 worktree=$3 data=$4 id=$5 store=$6 capture
  shift 6
  capture="$data/$id/runtime.json"
  cat > "$binary" <<'NODE'
#!/usr/bin/env node
const fs=require('fs'),path=require('path')
const args=process.argv.slice(2),env=process.env
const keys=['CURSOR_AGENT','CURSOR_INVOKED_AS','CLAUDE_CONFIG_DIR','CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION','CLAUDE_CODE_SEND_FEEDBACK']
fs.writeFileSync(env.FM_TEST_RUNTIME_CAPTURE,JSON.stringify({args,env:Object.fromEntries(keys.filter(k=>env[k]!==undefined).map(k=>[k,env[k]])),cwd:process.cwd(),binary:process.argv[1]}))
const at=args.indexOf('--session-id')
if(at>=0) {
  const dir=path.join(env.CLAUDE_CONFIG_DIR,'projects','fixture')
  fs.mkdirSync(dir,{recursive:true})
  fs.writeFileSync(path.join(dir,args[at+1]+'.jsonl'),JSON.stringify({sessionId:args[at+1],cwd:process.cwd()})+'\n')
}
NODE
  chmod +x "$binary"
  (
    cd "$worktree" || exit 1
    PATH="$(dirname "$binary"):$PATH" CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
      CLAUDE_CONFIG_DIR="$store" FM_TEST_RUNTIME_CAPTURE="$capture" bash -c "$command"
  ) || fail 'delivered launch command failed'
  node - "$capture" "$data/$id/sessions/launches.jsonl" "$binary" "$worktree" "$store" "$@" <<'NODE' || fail 'runtime arguments, isolation, or stamp registration differ'
const fs=require('fs'),assert=require('assert/strict')
const [file,ledger,binary,cwd,store,...expected]=process.argv.slice(2)
const actual=JSON.parse(fs.readFileSync(file)),args=[...actual.args]
assert.equal(actual.binary,binary)
assert.equal(actual.cwd,fs.realpathSync(cwd))
const custom=binary.endsWith('/custom-agent')
assert.equal(actual.env.CURSOR_AGENT,custom?'1':undefined)
assert.equal(actual.env.CURSOR_INVOKED_AS,custom?'cursor-agent':undefined)
const rows=fs.readFileSync(ledger,'utf8').trim().split('\n').map(JSON.parse),receipt=rows.at(-1)
assert.equal(receipt.worktree,fs.realpathSync(cwd))
assert.match(receipt.stamp,/^[0-9a-f-]{36}$/)
if(binary.endsWith('/claude')) {
  const at=args.indexOf('--session-id')
  assert.ok(at>=0)
  assert.equal(args[at+1],receipt.stamp)
  args.splice(at,2)
  assert.equal(receipt.harness,'claude')
  assert.equal(receipt.store,store)
  assert.equal(actual.env.CLAUDE_CONFIG_DIR,store)
  assert.equal(actual.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION,'false')
  assert.equal(actual.env.CLAUDE_CODE_SEND_FEEDBACK,'0')
} else {
  assert.equal(receipt.harness,custom?'custom-agent':'kimi')
  assert.equal(receipt.store,null)
}
assert.deepEqual(args,expected)
NODE
}

fm_assert_claude_launch() {
  local command=$1 binary=$2 worktree=$3 data=$4 id=$5 store=$6 brief
  shift 6
  brief=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$data/$id/brief.md") || exit 1
  fm_assert_task_launch "$command" "$binary" "$worktree" "$data" "$id" "$store" \
    --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' "$@" "$brief"
}
