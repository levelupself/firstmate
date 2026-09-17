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

# A failure inside the locked child must explain itself on stderr, not merely
# print the outer flock/bash argument list.
fingerprint="$TMP_ROOT/pool/size/rust/target/debug/.fingerprint/demo-3333333333333333/lib-demo"
cp "$fingerprint" "$TMP_ROOT/fingerprint.saved"
printf invalid > "$fingerprint"
rc=0
"$SWEEP" > "$TMP_ROOT/child-failure.out" 2> "$TMP_ROOT/child-failure.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'invalid fingerprint returned success'
assert_contains "$(cat "$TMP_ROOT/child-failure.err")" 'unknown-fingerprint-hash' 'locked child failure omitted its reason from stderr'
mv "$TMP_ROOT/fingerprint.saved" "$fingerprint"
pass 'locked child failure logs its concrete reason'


# Remove an enumerated lock before flock opens it, both with and without its
# parent directory. A real child error must retain stderr on its failure line.
cat > "$TMP_ROOT/lock-race.cjs" <<'JS'
const fs = require('node:fs'), cp = require('node:child_process');
const exec = cp.execFileSync;
cp.execFileSync = function(cmd, args, opts) {
  const lock = process.env.TEST_RACE_LOCK;
  if (args.includes(lock)) {
    if (process.env.TEST_LOCK_FAILURE === 'file') fs.unlinkSync(lock);
    else if (process.env.TEST_LOCK_FAILURE === 'directory') fs.rmSync(require('node:path').dirname(lock), {recursive:true});
    else return exec('bash', ['-c', 'echo "fixture lock permission denied" >&2; exit 73'], opts);
  }
  return exec(cmd, args, opts);
};
require('node:module').syncBuiltinESMExports();
JS
export TEST_RACE_LOCK="$TMP_ROOT/pool/size/rust/target/race/.cargo-lock"
for TEST_LOCK_FAILURE in file directory stderr; do
  export TEST_LOCK_FAILURE
  mkdir -p "${TEST_RACE_LOCK%/*}"
  touch "$TEST_RACE_LOCK"
  rc=0
  NODE_OPTIONS="--require=$TMP_ROOT/lock-race.cjs" "$SWEEP" > "$TMP_ROOT/race-$TEST_LOCK_FAILURE" 2>&1 || rc=$?
  output=$(cat "$TMP_ROOT/race-$TEST_LOCK_FAILURE")
  if [ "$TEST_LOCK_FAILURE" = stderr ]; then
    [ "$rc" -ne 0 ] || fail 'real lock failure returned success'
    assert_contains "$output" 'sweep failed: fixture lock permission denied' 'child stderr missing from failure line'
  else
    [ "$rc" -eq 0 ] || fail "vanished lock failed the sweep: $output"
    assert_contains "$output" 'skipped=copy-changed-during-sweep' 'vanished lock was not skipped'
  fi
done
rm -rf "${TEST_RACE_LOCK%/*}"
pass 'vanished locks skip the copy and genuine lock failures retain stderr'

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

# Pool budget wake: after a scheduled run, a project pool whose ignored
# footprint exceeds FM_POOL_TOTAL_BUDGET_GB gets one registered watcher check
# that surfaces exactly one wake per distinct over-budget total.
CHECK="$FM_HOME/state/pool-footprint.check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
printf '%s\n' fm-pr-check-migration-scan-v1 > "$FM_HOME/state/.pr-check-migration-scan-v1"
printf '%s\n' fm-pr-check-migration-v1 > "$FM_HOME/state/.pr-check-migration-v1"
chmod 0600 "$FM_HOME/state/.pr-check-migration-scan-v1" "$FM_HOME/state/.pr-check-migration-v1"
scheduled_sweep() {  # <total-budget-gb>
  rm -f "$FM_HOME/state/.pool-build-sweep.last"
  FM_POOL_TOTAL_BUDGET_GB="$1" "$SWEEP" --scheduled > "$TMP_ROOT/scheduled.out" 2>&1 \
    || fail "scheduled sweep failed: $(cat "$TMP_ROOT/scheduled.out")"
}
check_output() {
  [ -f "$CHECK" ] || { printf ''; return 0; }
  bash "$CHECK"
}
printf '.oracle-work/\n' >> "$PROJECT/.git/info/exclude"
for name in fat-a fat-b fat-c thin; do
  wt="$TMP_ROOT/pool/$name/rust"
  git -C "$PROJECT" worktree add -q --detach "$wt"
  mkdir -p "$wt/.oracle-work"
  case "$name" in
    fat-a) size=262144 ;;
    fat-b) size=131072 ;;
    fat-c) size=65536 ;;
    *) size=1024 ;;
  esac
  head -c "$size" /dev/zero | tr '\0' x > "$wt/.oracle-work/blob.bin"
