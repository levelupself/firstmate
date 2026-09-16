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
"$SWEEP" --dry-run > "$TMP_ROOT/dry" || fail 'build sweep executable must support dry-run'
assert_present "$TMP_ROOT/pool/age/rust/target/debug/deps/libdemo-1111111111111111.rlib" 'dry-run deleted old output'
"$SWEEP" > "$TMP_ROOT/age"
assert_absent "$TMP_ROOT/pool/age/rust/target/debug/deps/libdemo-1111111111111111.rlib" 'old generation retained'
assert_absent "$TMP_ROOT/pool/age/rust/target/debug/deps/libdemo-2222222222222222.rlib" 'second old generation retained'
assert_present "$TMP_ROOT/pool/age/rust/target/debug/deps/libdemo-3333333333333333.rlib" 'newest generation deleted'
assert_present "$TMP_ROOT/pool/busy/rust/target/debug/deps/libdemo-1111111111111111.rlib" 'live cargo output deleted'
assert_contains "$(cat "$TMP_ROOT/age")" 'live-cargo' 'skip reason missing'
assert_absent "$TMP_ROOT/pool/plain/rust/target" 'non-Rust copy changed'
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
