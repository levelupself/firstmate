// Artifact selection engine for fm-pool-build-sweep.sh; its header owns the CLI.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync, spawn} from 'node:child_process';
import {files, directories} from './fm-build-output-files.mjs';
const dir = path.dirname(fileURLToPath(import.meta.url));
const home = process.env.FM_HOME;
// Match fm-spawn.sh and fm-teardown.sh's code-root resolution.
const root = path.resolve(process.env.FM_ROOT_OVERRIDE || path.join(dir, '..'));
const state = process.env.FM_STATE_OVERRIDE || path.join(home, 'state');
const args = process.argv.slice(2);
let dry = false, age = Number(process.env.FM_POOL_BUILD_AGE_HOURS || 24);
let maxGB = Number(process.env.FM_POOL_BUILD_MAX_GB || 8);
let scheduled = false, periodic = false;
let lockedCopy, lockedTargets, explain;
for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--dry-run': dry = true; break;
    case '--explain': explain = path.resolve(args[++i]); dry = true; break;
    case '--age-hours': age = Number(args[++i]); break;
    case '--max-gb': maxGB = Number(args[++i]); break;
    case '--periodic': periodic = true; break;
    case '--scheduled': scheduled = true; break;
    case '--locked-copy': lockedCopy = [args[++i], args[++i]]; break;
    case '--locked-targets': lockedTargets = JSON.parse(args[++i]); break;
    default: throw Error(`unknown argument: ${args[i]}`);
  }
}
if (!Number.isFinite(age) || age <= 0 || !Number.isFinite(maxGB) || maxGB <= 0)
  throw Error('age-hours and max-gb must be positive');
