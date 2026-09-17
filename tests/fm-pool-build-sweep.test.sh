#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-pool-build-sweep)
export FM_HOME="$TMP_ROOT/home" TEST_INVENTORY="$TMP_ROOT/inventory.json"
mkdir -p "$FM_HOME"/{projects/rust,data,state} "$TMP_ROOT/fakebin"
PROJECT="$FM_HOME/projects/rust"
git -C "$PROJECT" init -q
printf 'target/\n' > "$PROJECT/.gitignore"
printf '[package]\nname="demo"\nversion="0.1.0"\nedition="2021"\n' > "$PROJECT/Cargo.toml"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm baseline
printf '%s\n' '- rust [no-mistakes] - fixture' > "$FM_HOME/data/projects.md"
for name in age size busy plain huge; do
  git -C "$PROJECT" worktree add -q --detach "$TMP_ROOT/pool/$name/rust"
done
cat > "$TMP_ROOT/fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
[ "$*" = 'status --json' ] || exit 1
cat "$TEST_INVENTORY"
EOF
chmod +x "$TMP_ROOT/fakebin/treehouse"
export PATH="$TMP_ROOT/fakebin:$PATH"
# A deterministic Cargo-shaped fingerprint graph: three builds of one unit.
node - "$TMP_ROOT" <<'JS'
const fs=require('fs'), root=process.argv[2];
const entries=['age','size','busy','plain','huge'].map(name=>({name,path:`${root}/pool/${name}/rust`,status:'in-use',lease_id:'',processes:name==='busy'?[{pid:123,name:'cargo'}]:[]}));
fs.writeFileSync(`${root}/inventory.json`,JSON.stringify(entries));
for (const e of entries) {
 if(e.name==='plain'){fs.unlinkSync(`${e.path}/Cargo.toml`);continue;}
 for(let i=1;i<=3;i++) {
  const hash=String(i).repeat(16), dir=`${e.path}/target/debug/.fingerprint/demo-${hash}`;
  fs.mkdirSync(dir,{recursive:true}); fs.mkdirSync(`${e.path}/target/debug/deps`,{recursive:true});
  const json={rustc:1,features:'[]',target:1,profile:1,path:1,deps:[],local:[],compile_kind:0};
  fs.writeFileSync(`${dir}/lib-demo.json`,JSON.stringify(json));fs.writeFileSync(`${dir}/lib-demo`,hash);
  fs.writeFileSync(`${e.path}/target/debug/deps/libdemo-${hash}.rlib`,Buffer.alloc(e.name==='huge'?65536:16384));
  const t=new Date(Date.now()-(e.name==='age'||e.name==='busy'?96-i*24:4-i)*3600000);
  for(const p of [`${dir}/lib-demo.json`,`${dir}/lib-demo`,dir,`${e.path}/target/debug/deps/libdemo-${hash}.rlib`])fs.utimesSync(p,t,t);
 }
 fs.mkdirSync(`${e.path}/.oracle-work`);fs.writeFileSync(`${e.path}/.oracle-work/keep`,'source');
}
JS
SWEEP="$ROOT/bin/fm-pool-build-sweep.sh"
# Debugger scratch symlinks and nested repositories must not hide stale builds.
wt="$TMP_ROOT/pool/age/rust"
mkdir -p "$wt/target/scratch" "$wt/target/nested/.git" "$wt/target/linked-repo"
printf keep > "$TMP_ROOT/outside"
ln -s "$TMP_ROOT/outside" "$wt/target/scratch/system-lib"
ln -s "$TMP_ROOT/absent" "$wt/target/scratch/dangling"
printf keep > "$wt/target/nested/keep"
printf 'gitdir: elsewhere\n' > "$wt/target/linked-repo/.git"
printf keep > "$wt/target/linked-repo/keep"
for source in argument environment; do
  if [ "$source" = argument ]; then
    command=("$SWEEP" --age-hours 0)
  else
    command=(env FM_POOL_BUILD_AGE_HOURS=0 "$SWEEP")
  fi
  if "${command[@]}" > "$TMP_ROOT/zero-out" 2> "$TMP_ROOT/zero-error"; then
    fail "zero age from $source was accepted"
  fi
  assert_contains "$(cat "$TMP_ROOT/zero-error")" 'age-hours and max-gb must be positive' 'zero age rejection lacks a clear error'
  [ ! -s "$TMP_ROOT/zero-out" ] || fail 'zero age reached copy sweeping'
  for name in age size busy huge; do
    for hash in 1111111111111111 2222222222222222 3333333333333333; do
      assert_present "$TMP_ROOT/pool/$name/rust/target/debug/deps/libdemo-$hash.rlib" 'zero age rejection deleted an artifact'
    done
  done
