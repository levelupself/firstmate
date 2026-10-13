#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
node --input-type=module <<'NODE'
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import assert from 'node:assert/strict'
import {captureSkills,skillSnapshots} from './bin/fm-effort-skills.mjs'
const home=fs.mkdtempSync(path.resolve('.skill-test-'))
try {
  process.env.CODEX_HOME=home+'/codex'
  process.env.CLAUDE_CONFIG_DIR=home+'/claude'
  process.env.FM_HOME=home
  const file=home+'/project/.agents/skills/synthetic-demo/SKILL.md'
  fs.mkdirSync(path.dirname(file),{recursive:true})
  fs.mkdirSync(home+'/codex/sessions',{recursive:true})
  const short='---\nname: synthetic-demo\ndescription: Execute widget-build.\n---\nBody.\n'
  const historical=short+'Historical trailing section.\n'
  fs.writeFileSync(file,short)
  const rows=[{type:'session_meta',payload:{id:'synthetic-session',cwd:home,timestamp:'2026-01-01T00:00:00Z'}},{type:'turn_context'}]
  const call=(id,cmd,output)=>{
    rows.push({type:'response_item',payload:{type:'function_call',name:'exec_command',call_id:id,arguments:JSON.stringify({cmd})}})
    rows.push({type:'response_item',payload:{type:'function_call_output',call_id:id,output}})
  }
  call('whole',`cat '${file}'`,JSON.stringify({output:historical,exit_code:0}))
  call('false-load',`cat README.md; echo ${file}`,historical)
  call('failed',`cat '${file}'`,JSON.stringify({output:historical,exit_code:1}))
  call('partial',`head -n 5 '${file}'`,short)
  call('truncated',`cat '${file}'`,{output:short,truncated:true,exit_code:0})
  rows.push({type:'turn_context'},{type:'turn_context'},{type:'turn_context'})
  const options={homeDir:home,rootDir:home,dataDir:home+'/data',stateDir:home+'/state'}
  const capture=()=>{
    fs.writeFileSync(home+'/codex/sessions/demo.jsonl',rows.map(r=>JSON.stringify(r)).join('\n')+'\n')
    captureSkills(options,[{taskId:'synthetic-task',raw:{project:home+'/project'}}],true)
    const snapshot=skillSnapshots(options).find(s=>s.identity?.kind==='primary-session')
    snapshot.events.sort((a,b)=>Number(a.log_offset.split(':')[0])-Number(b.log_offset.split(':')[0]))
    return snapshot
  }
  let snapshot=capture()
  assert.equal(snapshot.events.length,3)
  assert.equal(snapshot.events[0].skill_sha,crypto.createHash('sha256').update(historical).digest('hex').slice(0,12))
  assert.equal(snapshot.events[0].followed_by_use,null)
  assert.equal(snapshot.events[0].scope,'project')
  assert.equal(snapshot.events[1].skill_sha,null)
  assert.equal(snapshot.events[2].skill_sha,null)
  const snapshotFile=home+'/data/'+snapshot.task+'/skill-usage.json'
  snapshot.events[0].followed_by_use=false
  fs.writeFileSync(snapshotFile,JSON.stringify(snapshot))
  call('use','widget-build','done')
  fs.rmSync(home+'/project',{recursive:true})
  snapshot=capture()
  assert.equal(snapshot.events[0].followed_by_use,true)
  assert.equal(snapshot.events[0].scope,'project')
  rows.splice(rows.length-2,2)
  rows.push({type:'turn_context'})
  fs.rmSync(snapshotFile)
  snapshot=capture()
  assert.equal(snapshot.events[0].followed_by_use,false)
  console.log('PASS: historical bytes, read attribution, use windows, and retained scope')
} finally {
  fs.rmSync(home,{recursive:true,force:true})
}
NODE
