#!/usr/bin/env bash
# Advisory capacity snapshot before releasing another task; never a spawn gate.
# Usage: fm-resources.sh
# Prints one RESOURCES line: disk_free (KiB), disk_source, vm_mem_available
# (KiB; free's available column), load (1/5/15 minute), and task_worktrees.
# On WSL, query the current distro's registered VHDX BasePath through Windows
# PowerShell and report that Windows volume's free space, not the sparse VM
# filesystem's apparent capacity. If unavailable, use df -Pk / explicitly
# labelled vm-root. Missing metrics are unknown and never block the report.
# Task count is distinct existing worktree paths in this home's state/*.meta,
# excluding secondmate homes; retained task records count conservatively even
# if their worker exited. FM_HOME and FM_STATE_OVERRIDE select the home/state.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
case "${1:-}" in
  -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) echo 'usage: fm-resources.sh' >&2; exit 2 ;;
esac
disk=unknown
source=vm-root
if [[ "$(uname -r 2>/dev/null)" == *[Mm]icrosoft* ]] && [ -n "${WSL_DISTRO_NAME:-}" ] \
  && command -v powershell.exe >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  # Quote the argument as a PowerShell literal; the command body is static.
  # shellcheck disable=SC2016 # PowerShell variables, not shell expansions.
  win=$(timeout 5 powershell.exe -NoProfile -NonInteractive -Command '& { param([string]$distro)
    $items = @(Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" | Get-ItemProperty | Where-Object { $_.DistributionName -eq $distro })
    if ($items.Count -ne 1) { exit 1 }
    $base = $items[0].BasePath -replace "^\\\\\?\\", ""
    $root = [System.IO.Path]::GetPathRoot($base)
    $drive = New-Object System.IO.DriveInfo($root)
    Write-Output (([math]::Floor($drive.AvailableFreeSpace / 1024)).ToString() + " " + $drive.Name.Substring(0,1))
  }' "'${WSL_DISTRO_NAME//\'/\'\'}'" 2>/dev/null | tr -d '\r') || win=
  if [[ "$win" =~ ^([0-9]+)\ ([A-Za-z])$ ]]; then
    disk=${BASH_REMATCH[1]}
    source="windows-${BASH_REMATCH[2]}"
  fi
fi
if [ "$disk" = unknown ]; then
  disk=$(LC_ALL=C df -Pk / 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}') || disk=
  disk=${disk:-unknown}
fi
memory=$(LC_ALL=C free -k 2>/dev/null | awk '$1=="Mem:" && $7 ~ /^[0-9]+$/ {print $7}') || memory=
memory=${memory:-unknown}
load=$(LC_ALL=C uptime 2>/dev/null | sed -n 's/.*load averages\{0,1\}: *//p' | tr -d ',') || load=
load=${load:-unknown}
count=$(node - "$STATE" <<'JS'
const fs = require('fs'), dir = process.argv[2], paths = new Set();
if (fs.existsSync(dir)) for (const name of fs.readdirSync(dir)) {
  if (!name.endsWith('.meta')) continue;
  const lines = fs.readFileSync(`${dir}/${name}`, 'utf8').split('\n');
  if (lines.includes('kind=secondmate')) continue;
  for (const line of lines) if (line.startsWith('worktree=')) {
    const p = line.slice(9);
    if (p && fs.existsSync(p) && fs.statSync(p).isDirectory()) paths.add(fs.realpathSync(p));
  }
}
console.log(paths.size);
JS
) 2>/dev/null || count=unknown
printf 'RESOURCES disk_free=%sKiB disk_source=%s vm_mem_available=%sKiB load=%s task_worktrees=%s\n' \
  "$disk" "$source" "$memory" "$load" "$count"