done
node - "$TMP_ROOT" <<'JS'
const fs=require('fs'), root=process.argv[2];
const entries=['fat-a','fat-b','fat-c','thin'].map(name=>({name,path:`${root}/pool/${name}/rust`,status:'available',lease_id:'',processes:[]}));
fs.writeFileSync(`${root}/inventory.json`,JSON.stringify(entries));
JS
scheduled_sweep 0.0001
assert_present "$CHECK" 'over-budget pool did not write its watcher check'
assert_present "$FM_HOME/state/pool-footprint.check-trust" 'pool footprint check was not registered'
first=$(check_output)
[ -n "$first" ] || fail 'registered check printed nothing for an over-budget pool'
[ "$(printf '%s\n' "$first" | wc -l)" -eq 1 ] || fail "check printed more than one line: $first"
assert_contains "$first" 'rust' 'wake does not name the project'
for name in fat-a fat-b fat-c; do
  assert_contains "$first" "$TMP_ROOT/pool/$name/rust" "wake omits top copy $name"
done
assert_not_contains "$first" "$TMP_ROOT/pool/thin/rust" 'wake lists more than the top three copies'
[ -z "$(check_output)" ] || fail 'check repeated the wake for an unchanged total'
scheduled_sweep 0.0001
[ -z "$(check_output)" ] || fail 'a rerun with an unchanged total produced a second wake'
pass 'scheduled sweep surfaces one wake per over-budget pool total'

# The watcher itself trusts the registered check and surfaces the line once.
rm -f "$FM_HOME/state/.pool-footprint-surfaced"
FM_HOME="$FM_HOME" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 8 \
  > "$TMP_ROOT/checkpoint.out" 2> "$TMP_ROOT/checkpoint.err" || fail "watcher checkpoint did not wake: $(cat "$TMP_ROOT/checkpoint.out" "$TMP_ROOT/checkpoint.err")"
assert_contains "$(cat "$TMP_ROOT/checkpoint.out")" 'check:' 'watcher did not surface the pool footprint check'
assert_contains "$(cat "$TMP_ROOT/checkpoint.out")" "$TMP_ROOT/pool/fat-a/rust" 'watcher wake omits the largest copy'
# Drain and acknowledge that wake as a handling turn would, so the next
# checkpoint has no queued wake to resurface and can only wake on a repeat.
drained=$(FM_HOME="$FM_HOME" "$ROOT/bin/fm-wake-drain.sh" 2> "$TMP_ROOT/drain.err")
assert_contains "$drained" "$TMP_ROOT/pool/fat-a/rust" 'queued wake omits the largest copy'
sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$TMP_ROOT/drain.err")
generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$TMP_ROOT/drain.err")
FM_HOME="$FM_HOME" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" > /dev/null
rc=0
FM_HOME="$FM_HOME" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 3 \
  > "$TMP_ROOT/checkpoint2.out" 2> "$TMP_ROOT/checkpoint2.err" || rc=$?
[ "$rc" -eq 124 ] || fail "watcher repeated the pool footprint wake: $(cat "$TMP_ROOT/checkpoint2.out")"
pass 'watcher surfaces the registered pool footprint check exactly once'