const cap = maxGB * 1e9;
const exists = p => fs.existsSync(p);
const run = (cmd, argv, opts = {}) => execFileSync(cmd, argv, {encoding:'utf8', timeout:30000, maxBuffer:32*1024*1024, stdio:['ignore','pipe','pipe'], ...opts}).trim();
const marker = path.join(state, '.pool-build-sweep.last');
const recent = () => exists(marker) && Date.now() - fs.statSync(marker).mtimeMs < 3600000;
if (periodic) {
  if (dry) throw Error('--periodic cannot be combined with --dry-run');
  fs.mkdirSync(state, {recursive:true});
  if (!recent()) {
    const log = path.join(state, '.pool-build-sweep.log');
    if (exists(log) && fs.statSync(log).size > 1024*1024) fs.truncateSync(log, 0);
    const fd = fs.openSync(log, 'a');
    const child = spawn(path.join(dir, 'fm-pool-build-sweep.sh'), ['--scheduled'], {
      detached:true, stdio:['ignore', fd, fd], env:process.env,
    });
    child.on('error', e => fs.appendFileSync(log, `launch failed: ${e.message}\n`));
    child.unref(); fs.closeSync(fd);
  }
  process.exit(0);
}
if (scheduled) {
  if (recent()) process.exit(0);
  fs.writeFileSync(marker, `${new Date().toISOString()}\n`);
}
// PATH wins, followed by the user-local and standard system install locations.
function treehouse(project) {
  const systemLocations = process.env.FM_TREEHOUSE_SYSTEM_PATH === undefined
    ? ['/usr/local/bin', '/opt/homebrew/bin']
    : process.env.FM_TREEHOUSE_SYSTEM_PATH.split(path.delimiter).filter(Boolean);
  const locations = [...(process.env.PATH || '').split(path.delimiter),
    ...(process.env.HOME ? [path.join(process.env.HOME, '.local/bin')] : []),
    ...systemLocations];
  for (const location of locations) {
    const candidate = path.resolve(project, location, 'treehouse');
    try {
      if (!fs.statSync(candidate).isFile()) continue;
      fs.accessSync(candidate, fs.constants.X_OK);
      return fs.realpathSync(candidate);
    } catch {}
  }
  throw Object.assign(Error('treehouse-not-found'), {code:'FM_TREEHOUSE_NOT_FOUND'});
}
function inventory(project) {
  let output;
  try {
    output = run(treehouse(project), ['status','--json'], {cwd:project});
  } catch (e) {
    try { output = run('bash', ['-lc','treehouse status --json'], {cwd:project}); }
    catch { throw Object.assign(Error('treehouse-not-found'), {code:'FM_TREEHOUSE_NOT_FOUND'}); }
  }
  const entries = JSON.parse(output);
  if (!Array.isArray(entries)) throw Error('invalid Treehouse inventory');
  const seen = new Set();
  for (const e of entries) {
    if (!e || typeof e.path !== 'string' || !path.isAbsolute(e.path) || /[\r\n\t]/.test(e.path)
        || seen.has(e.path) || !Array.isArray(e.processes)) throw Error('invalid Treehouse entry');
    seen.add(e.path);
  }
  return entries;
}
function processReason(entry) {
  for (const p of entry.processes) {
    if (!p || typeof p.name !== 'string') return 'unknown-process';
    if (/^(cargo(?:-.*)?|rustc)(?:\s|$)/.test(path.basename(p.name))) return 'live-cargo';
  }
  return '';
}
const bytes = entries => entries.reduce((sum, f) => sum + f.size, 0);
const report = (wt, before, after, reason) => console.log(`${wt}\tbytes_before=${before}\tbytes_after=${after}\t${reason}`);
function boundary(wt) {
  return JSON.parse(run('bash', ['-c', '. "$1"; fm_build_output_target "$2"', '_', path.join(dir, 'fm-build-output-lib.sh'), wt]));
}
function sameRepo(project, wt) {
  const common = p => fs.realpathSync(run('git', ['-C', p, 'rev-parse','--path-format=absolute','--git-common-dir']));
  return fs.realpathSync(wt) === wt && fs.realpathSync(project) !== wt && common(project) === common(wt);
}
// Cargo's JSON contains u64 values. Preserve their decimal bytes before parsing;
// dependency hashes must never round through a JavaScript number.
const cargoJSON = text => JSON.parse(text.replace(/([:\[,]\s*)(\d{16,})(?=\s*[,}\]])/g, '$1"$2"'));
function select(target, all) {
  const nodes = [];
  const eligible = new Set(all.map(f => f.p));
  for (const f of all) {
    const rel = path.relative(target, f.p).split(path.sep);
    const fp = rel.indexOf('.fingerprint');
    if (fp < 1 || rel.length !== fp+3 || !rel.at(-1).endsWith('.json')) continue;
    const match = /^(.*)-([a-f0-9]{16})$/.exec(rel[fp+1]);
    if (!match) continue;
    const json = cargoJSON(fs.readFileSync(f.p, 'utf8'));
    if (!Array.isArray(json.deps)) throw Error('unknown-fingerprint');
    const unit = rel.at(-1).slice(0,-5);
    const stamp = f.p.slice(0,-5);
    if (!eligible.has(stamp)) throw Error('incomplete-fingerprint');
    const digest = fs.readFileSync(stamp,'utf8').trim();
    if (!/^[a-f0-9]{16}$/.test(digest)) throw Error('unknown-fingerprint-hash');
    const profile = rel.slice(0,fp).join(path.sep);
    // Feature sets and Cargo profiles are rebuildable generations of one unit.
    const key = JSON.stringify([profile, match[1], unit, json.compile_kind]);
    nodes.push({hash:match[2], crate:match[1].replaceAll('-','_'), profile, key, time:f.time, json,
      digest:BigInt(`0x${Buffer.from(digest,'hex').reverse().toString('hex')}`).toString()});
  }
  const newest = new Map();
  for (const n of nodes) {
    const previous = newest.get(n.key);
    if (!previous || n.time > previous.time || (n.time === previous.time && n.hash > previous.hash)) newest.set(n.key,n);
  }
  const keep = new Set(newest.values());
  const queue = [...keep];
  while (queue.length) {
    const n = queue.pop();
    for (const dep of n.json.deps) {
      if (!Array.isArray(dep) || dep.length < 3) throw Error('unknown-dependency');
      const digest = dep.length === 4 && typeof dep[2] === 'boolean' ? dep[3] : dep[2];
      const matches = nodes.filter(d => d.digest === String(digest));
      // Missing dependency proof cannot authorize deletion of any generation.
      if (!matches.length) throw Error('unresolved-dependency');
      for (const d of matches) if (!keep.has(d)) { keep.add(d); queue.push(d); }
    }
  }
  const protectedHashes = new Set([...keep].map(n => `${n.profile}/${n.hash}`));
  const obsolete = new Set(nodes.filter(n => !protectedHashes.has(`${n.profile}/${n.hash}`)).map(n => `${n.profile}/${n.hash}`));
  const candidates = all.filter(f => {
    const rel = path.relative(target,f.p).split(path.sep);
    const area = rel.findIndex(p => ['deps','build','.fingerprint'].includes(p));
    if (area < 1) return false;
    const hash = /-([a-f0-9]{16})(?:\.|$)/.exec(rel[area+1]);
    return hash && obsolete.has(`${rel.slice(0,area).join(path.sep)}/${hash[1]}`);
  }).sort((a,b) => a.time-b.time || a.p.localeCompare(b.p));
  if (explain) for (const key of newest.keys()) {
    const generations = nodes.filter(n => n.key === key);
    const hashes = new Set(generations.map(n => n.hash));
    const evictable = candidates.filter(f => {
      const rel = path.relative(target,f.p).split(path.sep);
      const area = rel.findIndex(p => ['deps','build','.fingerprint'].includes(p));
      const hash = /-([a-f0-9]{16})(?:\.|$)/.exec(rel[area+1]);
      return rel.slice(0,area).join(path.sep) === generations[0].profile && hash && hashes.has(hash[1]);
    });
    console.log(`generation_key=${key} protected=${generations.filter(n=>keep.has(n)).map(n=>n.hash).join(',')} evictable_bytes=${bytes(evictable)}`);
  }
  const profiles = [...new Set(nodes.map(n=>n.profile.split(path.sep)[0]))]
    .filter(p=>!['debug','release'].includes(p))
    .map(p=>({p:path.join(target,p), files:all.filter(f=>f.p.startsWith(path.join(target,p)+path.sep))}))
    .map(p=>({...p,time:p.files.reduce((time,f)=>Math.max(time,f.time),0)}))
    .sort((a,b)=>a.time-b.time || a.p.localeCompare(b.p));
  return {candidates, profiles};
}
function sweep(project, wt, target) {
  let before = 0;
  try {
    if (!sameRepo(project,wt)) {report(wt,0,0,'skipped=not-pool-copy');return;}
    if (!boundary(wt).includes(target)) { report(wt,0,0,'skipped=no-eligible-rust-output');return; }
    const all = files(target); before = bytes(all);
    const entry = inventory(project).find(e => e.path === wt);
    if (!entry) throw Error('missing-pool-entry');
    const reason = processReason(entry);
    if (reason) {report(wt,before,before,`skipped=${reason}`);return;}
    let {candidates, profiles} = select(target, all);
    const candidateBytes = bytes(candidates);
    const protectedSize = before-candidateBytes;
    // cargo-sweep is a planner only: it has no current-generation preservation
    // mode. Never grant it write access to the live target. Its proposed paths
    // may include current artifacts, so our fingerprint proof remains mandatory.
    let planner = 'mtime';
    if (before > cap) {
      let scratch;
      try {
        run('bash',['-c','command -v cargo-sweep']);
        scratch = fs.mkdtempSync(path.join(target,'.fm-sweep-plan-'));
        fs.writeFileSync(path.join(scratch,'Cargo.toml'), '[package]\nname="fm-sweep-plan"\nversion="0.0.0"\nedition="2021"\n[lib]\npath="lib.rs"\n[workspace]\n');
        fs.writeFileSync(path.join(scratch,'lib.rs'),'');
        const plan = size => {
          const output = run('cargo-sweep', ['sweep','--maxsize',size,'--dry-run','--verbose'], {
            cwd:scratch, env:{...process.env,CARGO_TARGET_DIR:target,CARGO_NET_OFFLINE:'true'},
          });
          const paths = [...output.matchAll(/Would remove: ("(?:[^"\\]|\\.)*")/g)].map(m=>JSON.parse(m[1]));
          return candidates.filter(f=>paths.some(p=>f.p===p || f.p.startsWith(p+path.sep)));
        };
        let proposed = plan(String(maxGB)+'GB');
        // Filtering out current artifacts can make the tool's proposed saving
        // insufficient. Request all obsolete candidates, still in dry-run mode,
        // then stop our oldest-first eviction as soon as the real cap is met.
        if (before-bytes(proposed)>cap) proposed = plan('0B');
        if (!proposed.length && candidates.length) throw Error('unrecognized cargo-sweep plan');
        const selected = new Set(proposed.map(f=>f.p));
        candidates = candidates.filter(f=>selected.has(f.p) || f.time<Date.now()-age*3600000);
        planner = 'cargo-sweep';
      } catch (e) {
        if (scratch) console.error(`${wt}: cargo-sweep plan failed; using verified mtime candidates`);
      } finally {
        if (scratch) fs.rmSync(scratch,{recursive:true,force:true});
      }
    }
    // Recheck both the Git boundary and process inventory after planning.
    if (!boundary(wt).includes(target)) throw Error('output-boundary-changed');
    const fresh = inventory(project).find(e => e.path === wt);
    if (!fresh) throw Error('missing-pool-entry');
    const busy = processReason(fresh);
    if (busy) {report(wt,before,before,`skipped=${busy}`);return;}
    let remaining = before, removed = 0;
    const cutoff = Date.now()-age*3600000;
    const removedPaths = new Set();
    const remove = f => {
      if (path.basename(f.p) === '.cargo-lock') return;
      const now = fs.lstatSync(f.p);
      if (!now.isFile() || now.ino !== f.ino || now.dev !== f.dev || now.mtimeMs !== f.time || now.size !== f.size)
        throw Error('artifact-changed');
      if (!dry) {
        fs.unlinkSync(f.p);
        let parent = path.dirname(f.p);
        while (parent !== target && !['deps','build','.fingerprint'].includes(path.basename(parent))) {
          try { fs.rmdirSync(parent); } catch { break; }
          parent = path.dirname(parent);
        }
      }
      removedPaths.add(f.p);
      remaining -= f.size; removed += f.size;
    };
    const metadata = new Map();
    for (const f of candidates) {
      if (f.p.includes(`${path.sep}.fingerprint${path.sep}`)) {
        const parent = path.dirname(f.p);
        metadata.set(parent,[...(metadata.get(parent)||[]),f]);
        continue;
      }
      if (f.time < cutoff || remaining > cap) remove(f);
    }
    // Keep the complete fingerprint until its data is gone. Otherwise a size
    // stop halfway through a generation would strand unidentifiable artifacts.
    for (const [parent, group] of metadata) {
      const hash = path.basename(parent).slice(-16);
      const profile = path.dirname(path.dirname(parent));
      const surviving = all.some(f=>f.p.startsWith(profile+path.sep)
        && !f.p.includes(`${path.sep}.fingerprint${path.sep}`)
        && f.p.includes(`-${hash}`) && !removedPaths.has(f.p));
      const complete = all.filter(f=>path.dirname(f.p)===parent).length===group.length;
      if (!surviving && complete && (group.every(f=>f.time<cutoff) || remaining>cap))
        for (const f of group) remove(f);
    }
    // Only known profile roots can be sacrificed, and only after obsolete
    // generations. Delete walker-admitted files, never excluded symlinks/repos.
    if (protectedSize > cap) for (const profile of profiles) {
      if (remaining <= cap) break;
      const current = inventory(project);
      if (current.some(e=>processReason(e))) throw Error('live-cargo-or-unknown-process');
      for (const f of profile.files) if (!removedPaths.has(f.p)) remove(f);
      if (!dry) {
        for (const p of directories(profile.p)) {
          try { fs.rmdirSync(p); } catch (e) { if (!['ENOTEMPTY','EEXIST'].includes(e.code)) throw e; }
        }
      }
    }
    report(wt,before,dry?before:remaining,`${dry?'dry-run ':''}reclaim_bytes=${removed} planner=${planner}${remaining>cap?(protectedSize>cap?' protected-over-cap':' cap-unreachable'):''}`);
  } catch (e) {
    report(wt,before,before,`skipped=${String(e.message).split('\n')[0]}`);
    if (e.code !== 'FM_TREEHOUSE_NOT_FOUND') {
      console.error(`${wt}: ${e.stderr || e.message}`);
      process.exitCode = 1;
    }
  }
}
function withCargoLocks(project, entry) {
  const wt = entry.path;
  if (!sameRepo(project,wt)) {report(wt,0,0,'skipped=not-pool-copy');return;}
  const targets = boundary(wt);
  if (explain) {
    for (const target of targets) console.log(`${target} category=cargo-target bytes=${bytes(files(target))}`);
    const output=run('bash',['-c','. "$1"; fm_prune_build_output "$2" dry-run','_',path.join(dir,'fm-build-output-lib.sh'),wt]);
    if(output) console.log(output);
  }
  const reason = processReason(entry);
  if (reason) {
    let size=0;try {size=bytes(files(path.join(wt,'target')));}catch{}
    report(wt,size,size,`skipped=${reason}`);return;
  }
  // Cargo uses flock on each profile's .cargo-lock. Only open existing regular
  // files beneath the eligible output root; a symlink never redirects a lock.
  if (!targets.length) {report(wt,0,0,'skipped=no-eligible-rust-output');return;}
  const locks = targets.flatMap(target=>files(target)).filter(f => path.basename(f.p)==='.cargo-lock').map(f=>f.p);
  let argv = [process.execPath, fileURLToPath(import.meta.url), '--locked-copy',project,wt,
    '--locked-targets',JSON.stringify(targets), '--age-hours',String(age),'--max-gb',String(maxGB), ...(dry?['--dry-run']:[]), ...(explain?['--explain',explain]:[])];
  // Read-only opens never recreate a lock removed by a live worker. Keep each
  // descriptor open in its shell until the entire nested sweep returns.
  for (const lock of locks) argv = ['bash','-c',
    'exec {fd}<"$1" || exit 76; shift; flock -n -E 75 "$fd" || exit $?; "$@"',
    '_',lock,...argv];
  try {const output=run(argv[0],argv.slice(1),{timeout:240000});if(output) console.log(output);}
  catch(e) {
    if(e.status===76 && locks.some(lock=>!exists(lock))) {report(wt,0,0,'skipped=copy-changed-during-sweep');}
    else if(e.status===75) {const size=bytes(targets.flatMap(target=>files(target)));report(wt,size,size,'skipped=live-cargo-lock');}
    else {if(e.stdout) process.stdout.write(e.stdout);console.error(`${wt}: sweep failed: ${e.stderr || e.message}`);process.exitCode=1;}
  }
}
if (lockedCopy) {
  const current=boundary(lockedCopy[1]);
  if(JSON.stringify(current)!==JSON.stringify(lockedTargets)) throw Error('output-boundary-changed');
  for (const target of current) sweep(...lockedCopy,target);
}
else {
  const registry = path.join(process.env.FM_DATA_OVERRIDE || path.join(home,'data'), 'projects.md');
  const names = exists(registry) ? [...new Set(fs.readFileSync(registry,'utf8').split('\n').map(l => /^- ([^\s/]+)(?:\s|$)/.exec(l)?.[1]).filter(n=>n && n!=='.' && n!=='..'))] : [];
  const audited = [], captured = [];
  for (const name of names) {
    let project = path.resolve(process.env.FM_PROJECTS_OVERRIDE || path.join(home,'projects'),name);
    if (!exists(project) && name === path.basename(root)) project = root;
    if (!exists(project)) {report(project,0,0,'skipped=no-clone');continue;}
    try {
      const entries = inventory(project);
      captured.push({project, entries});
      audited.push(...entries.map(entry => `${project}\t${entry.path}`));
    } catch(e) {
      audited.push(`${project}\t!inventory-unavailable`);
      if (e.code === 'FM_TREEHOUSE_NOT_FOUND') report(project,0,0,'skipped=treehouse-not-found');
      else console.error(`${project}: inventory failed: ${e.message}`);
      if (scheduled || e.code !== 'FM_TREEHOUSE_NOT_FOUND') process.exitCode=1;
    }
  }
  for (const {project, entries} of captured) {
    for (const entry of entries) {
      try {
        if (!explain || entry.path === explain) withCargoLocks(project,entry);
      } catch(e) {
        console.error(`${entry.path}: sweep failed: ${e.message}`);
        process.exitCode=1;
      }
    }
  }
  // The pool budget audit follows every scheduled run over the inventory it
  // just swept; fm-pool-footprint.sh owns the record, check, and wake contract.
  if (scheduled) {
    try {
      const output = execFileSync(path.join(dir,'fm-pool-footprint.sh'), ['--pool-audit'],
        {encoding:'utf8', input:audited.map(row => `${row}\n`).join(''), timeout:240000, stdio:['pipe','pipe','pipe']}).trim();
      if (output) console.log(output);
    } catch(e) {console.error(`pool budget audit failed: ${e.stderr || e.message}`);process.exitCode=1;}
  }
}
