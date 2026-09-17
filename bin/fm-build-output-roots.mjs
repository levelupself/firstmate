// Rule executor for fm-build-output-lib.sh. Git protection uses the owning copy;
// ignored scratch repositories are disposable on return, including their .git.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
const [wtArg, mode, ...rules] = process.argv.slice(2);
const wt = path.resolve(wtArg);
const git = (...args) => execFileSync('git', ['-C', wt, ...args], {encoding:'utf8', maxBuffer:64*1024*1024});
const stat = p => { try { return fs.lstatSync(p); } catch(e) { if(e.code==='ENOENT') return null; throw e; } };
const directory = p => stat(p)?.isDirectory();
const regular = p => stat(p)?.isFile();
if (!directory(wt) || fs.realpathSync(wt)!==wt || git('rev-parse','--show-toplevel').trim()!==wt) throw Error('invalid-copy');
const protectedPaths=git('ls-files','-z','--cached','--others','--exclude-standard').split('\0').filter(Boolean);
const ignoredPaths=git('ls-files','-z','--others','--ignored','--exclude-standard','--directory').split('\0').filter(Boolean);
function eligible(p) {
  const rel=path.relative(wt,p);
  if(protectedPaths.some(f=>f===rel || f.startsWith(rel+'/') || (f.endsWith('/') && rel.startsWith(f)))) return false;
  return ignoredPaths.some(f=>f===rel || f.startsWith(rel+'/') || (f.endsWith('/') && rel.startsWith(f)));
}
const targets=[];
function cargo(p) {
  if (regular(path.join(p,'.rustc_info.json')) || regular(path.join(p,'CACHEDIR.TAG'))) return true;
  function fingerprints(dir) {
    for(const name of fs.readdirSync(dir)) {
      if(name==='.git') continue;
      const child=path.join(dir,name);
      if(!directory(child)) continue;
      if(name==='.fingerprint' || fingerprints(child)) return true;
    }
    return false;
  }
  return fingerprints(p);
}
function discover(p) {
  for(const name of fs.readdirSync(p)) {
    if(name==='.git') continue;
    const child=path.join(p,name);
    if(!directory(child)) continue;
    if(name==='target' && cargo(child) && eligible(child)) {targets.push(child);continue;}
    discover(child);
  }
}
if(rules.includes('cargo-target')) discover(wt);
// Preserve the existing manifest-based root rule for returned incomplete builds.
const rootTarget=path.join(wt,'target');
if(rules.includes('root-cargo') && regular(path.join(wt,'Cargo.toml')) && directory(rootTarget) && eligible(rootTarget) && !targets.includes(rootTarget)) targets.unshift(rootTarget);
if(mode==='targets') {
  process.stdout.write(JSON.stringify(targets));
} else {
  const scratch=path.join(wt,'.oracle-work');
  const scratchEligible=rules.includes('oracle-scratch') && directory(scratch) && eligible(scratch);
  const groups=new Map();
  function scan(root, oracle=false) {
    const dirs=[];
    function visit(p, build=false, gitData=false) {
      const s=stat(p);
      if(!s || s.isSymbolicLink()) return;
      if(s.isDirectory()) {
        const names=fs.readdirSync(p);
        if(!oracle && names.includes('.git')) return;
        for(const name of names) visit(path.join(p,name),build || path.basename(p)==='target',gitData || path.basename(p)==='.git');
        dirs.push(p);
      } else if(s.isFile()) {
        const evidence=oracle && !build && !gitData && /\.(json|md|log|txt|patch)$/.test(p) && s.size<50000000;
        const category=oracle?(evidence?'oracle-evidence':'oracle-scratch'):'cargo-target';
        const key=`${root}\tcategory=${category}`;
        if(!groups.has(key)) groups.set(key,[]);
        groups.get(key).push({p,s,keep:evidence});
      }
    }
    visit(root);
    return dirs;
  }
  const dirs=[];
  for(const target of targets) {
    // Scratch categories include its targets once, not again as separate totals.
    if(scratchEligible && target.startsWith(scratch+path.sep)) continue;
    dirs.push(...scan(target));
  }
  if(scratchEligible) dirs.push(...scan(scratch,true));
  let removedGit=false;
  for(const [key,entries] of groups) {
    const before=entries.reduce((sum,f)=>sum+f.s.size,0);
    let after=before;
    if(mode==='delete') for(const f of entries) {
      if(f.keep) continue;
      const now=fs.lstatSync(f.p);
      if(!now.isFile() || now.ino!==f.s.ino || now.dev!==f.s.dev || now.size!==f.s.size || now.mtimeMs!==f.s.mtimeMs) throw Error('artifact-changed');
      fs.unlinkSync(f.p);after-=f.s.size;
      if(path.basename(f.p)==='.git') removedGit=true;
    }
    console.log(`${mode==='delete'?'pruned':'would prune'} ${key}\tbytes_before=${before}\tbytes_after=${after} (${Math.ceil(before/1024)} KiB)`);
  }
  if(mode==='delete') {
    for(const p of dirs) try {fs.rmdirSync(p);} catch(e) {if(!['ENOTEMPTY','EEXIST','ENOENT'].includes(e.code)) throw e;}
    if(removedGit) git('worktree','prune');
  } else if(mode!=='dry-run') throw Error('invalid-mode');
}