done
pass 'zero age is rejected from arguments and environment before sweeping'
"$SWEEP" --dry-run > "$TMP_ROOT/dry" || fail 'build sweep executable must support dry-run'
assert_present "$TMP_ROOT/pool/age/rust/target/debug/deps/libdemo-1111111111111111.rlib" 'dry-run deleted old output'
"$SWEEP" > "$TMP_ROOT/age"
assert_absent "$TMP_ROOT/pool/age/rust/target/debug/deps/libdemo-1111111111111111.rlib" 'old generation retained'
assert_absent "$TMP_ROOT/pool/age/rust/target/debug/deps/libdemo-2222222222222222.rlib" 'second old generation retained'
assert_present "$TMP_ROOT/pool/age/rust/target/debug/deps/libdemo-3333333333333333.rlib" 'newest generation deleted'
assert_present "$TMP_ROOT/pool/busy/rust/target/debug/deps/libdemo-1111111111111111.rlib" 'live cargo output deleted'
assert_contains "$(cat "$TMP_ROOT/age")" 'live-cargo' 'skip reason missing'
assert_absent "$TMP_ROOT/pool/plain/rust/target" 'non-Rust copy changed'
[ -L "$wt/target/scratch/system-lib" ] || fail 'sweep deleted scratch symlink'
[ -L "$wt/target/scratch/dangling" ] || fail 'sweep deleted dangling symlink'
assert_present "$wt/target/nested/keep" 'sweep deleted nested repository'
assert_present "$wt/target/linked-repo/keep" 'sweep deleted linked repository'
[ "$(cat "$TMP_ROOT/outside")" = keep ] || fail 'sweep followed scratch symlink'
pass 'age sweep keeps newest fingerprint generation and skips cargo and non-Rust copies'
"$SWEEP" --max-gb 0.00004 > "$TMP_ROOT/size"
assert_absent "$TMP_ROOT/pool/size/rust/target/debug/deps/libdemo-1111111111111111.rlib" 'size sweep did not evict youngest-eligible old generation'
assert_present "$TMP_ROOT/pool/size/rust/target/debug/deps/libdemo-3333333333333333.rlib" 'size sweep deleted newest generation'
assert_present "$TMP_ROOT/pool/huge/rust/target/debug/deps/libdemo-3333333333333333.rlib" 'oversized newest generation deleted'
assert_contains "$(cat "$TMP_ROOT/size")" 'protected-over-cap' 'oversized protected build not reported'
assert_present "$TMP_ROOT/pool/size/rust/.oracle-work/keep" 'source-adjacent data deleted'
pass 'size eviction is oldest first and stops before protected artifacts'
# A real Cargo lock excludes deletion even when a stale inventory missed it.
mkdir -p "$TMP_ROOT/pool/size/rust/target/debug"
# shellcheck disable=SC2016 # Positional arguments expand in the child shell.
flock "$TMP_ROOT/pool/size/rust/target/debug/.cargo-lock" bash -c '
  "$1" --max-gb 0.000001 > "$2"
' _ "$SWEEP" "$TMP_ROOT/locked"
assert_contains "$(cat "$TMP_ROOT/locked")" 'live-cargo-lock' 'Cargo profile lock was not respected'
pass 'Cargo profile locks close the inventory-to-deletion race'

# The helper owns a durable attempt marker, including failed attempts.
"$SWEEP" --periodic
for _ in {1..100}; do
  [ ! -f "$FM_HOME/state/.pool-build-sweep.last" ] || break
  sleep 0.05
done
assert_present "$FM_HOME/state/.pool-build-sweep.last" 'periodic sweep did not record its attempt'
cp "$FM_HOME/state/.pool-build-sweep.last" "$TMP_ROOT/marker"
"$SWEEP" --periodic
cmp "$TMP_ROOT/marker" "$FM_HOME/state/.pool-build-sweep.last" || fail 'second periodic launch changed durable cadence'
# Wait for the finite worker so cleanup never races it.
flock "$FM_HOME/state/.pool-build-sweep.lock" true
pass 'periodic cadence survives separate helper processes'

