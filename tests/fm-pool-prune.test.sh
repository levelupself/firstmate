#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-pool-prune)
mkdir -p "$TMP_ROOT/home/projects/rust" "$TMP_ROOT/home/state" "$TMP_ROOT/fakebin" "$TMP_ROOT/pool"
PROJECT="$TMP_ROOT/home/projects/rust"
git -C "$PROJECT" init -q
printf 'target/\n' > "$PROJECT/.gitignore"
touch "$PROJECT/Cargo.toml"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm baseline
for name in idle leased referenced tracked exception; do
  mkdir -p "$TMP_ROOT/pool/$name"
  git -C "$PROJECT" worktree add -q --detach "$TMP_ROOT/pool/$name/rust"
  mkdir "$TMP_ROOT/pool/$name/rust/target"
  echo binary > "$TMP_ROOT/pool/$name/rust/target/binary"
done
git -C "$TMP_ROOT/pool/tracked/rust" add -f target/binary
printf 'target/*\n!target/binary\n' > "$TMP_ROOT/pool/exception/rust/.gitignore"
printf 'worktree=%s\n' "$TMP_ROOT/pool/referenced/rust" > "$TMP_ROOT/home/state/task.meta"
node - "$TMP_ROOT" <<'JS'
const fs = require('fs'), root = process.argv[2];
const entries = ['idle', 'leased', 'referenced', 'tracked', 'exception'].map(name => ({name, path:`${root}/pool/${name}/rust`, status:name === 'leased' ? 'leased' : 'available', lease_id:name === 'leased' ? 'lease' : '', processes:[]}));
fs.writeFileSync(`${root}/inventory.json`, JSON.stringify(entries));
fs.writeFileSync(`${root}/pool/treehouse-state.json`, JSON.stringify({worktrees:entries.map(e=>({...e, leased:e.name==='leased'}))}));
JS
touch "$TMP_ROOT/pool/treehouse-state.lock"
cat > "$TMP_ROOT/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
cat "$TEST_INVENTORY"
SH
chmod +x "$TMP_ROOT/fakebin/treehouse"
export FM_HOME="$TMP_ROOT/home" TEST_INVENTORY="$TMP_ROOT/inventory.json"
export PATH="$TMP_ROOT/fakebin:$PATH"
out=$("$ROOT/bin/fm-pool-prune.sh" --dry-run rust) || fail 'pool dry-run failed'
[[ "$out" == *"$TMP_ROOT/pool/idle/rust/target"* ]] || fail 'idle Rust copy omitted'
[[ "$out" == *KiB* ]] || fail 'size omitted'
for name in leased referenced tracked exception; do
  [[ "$out" != *"$TMP_ROOT/pool/$name/rust/target"* ]] || fail "$name copy listed for deletion"
done
[ -f "$TMP_ROOT/pool/idle/rust/target/binary" ] || fail 'dry-run deleted output'
pass 'dry-run lists only eligible idle Rust output with size'
"$ROOT/bin/fm-pool-prune.sh" rust
[ ! -e "$TMP_ROOT/pool/idle/rust/target" ] || fail 'idle output retained'
for name in leased referenced tracked exception; do
  [ -f "$TMP_ROOT/pool/$name/rust/target/binary" ] || fail "$name output deleted"
done
pass 'sweep preserves leases, task references, tracked and non-ignored files'