# A changed total is a new wake; dropping under budget clears the record so a
# later crossing surfaces again.
head -c 65536 /dev/zero | tr '\0' x > "$TMP_ROOT/pool/thin/rust/.oracle-work/more.bin"
scheduled_sweep 0.0001
second=$(check_output)
[ -n "$second" ] || fail 'a changed over-budget total did not produce a new wake'
[ "$second" != "$first" ] || fail 'changed total repeated the earlier wake line'
scheduled_sweep 1000
[ -z "$(check_output)" ] || fail 'an under-budget pool still woke firstmate'
scheduled_sweep 0.0001
[ -n "$(check_output)" ] || fail 'a pool crossing the budget again did not wake firstmate'
pass 'pool budget wake follows the total: new total, silence under budget, wake on re-crossing'

for name in fat-a fat-b fat-c thin; do
  case "$name" in
    fat-a) size=1048576 ;;
    fat-b) size=262144 ;;
    fat-c) size=131072 ;;
    thin) size=1024 ;;
  esac
  rm -f "$TMP_ROOT/pool/$name/rust/.oracle-work/more.bin"
  head -c "$size" /dev/zero > "$TMP_ROOT/pool/$name/rust/.oracle-work/blob.bin"
done
scheduled_sweep 0.0001
before=$(check_output)
head -c 4096 /dev/zero >> "$TMP_ROOT/pool/thin/rust/.oracle-work/blob.bin"
scheduled_sweep 0.0001
after=$(check_output)
[ -n "$after" ] || fail 'exact byte increase hidden by rounding did not wake'
[ "$before" = "$after" ] || fail 'fixture failed to keep the rounded display unchanged'
[ -z "$(check_output)" ] || fail 'exact total woke twice'
mv "$TMP_ROOT/pool/fat-a/rust/.oracle-work/blob.bin" "$TMP_ROOT/swapped-blob"
mv "$TMP_ROOT/pool/fat-b/rust/.oracle-work/blob.bin" "$TMP_ROOT/pool/fat-a/rust/.oracle-work/blob.bin"
mv "$TMP_ROOT/swapped-blob" "$TMP_ROOT/pool/fat-b/rust/.oracle-work/blob.bin"
scheduled_sweep 0.0001
[ -z "$(check_output)" ] || fail 'redistributing an unchanged total repeated the wake'
[ "$(head -n 1 "$FM_HOME/state/pool-footprint.over-budget")" != "$after" ] || fail 'fixture failed to change the top-copy display'
pass 'wake identity uses exact bytes independently of rounding and top-copy distribution'

ln -s "$PROJECT" "$TMP_ROOT/project-alias"
for name in thin fat-c fat-b fat-a; do
  printf '%s\t%s\n' "$TMP_ROOT/project-alias" "$TMP_ROOT/pool/$name/rust"
done | FM_POOL_TOTAL_BUDGET_GB=0.0001 "$ROOT/bin/fm-pool-footprint.sh" --pool-audit > "$TMP_ROOT/alias-audit.out"
[ -z "$(check_output)" ] || fail 'canonical project alias or inventory order repeated the wake'
pass 'canonical project identity survives aliases and inventory reordering'

# The self-project fallback uses the same code root override as spawn/teardown.
# Audit its actual pool even when this home has no projects/<self> clone.
cp "$FM_HOME/data/projects.md" "$TMP_ROOT/projects.saved"
printf '%s\n' '- absent - fixture' '- rust - self fixture' > "$FM_HOME/data/projects.md"
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_ROOT_OVERRIDE="$PROJECT" FM_PROJECTS_OVERRIDE="$TMP_ROOT/no-clones" \
  FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/self-audit.out" 2>&1 \
  || fail "self-project audit failed: $(cat "$TMP_ROOT/self-audit.out")"
assert_contains "$(cat "$TMP_ROOT/self-audit.out")" 'skipped=no-clone' 'missing clone was not skipped'
assert_contains "$(cat "$FM_HOME/state/pool-footprint.over-budget")" "$PROJECT" 'self-project pool was not audited'
assert_contains "$(cat "$FM_HOME/state/pool-footprint.over-budget")" "$TMP_ROOT/pool/fat-a/rust" 'self-project copy was omitted'
assert_not_contains "$(cat "$FM_HOME/state/pool-footprint.over-budget")" 'inventory-unavailable' 'missing clone created a false wake'
mv "$TMP_ROOT/projects.saved" "$FM_HOME/data/projects.md"
pass 'scheduled audit measures the self-project pool and excludes absent clones'