# Exercise a real three-generation build with no downloads. An installed but
# unselected Rust toolchain is sufficient; never change machine toolchain state.
if command -v rustup >/dev/null 2>&1; then
  toolchain=$(rustup toolchain list | head -1 | awk '{print $1}')
else toolchain=; fi
if [ -n "$toolchain" ]; then
  wt="$TMP_ROOT/pool/age/rust"
  rm -rf "$wt/target"
  mkdir -p "$wt/src" "$wt/helper/src"
  printf '[dependencies]\nhelper={path="helper"}\n' >> "$wt/Cargo.toml"
  printf '[package]\nname="helper"\nversion="0.1.0"\nedition="2021"\n' > "$wt/helper/Cargo.toml"
  printf 'pub fn value() -> u32 { 42 }\n' > "$wt/helper/src/lib.rs"
  printf 'fn main() { println!("{}", helper::value()); }\n' > "$wt/src/main.rs"
  for generation in one two three; do
    CARGO_TARGET_DIR="$wt/target" RUSTFLAGS="-C metadata=$generation" \
      cargo "+$toolchain" build --offline --manifest-path "$wt/Cargo.toml" >/dev/null 2>&1
  done
  # All generations are old; the most recently written fingerprint still wins.
  node - "$wt/target" <<'JS'
const fs=require('fs'),path=require('path');
const seen=new Set();
function age(p){const s=fs.statSync(p),key=`${s.dev}:${s.ino}`;if(seen.has(key))return;seen.add(key);if(s.isDirectory())for(const n of fs.readdirSync(p))age(path.join(p,n));fs.utimesSync(p,new Date(s.atimeMs-7*86400000),new Date(s.mtimeMs-7*86400000));}
age(process.argv[2]);
for (const p of ['src/main.rs','Cargo.toml','helper/src/lib.rs','helper/Cargo.toml']) {const t=new Date(Date.now()-10*86400000);fs.utimesSync(path.join(process.argv[2],'..',p),t,t);}
JS
  "$SWEEP" --max-gb 8 > "$TMP_ROOT/real" || { cat "$TMP_ROOT/real"; fail "real Cargo sweep failed"; }
  CARGO_TARGET_DIR="$wt/target" RUSTFLAGS='-C metadata=three' \
    cargo "+$toolchain" build --offline -v --manifest-path "$wt/Cargo.toml" > "$TMP_ROOT/rebuild" 2>&1
  assert_contains "$(cat "$TMP_ROOT/rebuild")" 'Fresh demo' 'latest build was not incremental after sweep'
  count=$(find "$wt/target/debug/.fingerprint" -name 'bin-demo.json' | wc -l)
  [ "$count" -eq 1 ] || fail "expected one real Cargo generation, got $count"
  pass 'real Cargo build remains Fresh after two obsolete generations are evicted'
else
  echo 'ok - real Cargo proof unavailable (fingerprint fixture exercised instead)'
fi
# A real process in the copy is represented in the pool's process inventory.
node - "$SWEEP" "$TEST_INVENTORY" "$TMP_ROOT" <<'JS'
const fs=require('fs'),cp=require('child_process');
const [sweep,inventory,root]=process.argv.slice(2), wt=`${root}/pool/huge/rust`;
const child=cp.spawn('sleep',['60'],{cwd:wt,argv0:'cargo',stdio:'ignore'});
try {
 const entries=JSON.parse(fs.readFileSync(inventory));
 entries.find(e=>e.name==='huge').processes=[{pid:child.pid,name:'cargo'}];
 fs.writeFileSync(inventory,JSON.stringify(entries));
 process.kill(child.pid,0);
 const output=cp.execFileSync(sweep,['--max-gb','0.000001'],{encoding:'utf8'});
 if(!output.split('\n').some(l=>l.startsWith(wt+'\t') && l.includes('skipped=live-cargo')))throw Error('live process was not skipped');
 if(!fs.existsSync(`${wt}/target/debug/deps/libdemo-3333333333333333.rlib`))throw Error('live build artifact deleted');
} finally {child.kill();}
JS
pass 'real live process represented by Treehouse excludes its copy'

