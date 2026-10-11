// Deterministic skill evidence for the effort store. Only deferred ingestion or
// an explicit --rescan reads transcripts; rebuild consumes durable snapshots.
// See docs/effort-store.md for record shapes, attribution and heuristic limits.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import crypto from 'node:crypto'
import {spawnSync} from 'node:child_process'
import {index as sessionIndex} from './fm-task-session.mjs'
import {classifyTool, commandTextOf} from './fm-model-bench-analyze.mjs'

const SNAPSHOT_SCHEMA = 'fm-task-skill-usage.v1'
const SAFE_NAME = /^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$/
const EXEMPT = new Set(['credential-handling', 'ask-user-authority', 'project-management',
  'decision-hold-lifecycle', 'harness-adapters', 'firstmate-coding-guidelines',
  'firstmate-home-layout', 'task-lifecycle', 'secondmate-provisioning', 'process-event-sources'])
const read = file => { try { return fs.readFileSync(file, 'utf8') } catch { return null } }
const json = file => { try { return JSON.parse(read(file)) } catch { return null } }
const inside = (root, file) => { const rel = path.relative(root, file); return rel === '' || (!rel.startsWith('../') && rel !== '..' && !path.isAbsolute(rel)) }
function files(root, suffix, result = []) {
  let entries
  try { entries = fs.readdirSync(root, {withFileTypes: true}) } catch { return result }
  for (const entry of entries) {
    if (entry.isSymbolicLink() || entry.name === '.git' || entry.name === 'node_modules') continue
    const file = path.join(root, entry.name)
    if (entry.isDirectory()) files(file, suffix, result)
    else if (entry.isFile() && file.endsWith(suffix)) result.push(file)
  }
  return result.sort()
}
function save(file, object) {
  fs.mkdirSync(path.dirname(file), {recursive: true})
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(object)+'\n', {mode: 0o600})
  fs.renameSync(tmp, file)
}
function skillInfo(file, options, projectRoots) {
  const text = read(file)
  if (text === null) return null
  const repo = options.rootDir
  const tracked = [...new Set([repo,options.homeDir])].some(root=>inside(root,file) && spawnSync('git',['-C',root,'ls-files','--error-unmatch','--',path.relative(root,file)],{stdio:'ignore'}).status === 0)
  const project = projectRoots.some(root => root !== options.homeDir && root !== options.rootDir && inside(root, file))
  const scope = tracked ? 'shared' : project ? 'project' : 'local'
  const front = text.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)?.[1] || ''
  const name = front.match(/^name:\s*["']?([^\s"']+)/m)?.[1] || path.basename(path.dirname(file))
  const description = front.match(/^description:\s*([^\n]*(?:\n[ \t]+[^\n]*)*)/m)?.[1]?.replace(/^[>|][-+]?\s*/, '').trim() || ''
  return {skill: name, scope, file, text, description, skill_sha: crypto.createHash('sha256').update(text).digest('hex').slice(0, 12)}
}
export function skillInventory(options, projectRoots = []) {
  const home = options.homeDir
  const roots = [path.join(options.rootDir,'.agents','skills'), path.join(options.rootDir,'skills'),
    path.join(home,'.agents','skills'), path.join(os.homedir(),'.agents','skills'),
    path.join(process.env.CODEX_HOME || path.join(os.homedir(),'.codex'),'skills'),
    path.join(process.env.CODEX_HOME || path.join(os.homedir(),'.codex'),'plugins','cache'),
    ...projectRoots.flatMap(root=>[path.join(root,'.agents','skills'),path.join(root,'.claude','skills')])]
  return [...new Set(roots.flatMap(root=>files(root,'/SKILL.md')))].map(file=>skillInfo(file,options,projectRoots)).filter(Boolean)
}
function header(file, provider) {
  let fd
  try {
    fd = fs.openSync(file,'r'); const buf = Buffer.alloc(65536)
    const text = buf.subarray(0,fs.readSync(fd,buf,0,buf.length,0)).toString('utf8')
    for (const line of text.split('\n')) {
      let row
      try { row = JSON.parse(line) } catch { continue }
      if (provider === 'codex' && row.type === 'session_meta') return row.payload
      if (provider === 'claude' && row.cwd && row.sessionId) return {id: row.sessionId, cwd: row.cwd, timestamp: row.timestamp, sidechain: row.isSidechain}
    }
  } catch { return null } finally { if(fd !== undefined) fs.closeSync(fd) }
  return null
}
function argumentsOf(input) { if(typeof input !== 'string') return input || {}; try { return JSON.parse(input) } catch { return {} } }
function parseLog(record) {
  const text = read(record.file)
  if (text === null) return null
  let offset = 0, turn = 0, lastRequest = null
  const events = [], calls = [], outputs = new Map()
  for (const line of text.split('\n')) {
    const byte = offset; offset += Buffer.byteLength(line)+1
    let row
    try { row = JSON.parse(line) } catch { continue }
    const p = row.payload || {}, at = row.timestamp || null
    if (record.provider === 'claude') {
      if (row.isSidechain) continue
      if (row.type === 'assistant') {
        const request = row.requestId || row.message?.id
        if (!request || request !== lastRequest) { turn++; lastRequest = request }
        for (const [i,b] of (Array.isArray(row.message?.content) ? row.message.content : []).entries()) {
          if (b.type !== 'tool_use') continue
          calls.push({name: b.name, input: b.input, turn, at, offset: `${byte}:${i}`, id: b.id})
          if (b.name === 'Skill' && SAFE_NAME.test(b.input?.skill || '')) events.push({skill:b.input.skill,source:'explicit',turn,at_utc:at,log_offset:`${byte}:${i}`,call_id:b.id})
        }
      }
      if (row.type === 'user' && Array.isArray(row.message?.content)) for (const b of row.message.content) {
        if (b.type === 'tool_result') outputs.set(b.tool_use_id, {text:typeof b.content === 'string' ? b.content : JSON.stringify(b.content), failed:b.is_error === true})
      }
    } else {
      if (row.type === 'turn_context') turn++
      if (row.type !== 'response_item') continue
      if (p.type === 'message' && p.role === 'user' && Array.isArray(p.content)) {
        let i = 0
        for (const b of p.content) if(b.type === 'input_text') {
          for (const m of (b.text || '').matchAll(/(?:^|\s)\$([a-zA-Z0-9][a-zA-Z0-9_.:-]*)\b/g)) events.push({skill:m[1],source:'explicit',turn:Math.max(1,turn),at_utc:at,log_offset:`${byte}:user:${i++}`})
        }
      }
      if (['function_call','custom_tool_call'].includes(p.type)) calls.push({name:p.name,input:p.arguments ?? p.input,turn:Math.max(1,turn),at,offset:`${byte}:0`,id:p.call_id})
      if (['function_call_output','custom_tool_call_output'].includes(p.type)) outputs.set(p.call_id,{text: typeof p.output === 'string' ? p.output : JSON.stringify(p.output), failed: /(?:exit_code["']?\s*:\s*[1-9]|Process exited with code [1-9])/.test(String(p.output))})
    }
  }
  // Only actual read interfaces/commands count; prose, echo and patch payloads
  // mentioning SKILL.md are never load evidence. Dynamic paths are unresolved.
  if (record.provider === 'codex') for (const call of calls) {
    const name = call.name.split('.').at(-1)
    let text = null
    if (name === 'read_file') text = argumentsOf(call.input).path || argumentsOf(call.input).file_path
    else if (classifyTool('codex', name, call.input) === 'read') text = commandTextOf('codex', name, call.input)
    if (!text || !outputs.has(call.id) || outputs.get(call.id).failed) continue
    const seen = new Set()
    for (const m of text.matchAll(/(?:^|[\s"'])((?:~\/|\/|\.\.?\/)?[^\s"'`;|<>]*\/skills\/[^\s"'`;|<>]+\/SKILL\.md)(?=$|[\s"';])/g)) {
      let file = m[1]
      if (file.includes('$') || file.includes('\\')) continue
      file = file.startsWith('~/') ? path.join(os.homedir(),file.slice(2)) : path.resolve(record.cwd,file)
      if (seen.has(file)) continue
      seen.add(file)
      events.push({skill:path.basename(path.dirname(file)),source:'implicit',turn:call.turn,at_utc:call.at,log_offset:`${call.offset}:read:${seen.size}`,file,call_id:call.id})
    }
  }
  return {events,calls,outputs,lastTurn:Math.max(1,turn)}
}
function foldRecord(record, options, inventory, projectRoots, cutoff) {
  const parsed = parseLog(record)
  if (!parsed) return null
  return parsed.events.filter(e=>!cutoff || (e.at_utc && Date.parse(e.at_utc) >= Date.parse(cutoff))).map(event=>{
    const candidates = inventory.filter(s=>s.skill === event.skill)
    const contextual = candidates.filter(s=>inside(record.cwd,s.file))
    const resolved = contextual.length ? contextual : candidates
    const skill = event.file ? skillInfo(event.file,options,projectRoots) : resolved.length === 1 ? resolved[0] : null
    // Hash only content proven by a logged result, never today's file substituted
    // for an old version. Description is usable under the same evidence rule.
    const output = event.call_id && parsed.outputs.get(event.call_id)?.text
    const observed = skill && output && output.includes(skill.text)
    const terms = observed ? [...new Set(skill.description.toLowerCase().match(/[a-z][a-z0-9_-]{3,}/g) || [])].filter(t=>!['this','that','with','from','before','after','when','skill','skills','execute','agent','only','load'].includes(t)) : []
    const future = parsed.calls.filter(c=>c.turn >= event.turn && c.turn <= event.turn+3 && Number(c.offset.split(':')[0]) > Number(event.log_offset.split(':')[0]))
    const match = future.some(c=>!['read','search'].includes(classifyTool(record.provider,c.name.split('.').at(-1),c.input)) && c.name !== 'Skill' && terms.some(t=>JSON.stringify(c.input).toLowerCase().includes(t)))
    return {...event, session_id:`${record.provider}:${record.id}`, evidence:`${record.file}#byte=${event.log_offset}`,scope:skill?.scope || 'local',skill_sha:observed ? skill.skill_sha : null,
      followed_by_use:terms.length ? match ? true : parsed.lastTurn >= event.turn+3 ? false : null : null,
      file:undefined,call_id:undefined}
  })
}
export function captureSkills(options, tasks, rescan = false) {
  const marker = path.join(options.dataDir,'skill-capture.json')
  let enabled = json(marker)?.enabled_at
  if (!rescan && !enabled) { enabled = new Date().toISOString(); save(marker,{enabled_at:enabled}) }
  const projects = [...new Set(tasks.flatMap(t=>{
    const ledger = (read(path.join(options.dataDir,t.taskId,'sessions','launches.jsonl')) || '').split('\n').map(line=>{try{return JSON.parse(line)}catch{return null}}).filter(Boolean)
    const meta = read(path.join(options.stateDir,`${t.taskId}.meta`)) || ''
    return [t.raw?.project,t.raw?.worktree,meta.match(/^project=(.+)$/m)?.[1],...ledger.map(l=>l.worktree)].filter(Boolean)
  }))]
  const inventory = skillInventory(options,projects)
  const bound = new Set()
  for (const task of tasks) {
    let records = []
    try { records = sessionIndex(task.taskId) } catch { /* Unavailable logs leave prior evidence intact. */ }
    for (const r of records) bound.add(r.file)
    const ledger = (read(path.join(options.dataDir,task.taskId,'sessions','launches.jsonl')) || '').split('\n').map(line=>{try{return JSON.parse(line)}catch{return null}}).filter(Boolean)
    const main = records.filter(r=>r.provider !== 'claude' || path.basename(r.file,'.jsonl') === r.stamp).map(r=>({...r,cwd:ledger.find(l=>l.stamp===r.stamp)?.worktree || options.homeDir}))
    captureTask(task.taskId, main, null, options, inventory, projects, rescan ? null : enabled)
  }
  const stores = [ ['codex',path.join(process.env.CODEX_HOME || path.join(os.homedir(),'.codex'),'sessions')],
    ['claude',path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(),'.claude'),'projects')] ]
  for (const [provider,store] of stores) for (const file of files(store,'.jsonl')) {
    if (bound.has(file)) continue
    if (!rescan) { try { if(fs.statSync(file).mtimeMs < Date.parse(enabled)) continue } catch { continue } }
    const meta = header(file,provider)
    if (!meta || meta.sidechain || !meta.id || path.resolve(meta.cwd || '/') !== path.resolve(options.homeDir)) continue
    const date = (meta.timestamp || '').slice(0,10)
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) continue
    const id = `fm-session-${date}-${provider}-${crypto.createHash('sha256').update(meta.id).digest('hex').slice(0,16)}`
    captureTask(id,[{provider,id:meta.id,file,cwd:meta.cwd}],{kind:'primary-session',started_at:meta.timestamp},options,inventory,projects,rescan ? null : enabled)
  }
}
function captureTask(id, records, identity, options, inventory, projects, cutoff) {
  const file = path.join(options.dataDir,id,'skill-usage.json')
  const launchAt = json(path.join(options.dataDir,id,'sessions','identity.json'))?.spawned_at || identity?.started_at || null
  const prior = json(file)
  const previous = prior?.spawned_at === launchAt ? prior : null
  const events = new Map((previous?.schema === SNAPSHOT_SCHEMA ? previous.events : []).map(e=>[`${e.session_id}\0${e.log_offset}`,e]))
  let available = false
  for (const record of records) {
    const rows = foldRecord(record,options,inventory,projects,cutoff)
    if (rows === null) continue
    available = true
    for (const e of rows) {
      const key = `${e.session_id}\0${e.log_offset}`, old = events.get(key)
      events.set(key,old ? {...e,skill_sha:old.skill_sha || e.skill_sha,followed_by_use:old.followed_by_use ?? e.followed_by_use} : e)
    }
  }
  if (available && (events.size || !identity)) save(file,{schema:SNAPSHOT_SCHEMA,task:id,spawned_at:launchAt,project_roots:projects,identity:identity || previous?.identity || null,
    events:[...events.values()].sort((a,b)=>a.session_id.localeCompare(b.session_id)||a.log_offset.localeCompare(b.log_offset))})
}
export function skillSnapshots(options) {
  let dirs
  try { dirs = fs.readdirSync(options.dataDir,{withFileTypes:true}) } catch { return [] }
  return dirs.filter(d=>d.isDirectory()).map(d=>json(path.join(options.dataDir,d.name,'skill-usage.json')))
    .filter(s=>{
      if (s?.schema !== SNAPSHOT_SCHEMA || !Array.isArray(s.events) || !SAFE_NAME.test(s.task)) return false
      const identity = json(path.join(options.dataDir,s.task,'sessions','identity.json'))
      return !identity || identity.spawned_at === s.spawned_at
    })
}
export function writeSkillRows(db, snapshots) {
  const available = new Set(snapshots.map(s=>s.task))
  const sourceInsert = db.prepare('INSERT INTO task_source VALUES (?,?,?,?)')
  for (const task of db.prepare('SELECT task_id FROM task').all()) sourceInsert.run(task.task_id,'skills',available.has(task.task_id) ? 'present' : 'missing',available.has(task.task_id) ? SNAPSHOT_SCHEMA+' deterministic snapshot' : 'no skill evidence was captured')
  const eventInsert = db.prepare('INSERT INTO task_skill_event (task_id,session_id,log_offset,skill,turn,at_utc,source,evidence,followed_by_use,scope,skill_sha) VALUES (?,?,?,?,?,?,?,?,?,?,?)')
  const usageInsert = db.prepare('INSERT INTO task_skill_usage VALUES (?,?,?,?,?,?,?,?)')
  for (const snapshot of snapshots) {
    if (snapshot.identity?.kind === 'primary-session') db.prepare('INSERT OR IGNORE INTO task (task_id,kind,started_at) VALUES (?,?,?)').run(snapshot.task,'primary-session',snapshot.identity.started_at)
    const groups = new Map()
    for (const event of snapshot.events) {
      eventInsert.run(snapshot.task,event.session_id,event.log_offset,event.skill,event.turn,event.at_utc,event.source,event.evidence,event.followed_by_use === null ? null : Number(event.followed_by_use),event.scope,event.skill_sha)
      const key = `${event.skill}\0${event.skill_sha || ''}`
      const group = groups.get(key) || {skill:event.skill,scope:event.scope,loads:0,explicit:0,implicit:0,first:event.turn,sha:event.skill_sha}
      group.loads++; group[event.source]++; group.first = Math.min(group.first,event.turn); groups.set(key,group)
    }
    for (const g of groups.values()) usageInsert.run(snapshot.task,g.skill,g.scope,g.loads,g.explicit,g.implicit,g.first,g.sha)
  }
}
export function skillsReport(db, options, argv) {
  let since = null, asJson = false, includePrimary = false
  for (let i=0;i<argv.length;i++) {
    if (argv[i] === '--json') asJson = true
    else if (argv[i] === '--include-primary') includePrimary = true
    else if (argv[i] === '--since' && /^\d+d$/.test(argv[i+1] || '')) since = new Date(Date.now()-Number(argv[++i].slice(0,-1))*86400000).toISOString()
    else throw new Error(`unknown skills option '${argv[i]}'`)
  }
  const projects = [...new Set([...db.prepare('SELECT DISTINCT project_path FROM task WHERE project_path IS NOT NULL').all().map(r=>r.project_path),...skillSnapshots(options).flatMap(s=>s.project_roots || [])])]
  const rows = new Map()
  for (const s of skillInventory(options,projects)) rows.set(`${s.skill}\0${s.scope}`,{skill:s.skill,scope:s.scope,loads:0,tasks:0,followed:0,not_followed:0,unknown:0,outcomes:{},exempt:EXEMPT.has(s.skill)})
  const events = db.prepare(`SELECT e.*, t.outcome FROM task_skill_event e JOIN task t USING(task_id) WHERE (? OR coalesce(t.kind,'') <> 'primary-session') AND (? IS NULL OR e.at_utc >= ?) ORDER BY e.skill,e.scope,e.task_id`).all(Number(includePrimary),since,since)
  const taskSets = new Map()
  for (const e of events) {
    const key = `${e.skill}\0${e.scope}`
    const r = rows.get(key) || {skill:e.skill,scope:e.scope,loads:0,tasks:0,followed:0,not_followed:0,unknown:0,outcomes:{},exempt:EXEMPT.has(e.skill)}
    r.loads++; r[e.followed_by_use === 1 ? 'followed' : e.followed_by_use === 0 ? 'not_followed' : 'unknown']++
    if (!taskSets.has(key)) taskSets.set(key,new Set())
    if (!taskSets.get(key).has(e.task_id)) { taskSets.get(key).add(e.task_id); r.tasks++; r.outcomes[e.outcome || 'unknown']=(r.outcomes[e.outcome || 'unknown'] || 0)+1 }
    rows.set(key,r)
  }
  const skills = [...rows.values()].sort((a,b)=>a.skill.localeCompare(b.skill)||a.scope.localeCompare(b.scope)).map(r=>({...r,never_loaded:r.loads === 0,percent_not_followed:r.followed+r.not_followed ? Math.round(r.not_followed/(r.followed+r.not_followed)*10000)/100 : null}))
  if (asJson) return JSON.stringify({since,include_primary:includePrimary,skills})+'\n'
  return ['SKILL | SCOPE | LOADS | TASKS | NOT FOLLOWED % (known loads) | UNKNOWN | OUTCOMES | FLAGS', ...skills.map(r=>`${r.skill} | ${r.scope} | ${r.loads} | ${r.tasks} | ${r.percent_not_followed ?? '-'} | ${r.unknown} | ${JSON.stringify(r.outcomes)} | ${[r.exempt?'exempt':'',r.never_loaded?'never-loaded':''].filter(Boolean).join(',')}`)].join('\n')+'\n'
}