index=$(git -C "$TMP_ROOT/pool/thin/rust" rev-parse --git-path index)
printf 'broken index\n' > "$index"
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/broken-sweep.out" 2>&1 || true
broken=$(check_output)
assert_contains "$broken" 'could not measure' 'audit silently accepted a failed ignored listing'
assert_contains "$broken" "$TMP_ROOT/pool/thin/rust" 'audit did not name the unmeasurable copy'
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/broken-sweep.out" 2>&1 || true
[ -z "$(check_output)" ] || fail 'unchanged measurement failure repeated the wake'
pass 'scheduled audit surfaces failed ignored listings exactly once'

node - "$TEST_INVENTORY" <<'JS'
const fs=require('fs'), file=process.argv[2], rows=JSON.parse(fs.readFileSync(file));
rows.sort((a,b)=>Number(b.name==='thin')-Number(a.name==='thin'));
fs.writeFileSync(file,JSON.stringify(rows));
JS
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/first-broken.out" 2>&1 || true
[ -z "$(check_output)" ] || fail 'a corrupt first copy changed the audit of later copies'
head -c 65536 /dev/zero >> "$TMP_ROOT/pool/fat-a/rust/.oracle-work/blob.bin"
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/first-broken.out" 2>&1 || true
growth=$(check_output)
assert_contains "$growth" "$TMP_ROOT/pool/fat-a/rust" 'growth after a corrupt first copy was omitted'
assert_contains "$growth" 'could not measure' 'corrupt first copy lost its failure state'
[ -z "$(check_output)" ] || fail 'growth behind a corrupt first copy woke twice'
pass 'a corrupt first copy does not hide later copies or their growth'

mkdir -p "$FM_HOME/projects/other"
printf '%s\n' '- other [no-mistakes] - fixture' >> "$FM_HOME/data/projects.md"
export TEST_CAPTURE_LOG="$TMP_ROOT/capture-order.log"
export TEST_REAL_GIT
TEST_REAL_GIT=$(command -v git)
cat > "$TMP_ROOT/fakebin/git" <<'EOF'
#!/usr/bin/env bash
printf 'copy:%s\n' "$*" >> "$TEST_CAPTURE_LOG"
exec "$TEST_REAL_GIT" "$@"
EOF
cat > "$TMP_ROOT/fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
[ "$*" = 'status --json' ] || exit 1
printf 'inventory:%s\n' "$PWD" >> "$TEST_CAPTURE_LOG"
if [ -f "$PWD/inventory-unavailable" ]; then
  printf 'not-json\n'
elif [ "${PWD##*/}" = other ]; then
  printf '[]\n'
else
  cat "$TEST_INVENTORY"
fi
EOF
chmod +x "$TMP_ROOT/fakebin/git" "$TMP_ROOT/fakebin/treehouse"
: > "$TEST_CAPTURE_LOG"
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/capture-order.out" 2>&1 || true
expected=$(printf 'inventory:%s\ninventory:%s' "$PROJECT" "$FM_HOME/projects/other")
[ "$(head -n 2 "$TEST_CAPTURE_LOG")" = "$expected" ] || fail 'cleanup started before every project inventory was captured'
[ -z "$(check_output)" ] || fail 'an empty additional pool repeated an unchanged wake'
pass 'every registered project inventory is captured before cleanup starts'

touch "$FM_HOME/projects/other/inventory-unavailable"
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/unavailable.out" 2>&1 || true
unavailable=$(check_output)
assert_contains "$unavailable" 'could not read inventory' 'unreadable project inventory was silently omitted'
assert_contains "$unavailable" "$FM_HOME/projects/other" 'inventory failure omitted its project identity'
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/unavailable.out" 2>&1 || true
[ -z "$(check_output)" ] || fail 'unchanged unavailable inventory woke twice'
rm "$FM_HOME/projects/other/inventory-unavailable"
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/recovered.out" 2>&1 || true
recovered=$(check_output)
assert_not_contains "$recovered" 'could not read inventory' 'recovered inventory kept its failure state'
pass 'inventory failure is durable, deduplicated, and cleared after recovery'
rm "$TMP_ROOT/fakebin/git"