# An installed planner may suggest deleting current output. Only independently
# proved obsolete paths may cross the deletion boundary, including dry-run.
cat > "$TMP_ROOT/fakebin/cargo-sweep" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *' --dry-run '* ]] || exit 99
[[ " $* " == *' --maxsize '* ]] || exit 98
printf '%s\n' "$*" >> "$TEST_PLANNER_LOG"
find "$CARGO_TARGET_DIR/debug/deps" -type f -print | while IFS= read -r file; do
  printf '[DEBUG] Would remove: "%s"\n' "$file"
done
EOF
chmod +x "$TMP_ROOT/fakebin/cargo-sweep"
export TEST_PLANNER_LOG="$TMP_ROOT/planner.log"
"$SWEEP" --max-gb 0.000001 > "$TMP_ROOT/planner"
assert_present "$TEST_PLANNER_LOG" 'installed cargo-sweep was not used'
assert_present "$TMP_ROOT/pool/size/rust/target/debug/deps/libdemo-3333333333333333.rlib" 'planner suggestion deleted newest generation'
assert_contains "$(cat "$TMP_ROOT/planner")" 'planner=cargo-sweep' 'installed planner result was not consumed'
pass 'installed cargo-sweep is filtered through newest-generation protection'

# Feature and Cargo profile variants compete within each profile directory.
wt="$TMP_ROOT/pool/variants/rust"
git -C "$PROJECT" worktree add -q --detach "$wt"
node - "$wt" "$TEST_INVENTORY" <<'JS'
const fs=require('fs'), [wt,inventory]=process.argv.slice(2);
fs.writeFileSync(inventory,JSON.stringify([{path:wt,processes:[]}]));
for(const profile of ['debug','release','kernel-b/debug']) for(let i=1;i<=2;i++) {
 const hash=String(i).repeat(16), base=`${wt}/target/${profile}`, fp=`${base}/.fingerprint/demo-${hash}`;
 fs.mkdirSync(fp,{recursive:true});fs.mkdirSync(`${base}/deps`,{recursive:true});
 const entries=[[`${fp}/lib-demo.json`,JSON.stringify({features:i===1?'[]':'["extra"]',profile:i,deps:[],compile_kind:0})],[`${fp}/lib-demo`,hash],[`${base}/deps/libdemo-${hash}.rlib`,Buffer.alloc(16384)]];
 for(const [p,data] of entries){fs.writeFileSync(p,data);const t=new Date(Date.now()-(72-i)*3600000);fs.utimesSync(p,t,t);}
}
JS
"$SWEEP" > "$TMP_ROOT/variants"
for profile in debug release kernel-b/debug; do
  assert_absent "$wt/target/$profile/deps/libdemo-1111111111111111.rlib" 'feature variant retained as independently current'
  assert_present "$wt/target/$profile/deps/libdemo-2222222222222222.rlib" 'newest feature variant deleted'
done
"$SWEEP" --explain "$wt" > "$TMP_ROOT/explain"
assert_contains "$(cat "$TMP_ROOT/explain")" 'generation_key=' 'explain omitted generation keys'
assert_contains "$(cat "$TMP_ROOT/explain")" 'protected=2222222222222222' 'explain omitted protected generation'
assert_contains "$(cat "$TMP_ROOT/explain")" 'evictable_bytes=0' 'explain omitted evictable bytes'
"$SWEEP" --dry-run --max-gb 0.000001 > "$TMP_ROOT/profile-dry"
assert_present "$wt/target/kernel-b/debug/deps/libdemo-2222222222222222.rlib" 'profile dry-run deleted output'
"$SWEEP" --max-gb 0.000001 > "$TMP_ROOT/profile-cap"
assert_absent "$wt/target/kernel-b" 'oversized newest set did not evict custom target directory'
for profile in debug release; do
  assert_present "$wt/target/$profile/deps/libdemo-2222222222222222.rlib" 'cap evicted standard profile'
done
assert_contains "$(cat "$TMP_ROOT/profile-cap")" 'protected-over-cap' 'remaining protected output not reported'
pass 'feature variants supersede and custom profiles yield to the cap with explain and dry-run support'

