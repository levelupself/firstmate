#!/usr/bin/env node
// Session-stamped task totals. The shell entry point delegates here.
// fm-task-usage.v3 retains task totals; mixed-session model totals may be null; correlation.attribution
// is session-stamp and session_records names each measured local source and stamp.
// Usage: fm-task-usage.sh <id> [--json|--snapshot]
// Every read joins codeburn session rows by provider/sessionId against exact
// local stamps. No date, encoded project path, or ancestry decides ownership.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import {spawnSync} from 'node:child_process'
import {data,state,taskDir,read,json,identity,index} from './fm-task-session.mjs'

const [id,mode='']=process.argv.slice(2)
function compact(u) {
  const seconds=u.duration_seconds||0
  return `${u.harness} / ${(u.actual_models||[]).join(', ')||'-'} | in ${u.tokens.input}, out ${u.tokens.output}, cache ${u.tokens.cache_read}, write ${u.tokens.cache_write} | $${u.cost_usd.toFixed(4)} | ${u.calls} calls | ${u.sessions} sessions | elapsed ${Math.floor(seconds/3600)}h ${Math.floor(seconds%3600/60)}m ${seconds%60}s`
}
const number=(row,key,file)=>{
  const n=row[key]
  if(typeof n!=='number'||!Number.isFinite(n)||n<0) throw new Error(`invalid ${key} in codeburn store ${file}`)
  return n
}
let tmp
try {
  if(!['','--json','--snapshot'].includes(mode)) throw new Error('usage: fm-task-usage.sh <id> [--json|--snapshot]; pre-launch baselines are no longer inferred')
  const snapshot=path.join(taskDir(id),'usage.json'), metaPath=path.join(state,id+'.meta')
  if(!fs.existsSync(metaPath)&&fs.existsSync(snapshot)) {
    const u=json(snapshot);console.log(mode==='--json'?JSON.stringify(u):compact(u))
  } else {
    const meta=Object.fromEntries(read(metaPath).split('\n').filter(line=>line.includes('=')).map(line=>[line.slice(0,line.indexOf('=')),line.slice(line.indexOf('=')+1)]))
    if(meta.kind==='secondmate') throw new Error('secondmates are persistent supervisors, not task cycles')
    const task=identity(id)
    if(task.spawned_at!==meta.spawned_at) throw new Error(`task creation identity mismatch in ${metaPath}`)
    const owned=index(id), keys=new Map(owned.map(s=>[s.provider+'\0'+s.id,s]))
    tmp=fs.mkdtempSync(path.join(os.tmpdir(),'fm-task-usage-'))
    const reportPath=path.join(tmp,'sessions.json')
    const timeout=Number(process.env.FM_TASK_USAGE_TIMEOUT||60)
    const result=spawnSync(process.env.FM_CODEBURN_BIN||'codeburn',[
      '--timezone','UTC','sessions','--period','all','--format','json',
    ],{encoding:'utf8',timeout:Number.isFinite(timeout)&&timeout>0?timeout*1000:60000,maxBuffer:64*1024*1024})
    if(result.error||result.status!==0) throw new Error(`codeburn sessions unavailable at ${reportPath}: ${result.error?.message||result.stderr||result.status}`)
    fs.writeFileSync(reportPath,result.stdout,{mode:0o600})
    const report=json(reportPath)
    if(!Array.isArray(report)) throw new Error(`unsupported codeburn session report in ${reportPath}`)
    const modelsByKey=new Map(), seen=new Set()
    const totals={calls:0,input_tokens:0,output_tokens:0,cache_read_tokens:0,cache_write_tokens:0,cost_usd:0}
    const fields={calls:'calls',input_tokens:'inputTokens',output_tokens:'outputTokens',cache_read_tokens:'cacheReadTokens',cache_write_tokens:'cacheWriteTokens',cost_usd:'cost'}
    for(const row of report) {
      const key=row.provider+'\0'+row.sessionId
      if(!keys.has(key)) continue
      if(seen.has(key)) throw new Error(`ambiguous codeburn session ${row.sessionId} in ${reportPath}`)
      if(!Array.isArray(row.models)||!row.models.length||row.models.some(name=>typeof name!=='string'||!name.trim())||new Set(row.models).size!==row.models.length) throw new Error(`invalid model names in ${reportPath} for ${row.sessionId}`)
      seen.add(key)
      const values=Object.fromEntries(Object.entries(fields).map(([out,input])=>[out,number(row,input,reportPath)]))
      for(const field of Object.keys(fields)) totals[field]+=values[field]
      for(const name of row.models) {
        const modelKey=row.provider+'\0'+name
        const model=modelsByKey.get(modelKey)||{name,provider:row.provider,...Object.fromEntries(Object.keys(fields).map(field=>[field,0]))}
        for(const field of Object.keys(fields)) {
          model[field]=row.models.length>1||model[field]===null?null:model[field]+values[field]
        }
        modelsByKey.set(modelKey,model)
      }
    }
    for(const [key,session] of keys) if(!seen.has(key)) throw new Error(`codeburn rows unavailable for session ${session.id} from ${session.file}`)
    const models=[...modelsByKey.values()].sort((a,b)=>(a.provider+'\0'+a.name).localeCompare(b.provider+'\0'+b.name))
    const sum=key=>totals[key]
    const captured=new Date(), started=Date.parse(meta.spawned_at)
    let title=meta.title||id
    const brief=path.join(data,id,'brief.md')
    if(!meta.title&&fs.existsSync(brief)) title=read(brief).match(/^# Task\s*\n+([^\n]+)/m)?.[1]||id
    const u={schema:'fm-task-usage.v3',id,title,kind:meta.kind||'ship',project:meta.project||null,delivery_mode:meta.mode||null,
      harness:meta.harness||'unknown',configured_model:meta.model||'default',actual_models:models.map(m=>m.name),models,
      tokens:{input:sum('input_tokens'),output:sum('output_tokens'),cache_read:sum('cache_read_tokens'),cache_write:sum('cache_write_tokens')},
      cost_usd:sum('cost_usd'),calls:sum('calls'),sessions:seen.size,spawned_at:meta.spawned_at,captured_at:captured.toISOString(),
      duration_seconds:Number.isFinite(started)?Math.max(0,Math.floor((captured.getTime()-started)/1000)):null,
      correlation:{attribution:'session-stamp',worktree:meta.worktree,session_records:owned}}
    if(fs.existsSync(snapshot)) {
      const previous=json(snapshot)
      if(previous.correlation?.attribution==='session-stamp') {
        for(const key of ['cost_usd','calls','sessions']) if(u[key]<previous[key]) throw new Error(`measured ${key} decreased since ${snapshot}`)
        for(const key of Object.keys(u.tokens)) if(u.tokens[key]<previous.tokens[key]) throw new Error(`measured ${key} decreased since ${snapshot}`)
      }
    }
    if(mode==='--snapshot') {
      fs.mkdirSync(taskDir(id),{recursive:true})
      const staged=snapshot+'.'+process.pid
      const fd=fs.openSync(staged,'w',0o600)
      try { fs.writeFileSync(fd,JSON.stringify(u)+'\n');fs.fsyncSync(fd) }
      finally { fs.closeSync(fd) }
      fs.renameSync(staged,snapshot)
    }
    console.log(mode==='--json'?JSON.stringify(u):compact(u))
  }
} catch(e) { console.error(`fm-task-usage: ${e.message}`);process.exitCode=1 }
finally {if(tmp) fs.rmSync(tmp,{recursive:true,force:true})}