record="$FM_HOME/state/pool-footprint.over-budget"
cp "$record" "$TMP_ROOT/snapshot-old"
old_line=$(head -n 1 "$record")
head -c 65536 /dev/zero >> "$TMP_ROOT/pool/fat-a/rust/.oracle-work/blob.bin"
rm -f "$FM_HOME/state/.pool-build-sweep.last"
FM_POOL_TOTAL_BUDGET_GB=0.0001 "$SWEEP" --scheduled > "$TMP_ROOT/snapshot-next.out" 2>&1 || true
new_line=$(head -n 1 "$record")
[ "$old_line" != "$new_line" ] || fail 'snapshot fixture did not change the display'
mv "$record" "$TMP_ROOT/snapshot-next"
mv "$TMP_ROOT/snapshot-old" "$record"
rm "$FM_HOME/state/.pool-footprint-surfaced"
mkdir "$TMP_ROOT/snapshot-bin"
export TEST_SNAPSHOT_RECORD="$record" TEST_SNAPSHOT_NEXT="$TMP_ROOT/snapshot-next"
export TEST_SNAPSHOT_REPLACED="$TMP_ROOT/snapshot-replaced"
export TEST_REAL_CAT TEST_REAL_SED TEST_REAL_HEAD
TEST_REAL_CAT=$(command -v cat)
TEST_REAL_SED=$(command -v sed)
TEST_REAL_HEAD=$(command -v head)
for tool in cat sed head; do
  cat > "$TMP_ROOT/snapshot-bin/$tool" <<'EOF'
#!/usr/bin/env bash
case "${0##*/}" in
  cat) real=$TEST_REAL_CAT ;;
  sed) real=$TEST_REAL_SED ;;
  head) real=$TEST_REAL_HEAD ;;
esac
output=$("$real" "$@") || exit $?
for arg in "$@"; do
  if [ "$arg" = "$TEST_SNAPSHOT_RECORD" ] && [ -f "$TEST_SNAPSHOT_NEXT" ]; then
    mv "$TEST_SNAPSHOT_NEXT" "$TEST_SNAPSHOT_RECORD"
    touch "$TEST_SNAPSHOT_REPLACED"
    break
  fi
done
printf '%s\n' "$output"
EOF
  chmod +x "$TMP_ROOT/snapshot-bin/$tool"
done
snapshot_first=$(PATH="$TMP_ROOT/snapshot-bin:$PATH" bash "$CHECK")
assert_present "$TEST_SNAPSHOT_REPLACED" 'record replacement was not exercised during check execution'
[ "$snapshot_first" = "$old_line" ] || fail 'check mixed old dedupe keys with a new display'
[ "$(check_output)" = "$new_line" ] || fail 'new snapshot did not produce exactly its own wake'
[ -z "$(check_output)" ] || fail 'record replacement repeated the new total'
pass 'atomic record replacement cannot mix snapshot keys and display'

quoted_home="$TMP_ROOT/home's \$cache"
mkdir -p "$quoted_home/state"
printf '%s\t%s\n' "$PROJECT" "$TMP_ROOT/pool/fat-a/rust" | \
  FM_HOME="$quoted_home" FM_POOL_TOTAL_BUDGET_GB=0.0001 "$ROOT/bin/fm-pool-footprint.sh" --pool-audit > "$TMP_ROOT/quoted-audit.out"
assert_present "$quoted_home/state/pool-footprint.check-trust" 'quoted-home check was not registered'
quoted_wake=$(bash "$quoted_home/state/pool-footprint.check.sh") || fail 'quoted-home check failed to execute'
assert_contains "$quoted_wake" "$TMP_ROOT/pool/fat-a/rust" 'quoted-home check lost its budget alert'
[ -z "$(bash "$quoted_home/state/pool-footprint.check.sh")" ] || fail 'quoted-home check repeated its wake'
pass 'generated check safely handles apostrophes, spaces, and dollar signs in home paths'