node - "$wt" <<'JS'
const fs=require('fs'), wt=process.argv[2], base=`${wt}/target/kernel-c/debug`;
const hash='3333333333333333', fp=`${base}/.fingerprint/demo-${hash}`;
fs.mkdirSync(fp,{recursive:true});fs.mkdirSync(`${base}/deps`,{recursive:true});
fs.writeFileSync(`${base}/.cargo-lock`,'');
fs.writeFileSync(`${fp}/lib-demo.json`,JSON.stringify({deps:[],compile_kind:0}));
fs.writeFileSync(`${fp}/lib-demo`,hash);
fs.writeFileSync(`${base}/deps/libdemo-${hash}.rlib`,Buffer.alloc(16384));
for(const kind of ['dangling','directory','file']) {
 const repo=`${wt}/target/kernel-c/${kind}`;
 fs.mkdirSync(`${repo}/empty/descendant`,{recursive:true});
 if(kind==='dangling') fs.symlinkSync('absent',`${repo}/.git`);
 else if(kind==='directory') fs.mkdirSync(`${repo}/.git`);
 else fs.writeFileSync(`${repo}/.git`,'gitdir: elsewhere\n');
}
fs.mkdirSync(`${wt}/target/kernel-c/ordinary/empty`,{recursive:true});
fs.symlinkSync('absent',`${wt}/target/kernel-c/scratch-link`);
fs.writeFileSync(`${wt}/lock-before.json`,JSON.stringify(fs.statSync(`${base}/.cargo-lock`)));
JS
cat > "$TMP_ROOT/lock-contender.cjs" <<'JS'
const fs=require('node:fs'), cp=require('node:child_process');
const unlink=fs.unlinkSync;
fs.unlinkSync=function(p,...args) {
 const result=unlink.call(this,p,...args);
 if(p===process.env.TEST_EVICT_ARTIFACT) {
  const lock=process.env.TEST_EVICT_LOCK;
  const before=fs.existsSync(lock)?fs.statSync(lock):null;
  const contender=cp.spawnSync('flock',['-n','-E','75',lock,'true']);
  fs.writeFileSync(process.env.TEST_CONTENDER_RESULT,JSON.stringify({before,status:contender.status}));
 }
 return result;
};
JS
lock="$wt/target/kernel-c/debug/.cargo-lock"
TEST_EVICT_LOCK="$lock" \
TEST_EVICT_ARTIFACT="$wt/target/kernel-c/debug/deps/libdemo-3333333333333333.rlib" \
TEST_CONTENDER_RESULT="$TMP_ROOT/contender.json" \
NODE_OPTIONS="--require=$TMP_ROOT/lock-contender.cjs" \
  "$SWEEP" --max-gb 0.000001 > "$TMP_ROOT/profile-lock"
node - "$wt" "$TMP_ROOT/contender.json" <<'JS'
const fs=require('fs'), assert=require('assert/strict'), [wt,result]=process.argv.slice(2);
const original=JSON.parse(fs.readFileSync(`${wt}/lock-before.json`));
const contender=JSON.parse(fs.readFileSync(result));
assert.equal(contender.status,75,'concurrent build acquired lock during eviction');
assert.ok(contender.before,'lock disappeared during eviction');
const after=fs.statSync(`${wt}/target/kernel-c/debug/.cargo-lock`);
for(const stat of [contender.before,after]) {
 assert.equal(stat.ino,original.ino,'Cargo lock inode replaced');
 assert.equal(stat.dev,original.dev,'Cargo lock device changed');
}
JS
flock -n "$lock" true || fail 'Cargo lock was not released after eviction'
assert_absent "$wt/target/kernel-c/debug/deps" 'locked custom profile artifacts retained'
assert_absent "$wt/target/kernel-c/ordinary" 'ordinary empty directories retained'
for kind in dangling directory file; do
  assert_present "$wt/target/kernel-c/$kind/empty/descendant" 'nested repository directories pruned'
done
[ -L "$wt/target/kernel-c/dangling/.git" ] || fail 'dangling repository entry deleted'
[ -L "$wt/target/kernel-c/scratch-link" ] || fail 'custom profile symlink deleted'
pass 'custom eviction preserves Cargo lock serialization and shared walker exclusions'

