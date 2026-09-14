#!/usr/bin/env node
// Immutable attribution identities, created only by the task launch path.
// init <id> <spawned-at>: establish forward-only coverage for a NEW task.
// register <id> <harness> <worktree>: create one launch receipt and print its UUID.
// Registration runs in the launch shell, after environment exports and activation.
// Receipts contain identity and source locations, never counters or sealed totals.
// index <id>: read exact stamps from the recorded stores; print joined session keys.
// Private schema fm-task-sessions.v1: identity.json binds id/spawned_at; each
// launches.jsonl appends stamp/harness/store/worktree receipts. No receipt is replaced.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import {randomUUID} from 'node:crypto'
import {fileURLToPath} from 'node:url'

const root = process.env.FM_ROOT_OVERRIDE || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
export const home = process.env.FM_HOME || root
export const data = process.env.FM_DATA_OVERRIDE || path.join(home, 'data')
export const state = process.env.FM_STATE_OVERRIDE || path.join(home, 'state')
const validId = id => typeof id === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(id)
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value)
export function taskDir(id) {
  if (!validId(id)) throw new Error('invalid task id')
  return path.join(data, id)
}
export function read(file) {
  try { return fs.readFileSync(file, 'utf8') } catch (e) { throw new Error(`cannot read ${file}: ${e.code}`) }
}
export function json(file) {
  try { return JSON.parse(read(file)) } catch (e) { throw new Error(`invalid or unreadable ${file}: ${e.message}`) }
}
export function entries(dir) {
  try { return fs.readdirSync(dir, {withFileTypes:true}) } catch(e) { throw new Error(`cannot read store ${dir}: ${e.code}`) }
}
function writeOnce(file, value) {
  fs.writeFileSync(file, JSON.stringify(value)+'\n', {flag:'wx', mode:0o600})
}
export function identity(id) {
  const file=path.join(taskDir(id),'sessions','identity.json')
  const value=json(file)
  if(value?.schema!=='fm-task-sessions.v1'||value.id!==id||!value.spawned_at) throw new Error(`invalid task identity ${file}`)
  return value
}
export function init(id, spawnedAt) {
  if(!Number.isFinite(Date.parse(spawnedAt))) throw new Error('missing measured task creation time')
  const dir=path.join(taskDir(id),'sessions')
  let existing=false
  try { fs.lstatSync(path.join(dir,'identity.json'));existing=true }
  catch(e) { if(e.code!=='ENOENT') throw e }
  if(existing) {
    identity(id)
    read(path.join(dir,'launches.jsonl'))
    return
  }
  fs.mkdirSync(dir,{recursive:true})
  fs.writeFileSync(path.join(dir,'launches.jsonl'),'',{flag:'wx',mode:0o600})
  writeOnce(path.join(dir,'identity.json'),{schema:'fm-task-sessions.v1',id,spawned_at:spawnedAt})
}
export function register(id,harness,worktree) {
  identity(id)
  const stamp=randomUUID()
  const store=harness==='codex'?path.resolve(process.env.CODEX_HOME||path.join(os.homedir(),'.codex')):
    harness==='claude'?path.resolve(process.env.CLAUDE_CONFIG_DIR||path.join(os.homedir(),'.claude')):null
  const value={stamp,harness,store,worktree:fs.realpathSync(worktree)}
  const file=path.join(taskDir(id),'sessions','launches.jsonl')
  // No O_CREAT: a missing earlier launch ledger must never become a new one.
  let fd
  try {
    fd=fs.openSync(file,fs.constants.O_WRONLY|fs.constants.O_APPEND)
    const bytes=Buffer.from(JSON.stringify(value)+'\n')
    if(fs.writeSync(fd,bytes)!==bytes.length) throw new Error('incomplete receipt append')
    fs.fsyncSync(fd)
  } catch(e) { throw new Error(`cannot append launch receipt ${file}: ${e.message}`) }
  finally { if(fd!==undefined) fs.closeSync(fd) }
  return stamp
}
function contained(cwd,worktree) {
  if(typeof cwd!=='string'||!path.isAbsolute(cwd)) return false
  const relative=path.relative(worktree,path.resolve(cwd))
  return relative===''||(!relative.startsWith('..'+path.sep)&&relative!=='..'&&!path.isAbsolute(relative))
}
function walk(dir) {
  const files=[]
  for(const entry of entries(dir)) {
    const file=path.join(dir,entry.name)
    if(entry.isSymbolicLink()) throw new Error(`refusing symlink in session store ${file}`)
    if(entry.isDirectory()) files.push(...walk(file))
    else if(entry.isFile()&&entry.name.endsWith('.jsonl')) files.push(file)
  }
  return files
}
function header(file, harness) {
  let fd
  try {
    fd=fs.openSync(file,'r')
    const chunk=Buffer.alloc(65536)
    let pending=''
    for (;;) {
      const size=fs.readSync(fd,chunk,0,chunk.length,null)
      pending+=chunk.toString('utf8',0,size)
      const lines=pending.split('\n')
      pending=lines.pop()
      if(size===0&&pending) { lines.push(pending);pending='' }
      for(const line of lines) {
        if(!line) continue
        const row=JSON.parse(line)
        if(harness==='codex'&&row.type==='session_meta') return row.payload
        if(harness==='claude'&&row.sessionId&&row.cwd) return row
      }
      if(size===0) throw new Error('missing session identity')
    }
  } catch(e) { throw new Error(`cannot read session identity ${file}: ${e.message}`) }
  finally { if(fd!==undefined) fs.closeSync(fd) }
}
export function index(id) {
  identity(id)
  const ledger=path.join(taskDir(id),'sessions','launches.jsonl')
  const launches=read(ledger).split('\n').filter(Boolean).map((line,i)=>{
    const file=`${ledger}:${i+1}`
    let value
    try { value=JSON.parse(line) } catch { throw new Error(`invalid launch receipt ${file}`) }
    if(!value||!uuid(value.stamp)||!path.isAbsolute(value.worktree||'')) throw new Error(`invalid launch receipt ${file}`)
    if(!['claude','codex'].includes(value.harness)||!path.isAbsolute(value.store||'')) throw new Error(`unsupported session store in ${file}: ${value.harness}`)
    return {...value,receipt:file}
  })
  if(!launches.length) throw new Error(`no measured launches in ${ledger}`)
  if(new Set(launches.map(row=>row.stamp)).size!==launches.length) throw new Error(`duplicate stamps in ${ledger}`)
  const snapshot=path.join(taskDir(id),'usage.json')
  const prior=fs.existsSync(snapshot)?json(snapshot):null
  if(prior?.correlation?.attribution==='session-stamp') {
    for(const session of prior.correlation.session_records||[]) header(session.file,session.provider)
  }
  const sessions=new Map(), scans=new Map()
  const add=(launch,id,file)=>{
    if(typeof id!=='string'||!id) throw new Error(`missing session id in ${file}`)
    const key=launch.harness+'\0'+id
    if(sessions.has(key)&&sessions.get(key).file!==file) throw new Error(`ambiguous session ${id}: ${sessions.get(key).file}, ${file}`)
    sessions.set(key,{provider:launch.harness,id,file,stamp:launch.stamp})
  }
  for(const launch of launches) {
    const store=path.join(launch.store,launch.harness==='claude'?'projects':'sessions')
    if(!scans.has(store)) scans.set(store,walk(store).map(file=>({file,
      meta:launch.harness==='codex'?header(file,'codex'):null})))
    let matched=false
    const inventory=scans.get(store)
    const counts=new Map()
    for(const source of inventory) {
      const id=launch.harness==='codex'?source.meta.id:path.basename(source.file,'.jsonl')
      counts.set(id,(counts.get(id)||0)+1)
    }
    for(const {file,meta} of inventory) {
      if(launch.harness==='codex') {
        if(meta?.originator!==launch.stamp||!contained(meta.cwd,launch.worktree)) continue
        if(counts.get(meta.id)!==1) throw new Error(`ambiguous session ${meta.id} in ${store}`)
        add(launch,meta.id,file);matched=true
      } else {
        const basename=path.basename(file,'.jsonl')
        const parent=path.dirname(file)
        const main=basename===launch.stamp
        const child=path.basename(parent)==='subagents'&&path.basename(path.dirname(parent))===launch.stamp
        if(!main&&!child) continue
        const row=header(file,'claude')
        if(row.sessionId!==launch.stamp||!contained(row.cwd,launch.worktree)) continue
        if(counts.get(basename)!==1) throw new Error(`ambiguous session ${basename} in ${store}`)
        add(launch,basename,file)
        if(main) matched=true
      }
    }
    if(!matched) throw new Error(`stamped session ${launch.stamp} unavailable in ${store} (receipt ${launch.receipt})`)
  }
  // A previously measured file cannot vanish behind an otherwise readable root.
  if(prior) {
    if(prior.correlation?.attribution==='session-stamp') {
      for(const session of prior.correlation.session_records||[]) {
        const current=sessions.get(session.provider+'\0'+session.id)
        if(!current||current.file!==session.file||current.stamp!==session.stamp) throw new Error(`measured session no longer matches ${session.file}`)
      }
    }
  }
  return [...sessions.values()]
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const [mode,id,...args]=process.argv.slice(2)
    if(mode==='init') init(id,...args)
    else if(mode==='register') console.log(register(id,...args))
    else if(mode==='index') console.log(JSON.stringify(index(id)))
    else throw new Error('usage: fm-task-session.mjs init|register|index <id> [arguments]')
  } catch(e) { console.error(`fm-task-session: ${e.message}`);process.exitCode=1 }
}
