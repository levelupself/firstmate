#!/usr/bin/env bash
# Prune idle build output in this home's Treehouse pools.
# Usage: fm-pool-prune.sh [--dry-run] [<project-name>...]
# With no names, inspect FM_HOME itself and directories under FM_HOME/projects.
# Names select that home repository's basename or a direct projects child.
# FM_HOME defaults to the code root; FM_STATE_OVERRIDE selects task records.
# Treehouse status --json is authoritative for pool discovery and live use.
# Only available, process-free, unleased copies of the selected Git repository
# qualify. Every state/*.meta worktree reference excludes its copy, irrespective
# of task status. Unknown inventories stop the sweep; no whole-home pool scan.
# POSIX flock on Treehouse's existing treehouse-state.lock serializes deletion
# against acquisition. Re-read persistent lease/owner state and task references
# under that lock. Missing flock or an unrecognized pool layout stops safely.
# Treehouse status itself may reconcile its inventory even during --dry-run;
# dry-run performs no build-output deletion. The build rules and safety boundary
# are owned by fm-build-output-lib.sh. No task spawn or slot selection changes.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-build-output-lib.sh
. "$SCRIPT_DIR/fm-build-output-lib.sh"
MODE=delete
PROJECTS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE=dry-run ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    -*|*/*|.|..) echo "error: invalid project name: $arg" >&2; exit 2 ;;
    *)
      if [ "$arg" = "$(basename "$FM_HOME")" ]; then PROJECTS+=("$FM_HOME")
      else PROJECTS+=("$FM_HOME/projects/$arg"); fi
      ;;
  esac
done
if [ "${#PROJECTS[@]}" -eq 0 ]; then
  git -C "$FM_HOME" rev-parse --git-dir >/dev/null 2>&1 && PROJECTS+=("$FM_HOME")
  for project in "$FM_HOME/projects/"*; do
    [ ! -d "$project" ] || PROJECTS+=("$project")
  done
fi
for project in "${PROJECTS[@]}"; do
  [ -d "$project" ] || { echo "error: no project at $project" >&2; exit 1; }
  inventory=$(cd "$project" && treehouse status --json) || exit 1
  candidates=$(FM_POOL_INVENTORY="$inventory" node - <<'JS'
const entries = JSON.parse(process.env.FM_POOL_INVENTORY);
if (!Array.isArray(entries)) throw Error('unreadable Treehouse inventory');
const paths = new Set();
for (const e of entries) {
  if (!e || typeof e.path !== 'string' || !e.path.startsWith('/') || /[\r\n]/.test(e.path) || paths.has(e.path) || typeof e.lease_id !== 'string' || !Array.isArray(e.processes)) throw Error('invalid Treehouse entry');
  paths.add(e.path);
  if (e.status === 'available' && e.lease_id === '' && e.processes.length === 0) console.log(e.path);
}
JS
  ) || exit 1
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    # Pool layout is <pool>/<slot>/<repository>. Never create a guessed lock.
    pool=$(dirname "$(dirname "$wt")")
    [ -f "$pool/treehouse-state.lock" ] && [ ! -L "$pool/treehouse-state.lock" ] || {
      echo "error: unrecognized Treehouse pool lock: $pool" >&2; exit 1;
    }
    (
      flock -x 9 || exit 1
      node - "$pool/treehouse-state.json" "$STATE" "$wt" "$project" <<'JS'
const fs = require('fs'), cp = require('child_process');
const [stateFile, taskState, wt, project] = process.argv.slice(2);
const real = p => fs.realpathSync(p);
const common = p => real(cp.execFileSync('git', ['-C', p, 'rev-parse', '--path-format=absolute', '--git-common-dir'], {encoding:'utf8'}).trim());
if (real(wt) !== wt || real(project) === wt || common(wt) !== common(project)) process.exit(3);
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
if (!Array.isArray(state.worktrees)) throw Error('unreadable pool state');
const entries = state.worktrees.filter(e => e.path === wt);
if (entries.length !== 1) throw Error('ambiguous pool entry');
const e = entries[0];
if (e.leased || e.lease_id || e.destroying || e.owner_pid) process.exit(3);
if (fs.existsSync(taskState)) for (const name of fs.readdirSync(taskState)) {
  if (!name.endsWith('.meta')) continue;
  for (const line of fs.readFileSync(`${taskState}/${name}`, 'utf8').split('\n')) {
    if (!line.startsWith('worktree=')) continue;
    const p = line.slice(9);
    if (!p) continue;
    // Resolve aliases when they exist; preserve exact references even if absent.
    if (p === wt || (fs.existsSync(p) && real(p) === wt)) process.exit(3);
  }
}
JS
      rc=$?
      [ "$rc" -ne 3 ] || exit 0
      [ "$rc" -eq 0 ] || exit "$rc"
      fm_prune_build_output "$wt" "$MODE"
    ) 9<"$pool/treehouse-state.lock" || {
      rc=$?
      [ "$rc" -eq 3 ] || exit "$rc"
    }
  done <<< "$candidates"
done
