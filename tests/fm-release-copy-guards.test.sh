#!/usr/bin/env bash
set -eu
# shellcheck source=tests/release-copy-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/release-copy-helpers.sh"

for spec in 'kind=scout' 'mode=no-mistakes' 'backend=orca' 'endpoint_task_id=foreign'; do
  setup_case
  key=${spec%%=*}
  sed -i "s/^$key=.*/$spec/" "$meta"
  case "$key" in endpoint_task_id) reason='endpoint' ;; *) reason='release-copy requires' ;; esac
  refuses "$reason"
done
for verb in working paused needs-decision; do
  setup_case
  printf '%s: still active\n' "$verb" >> "$dir/home/state/member.status"
  refuses 'latest status must be done:'
done
for dirty in unstaged staged untracked hook-untracked hidden-untracked; do
  setup_case
  case "$dirty" in
    unstaged) echo dirty >> "$wt/change" ;;
    staged) echo dirty >> "$wt/change"; git -C "$wt" add change ;;
    untracked) echo dirty > "$wt/extra" ;;
    hidden-untracked) git -C "$wt" config status.showUntrackedFiles no; echo dirty > "$wt/extra" ;;
    hook-untracked) mkdir "$wt/.claude"; echo dirty > "$wt/.claude/extra" ;;
  esac
  refuses 'uncommitted'
done
# Inject the git public index-inspection response, without setting hidden flags.
for flag in S h; do
  setup_case
  real_git=$(command -v git)
  cat > "$dir/fakebin/git" <<EOF
#!/usr/bin/env bash
if [ "\${3:-} \${4:-}" = 'ls-files -v' ]; then printf '$flag change\n'; exit 0; fi
exec '$real_git' "\$@"
EOF
  chmod +x "$dir/fakebin/git"
  refuses 'hidden from ordinary dirty checks'
done
setup_case
git -C "$wt" checkout -q --detach
git -C "$dir/proj" branch -D fm/member >/dev/null
refuses 'shared branch'
setup_case
git -C "$wt" checkout -q --detach
git -C "$wt" commit --allow-empty -qm extra
refuses 'shared branch'
setup_case
cp "$meta" "$dir/home/state/landing.meta"
sed -i 's/endpoint_task_id=member/endpoint_task_id=landing/' "$dir/home/state/landing.meta"
refuses 'task landing'
setup_case
FM_HOME="$dir/home" "$ROOT/bin/fm-worktree-allocation.sh" acquire other "$dir/proj" "$wt" 2026-10-01T00:00:00Z >/dev/null
refuses 'holder'
setup_case
node -e 'const fs=require("fs"),p=process.argv[1],s=JSON.parse(fs.readFileSync(p));s[0].lease_id="foreign";s[0].lease_holder="other";fs.writeFileSync(p,JSON.stringify(s))' "$dir/fake/status.json"
refuses 'leased by the pool'
setup_case
printf '[]\n' > "$dir/fake/status.json"
refuses 'pool inventory'