# Nested output is eligible without a root manifest, including linked worktrees.
wt="$TMP_ROOT/pool/nested/rust"
git -C "$PROJECT" worktree add -q --detach "$wt"
# Keep the ignore rule local to this disposable fixture.
printf '.oracle-work/\n' >> "$wt/.gitignore"
nested="$wt/.oracle-work/extension-worktree"
git -C "$PROJECT" worktree add -q --detach "$nested"
node - "$wt" "$TEST_INVENTORY" <<'JS'
const fs=require('fs'), [wt,inventory]=process.argv.slice(2);
fs.writeFileSync(inventory,JSON.stringify([{path:wt,processes:[]}]));
for(const parent of ['x','extension-worktree']) for(let i=1;i<=2;i++) {
 const hash=String(i).repeat(16), base=`${wt}/.oracle-work/${parent}/target/debug`, fp=`${base}/.fingerprint/demo-${hash}`;
 fs.mkdirSync(fp,{recursive:true});fs.mkdirSync(`${base}/deps`,{recursive:true});
 for(const [p,data] of [[`${fp}/lib-demo.json`,JSON.stringify({deps:[],compile_kind:0})],[`${fp}/lib-demo`,hash],[`${base}/deps/libdemo-${hash}.rlib`,Buffer.alloc(16384)]]) {
  fs.writeFileSync(p,data);const t=new Date(Date.now()-(72-i)*3600000);fs.utimesSync(p,t,t);
 }
}
fs.writeFileSync(`${wt}/.oracle-work/report.json`,'{}');
for(const ext of ['md','log','txt','patch']) fs.writeFileSync(`${wt}/.oracle-work/report.${ext}`,'evidence');
fs.mkdirSync(`${wt}/.oracle-work/x/target/notes`,{recursive:true});
fs.writeFileSync(`${wt}/.oracle-work/x/target/notes/build.json`,'{}');
fs.mkdirSync(`${wt}/outside-target`,{recursive:true});
fs.writeFileSync(`${wt}/outside-target/keep`,'preserve');
fs.symlinkSync(`${wt}/outside-target`,`${wt}/.oracle-work/directory-link`);
fs.writeFileSync(`${wt}/.oracle-work/disposable.jar`,'binary');
fs.writeFileSync(`${wt}/.oracle-work/large.log`,'');fs.truncateSync(`${wt}/.oracle-work/large.log`,50000000);
fs.symlinkSync(process.env.TMP_OUTSIDE || `${wt}/Cargo.toml`,`${wt}/.oracle-work/link`);
JS
"$SWEEP" --explain "$wt" > "$TMP_ROOT/nested-explain"
assert_contains "$(cat "$TMP_ROOT/nested-explain")" "$wt/.oracle-work/x/target" 'explain omitted nested target'
assert_contains "$(cat "$TMP_ROOT/nested-explain")" 'category=oracle-evidence' 'explain omitted evidence category'
node - "$SWEEP" "$wt" "$TEST_INVENTORY" <<'JS'
const fs=require('fs'), cp=require('child_process'), assert=require('assert/strict');
const [sweep,wt,inventory]=process.argv.slice(2);
const lock=`${wt}/.oracle-work/extension-worktree/target/debug/.cargo-lock`;
fs.writeFileSync(lock,'');
function snapshot(p) {
 const stat=fs.lstatSync(p);
 if(stat.isSymbolicLink()) return {link:fs.readlinkSync(p)};
 if(stat.isDirectory()) return Object.fromEntries(fs.readdirSync(p).sort().map(n=>[n,snapshot(`${p}/${n}`)]));
 return {size:stat.size,mtime:stat.mtimeMs,ino:stat.ino,data:fs.readFileSync(p).toString('base64')};
}
function size(p) {
 const stat=fs.lstatSync(p);
 return stat.isSymbolicLink()?0:stat.isDirectory()?fs.readdirSync(p).reduce((sum,n)=>sum+size(`${p}/${n}`),0):stat.size;
}
const before=snapshot(wt);
for(const busy of [true,false]) {
 fs.writeFileSync(inventory,JSON.stringify([{path:wt,processes:busy?[{pid:123,name:'cargo'}]:[]}]));
 const output=busy
  ?cp.execFileSync(sweep,['--explain',wt],{encoding:'utf8'})
  :cp.execFileSync('flock',[lock,sweep,'--explain',wt],{encoding:'utf8'});
 assert.ok(output.includes(`skipped=${busy?'live-cargo':'live-cargo-lock'}`),output);
 for(const parent of ['x','extension-worktree']) {
  const target=`${wt}/.oracle-work/${parent}/target`;
  assert.ok(output.includes(`${target} category=cargo-target bytes=${size(target)}`),output);
 }
 for(const category of ['oracle-scratch','oracle-evidence'])
  assert.match(output,new RegExp(`category=${category}[^\\n]*bytes_before=[1-9][0-9]*`));
 assert.deepEqual(snapshot(wt),before,'explain changed copy contents or file metadata');
}
JS
pass 'busy-process and held-lock explanations report nested sizes without changing files'
# Nested locks serialize the whole copy before any target is swept.
# shellcheck disable=SC2016
flock "$nested/target/debug/.cargo-lock" bash -c '"$1" > "$2"' _ "$SWEEP" "$TMP_ROOT/nested-lock"
assert_contains "$(cat "$TMP_ROOT/nested-lock")" 'live-cargo-lock' 'nested Cargo lock ignored'
assert_present "$wt/.oracle-work/x/target/debug/deps/libdemo-1111111111111111.rlib" 'copy swept while nested Cargo lock held'
"$SWEEP" > "$TMP_ROOT/nested-sweep"
for parent in x extension-worktree; do
  assert_absent "$wt/.oracle-work/$parent/target/debug/deps/libdemo-1111111111111111.rlib" 'nested stale generation retained'
  assert_present "$wt/.oracle-work/$parent/target/debug/deps/libdemo-2222222222222222.rlib" 'nested newest generation deleted'
