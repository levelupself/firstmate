#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-resources)
mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/home/state" "$TMP_ROOT/wt"
cat > "$TMP_ROOT/fakebin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 10000 2000 8000 20%% /\n'
SH
cat > "$TMP_ROOT/fakebin/free" <<'SH'
#!/usr/bin/env bash
printf ' total used free shared buff/cache available\nMem: 10000 2000 3000 0 5000 8000\n'
SH
cat > "$TMP_ROOT/fakebin/uname" <<'SH'
#!/usr/bin/env bash
echo Linux
SH
chmod +x "$TMP_ROOT/fakebin/"*
printf 'worktree=%s\nkind=ship\n' "$TMP_ROOT/wt" > "$TMP_ROOT/home/state/one.meta"
printf 'worktree=%s\nkind=ship\n' "$TMP_ROOT/wt" > "$TMP_ROOT/home/state/two.meta"
out=$(FM_HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/fakebin:$PATH" "$ROOT/bin/fm-resources.sh") || fail 'resource report failed'
[[ "$out" != *$'\n'* ]] || fail 'resource report is not one line'
for expected in 'disk_free=8000KiB' 'vm_mem_available=8000KiB' 'load=' 'task_worktrees=1'; do
  [[ "$out" == *"$expected"* ]] || fail "missing $expected: $out"
done
pass 'resource report uses df/free and counts distinct existing task copies'
cat > "$TMP_ROOT/fakebin/uname" <<'SH'
#!/usr/bin/env bash
echo '6.6.0-microsoft-standard-WSL2'
SH
cat > "$TMP_ROOT/fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
printf '123456 D\r\n'
SH
chmod +x "$TMP_ROOT/fakebin/powershell.exe"
out=$(WSL_DISTRO_NAME=Test FM_HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/fakebin:$PATH" "$ROOT/bin/fm-resources.sh")
[[ "$out" == *'disk_free=123456KiB disk_source=windows-D'* ]] || fail 'Windows capacity not preferred'
cat > "$TMP_ROOT/fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
exit 1
SH
out=$(WSL_DISTRO_NAME=Test FM_HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/fakebin:$PATH" "$ROOT/bin/fm-resources.sh")
[[ "$out" == *'disk_free=8000KiB disk_source=vm-root'* ]] || fail 'Windows query failure has no VM fallback'
pass 'WSL selects host volume capacity and labels the fallback'