done
assert_present "$wt/.oracle-work/disposable.jar" 'live sweep deleted non-target scratch'
"$SWEEP" --return-copy "$wt" --dry-run > "$TMP_ROOT/nested-return-dry"
assert_present "$nested/.git" 'return dry-run deleted worktree metadata'
assert_present "$wt/.oracle-work/disposable.jar" 'return dry-run deleted scratch'
"$SWEEP" --return-copy "$wt" > "$TMP_ROOT/nested-return"
assert_absent "$wt/.oracle-work/x/target" 'return retained nested cargo target'
assert_absent "$nested" 'return retained nested worktree'
assert_absent "$wt/.oracle-work/disposable.jar" 'return retained scratch binary'
assert_absent "$wt/.oracle-work/large.log" 'return retained oversized evidence'
assert_present "$wt/.oracle-work/report.json" 'return deleted JSON evidence'
for ext in md log txt patch; do
  assert_present "$wt/.oracle-work/report.$ext" 'return deleted small evidence'
done
assert_present "$wt/outside-target/keep" 'return followed directory symlink'
assert_present "$wt/Cargo.toml" 'return followed scratch symlink'
[ -L "$wt/.oracle-work/link" ] || fail 'return removed scratch symlink'
if git -C "$PROJECT" worktree list --porcelain | rg -F "worktree $nested"; then fail 'return retained nested worktree registration'; fi
assert_contains "$(cat "$TMP_ROOT/nested-return")" 'bytes_after=' 'return omitted byte accounting'
pass 'nested targets sweep safely and returned scratch retains only small evidence and exclusions'

# Outer tracked content and ignore exceptions protect the entire scratch root.
for protection in tracked nonignored; do
  wt="$TMP_ROOT/pool/$protection-scratch/rust"
  git -C "$PROJECT" worktree add -q --detach "$wt"
  mkdir -p "$wt/.oracle-work"
  printf 'keep' > "$wt/.oracle-work/keep"
  printf 'discard' > "$wt/.oracle-work/scratch.jar"
  if [ "$protection" = tracked ]; then
    printf '.oracle-work/\n' >> "$wt/.gitignore"
    git -C "$wt" add -f .oracle-work/keep
  else
    printf '.oracle-work/*\n!.oracle-work/keep\n' >> "$wt/.gitignore"
  fi
  "$SWEEP" --return-copy "$wt" > "$TMP_ROOT/protected-return"
  assert_present "$wt/.oracle-work/keep" 'return deleted protected scratch file'
  assert_present "$wt/.oracle-work/scratch.jar" 'return failed to protect mixed scratch root'
done
pass 'tracked and nonignored scratch roots remain protected'
