#!/usr/bin/env bash
# Shared fake pool for the spawn and teardown suites: a treehouse stub that
# models the durable per-task lease (get --lease hands out the first free,
# unleased, process-free copy and marks it leased in persistent state; a leased
# copy is never handed out again until return releases it; return honours
# --if-lease-id and --if-lease-holder exactly as treehouse 2.1.0 does, refusing
# a mismatch or an unleased copy), plus a pool-aware tmux stub whose pane enters
# a copy by name. Pool state is the inventory file `treehouse status --json`
# serves, so a test reads the pool's own view to prove what was leased or
# released, and every treehouse invocation is appended to treehouse.log.
#
# Files under <fake-dir> (FM_FAKE_DIR):
#   status.json   the pool inventory, the stub's only durable state
#                 (FM_FAKE_POOL_STATE overrides the path so two panes with
#                 separate tmux state can share one pool)
#   pool-fresh    optional "<name>\t<path>" the stub registers as a fresh copy
#                 when nothing free is left, modelling get creating one
#   treehouse.log every treehouse invocation, one per line
#   cwd           the pane's current directory (tmux stub)
#   keys, literal what the pane was sent (tmux stub)
# Knobs: FM_FAKE_STATUS_FAIL=1 makes status fail; FM_FAKE_LEASE_FAIL=1 makes
# get --lease fail; FM_FAKE_RETURN_FAIL=1 makes return fail;
# FM_FAKE_POOL_ENTER_STALL=1 leaves the pane where it is on `treehouse enter`;
# FM_FAKE_LAUNCH_FAIL=1 makes the pane refuse the agent launch literal.

# fm_fake_pool_entry <name> <path> <status> [processes-json] [lease-id] [holder]
fm_fake_pool_entry() {
  local lease=${5:-} holder=${6:-} leased_at=null
  [ -z "$lease" ] || leased_at='"2026-09-19T00:00:00Z"'
  printf '{"name":"%s","path":"%s","status":"%s","lease_id":"%s","lease_holder":"%s","leased_at":%s,"processes":%s}' \
    "$1" "$2" "$3" "$lease" "$holder" "$leased_at" "${4:-[]}"
}

# fm_fake_pool_inventory <entry>... : a JSON array of entries.
fm_fake_pool_inventory() {
  local out='' e
  for e in "$@"; do
    out="$out${out:+,}$e"
  done
  printf '[%s]\n' "$out"
}

# fm_fake_pool_field <state-file> <path> <field>: one field of the entry for
# <path> (resolved), or nothing when the pool does not list it.
fm_fake_pool_field() {
  node -e '
const fs = require("fs")
const [file, path, field] = process.argv.slice(1)
const real = p => { try { return fs.realpathSync(p) } catch { return p } }
const entries = JSON.parse(fs.readFileSync(file, "utf8"))
const e = entries.find(x => real(x.path) === real(path))
if (e && e[field] !== undefined && e[field] !== null) process.stdout.write(String(e[field]))
' "$1" "$2" "$3"
}

# fm_fake_pool_forget_processes <state-file>: the pool forgot every process
# (the workers exited, or the host rebooted): an unleased copy reads available
# again, while a leased copy keeps its lease with nothing running inside.
fm_fake_pool_forget_processes() {
  node -e '
const fs = require("fs")
const file = process.argv[1]
const entries = JSON.parse(fs.readFileSync(file, "utf8"))
for (const e of entries) {
  e.processes = []
  if (e.lease_id === "") e.status = "available"
}
fs.writeFileSync(file, JSON.stringify(entries) + "\n")
' "$1"
}

# fm_fake_pool_write_treehouse <fakebin>
fm_fake_pool_write_treehouse() {
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
STATE=${FM_FAKE_POOL_STATE:-$D/status.json}
printf '%s\n' "$*" >> "$D/treehouse.log"
LOCK="$STATE.lock"
lock() {
  local i=0
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 400 ] || { echo "fake treehouse: pool lock stuck" >&2; exit 97; }
    sleep 0.05
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}
refresh_copy() {  # <path>
  git -C "$1" reset -q --hard || exit 1
  if git -C "$1" remote get-url origin >/dev/null 2>&1; then
    git -C "$1" checkout -q --detach refs/remotes/origin/main || exit 1
  else
    git -C "$1" checkout -q --detach main || exit 1
  fi
}
pool() {  # <op> <args...> : JSON state transitions, printed as tab-separated fields
  node - "$STATE" "$D/pool-fresh" "$@" <<'NODE'
const fs = require('fs')
const crypto = require('crypto')
const [file, freshFile, op, ...args] = process.argv.slice(2)
const real = p => { try { return fs.realpathSync(p) } catch { return p } }
let entries
try { entries = JSON.parse(fs.readFileSync(file, 'utf8')) } catch { process.exit(1) }
const save = () => fs.writeFileSync(file, JSON.stringify(entries) + '\n')
if (op === 'lease') {
  const [holder] = args
  let e = entries.find(x => x.status === 'available' && x.lease_id === '' && x.processes.length === 0)
  if (!e) {
    let fresh = ''
    try { fresh = fs.readFileSync(freshFile, 'utf8').trim() } catch {}
    if (!fresh) { process.stderr.write('no worktree available\n'); process.exit(1) }
    const [name, path] = fresh.split('\t')
    e = {name, path, status: 'available', lease_id: '', lease_holder: '', leased_at: null, processes: []}
    entries.push(e)
    fs.unlinkSync(freshFile)
  }
  e.status = 'leased'
  e.lease_id = crypto.randomBytes(16).toString('hex')
  e.lease_holder = holder
  e.leased_at = new Date().toISOString()
  save()
  process.stdout.write([e.path, e.lease_id, e.lease_holder, e.leased_at].join('\t') + '\n')
} else if (op === 'path-of') {
  const e = entries.find(x => x.name === args[0])
  if (!e) process.exit(1)
  process.stdout.write(e.path + '\n')
} else if (op === 'return') {
  const [path, ifLease, ifHolder] = args
  const e = entries.find(x => real(x.path) === real(path))
  if (!e) { process.stderr.write(`failed to return worktree: ${path} is not in the pool\n`); process.exit(1) }
  if ((ifLease !== '' || ifHolder !== '') && e.lease_id === '') {
    process.stderr.write(`failed to return worktree: lease precondition failed: worktree ${path} is not leased\n`); process.exit(1)
  }
  if (ifLease !== '' && e.lease_id !== ifLease) {
    process.stderr.write(`failed to return worktree: lease precondition failed: lease id does not match worktree ${path}\n`); process.exit(1)
  }
  if (ifHolder !== '' && e.lease_holder !== ifHolder) {
    process.stderr.write(`failed to return worktree: lease precondition failed: lease holder does not match worktree ${path}\n`); process.exit(1)
  }
  e.status = 'available'
  e.lease_id = ''
  e.lease_holder = ''
  e.leased_at = null
  e.processes = []
  save()
  process.stdout.write(e.path + '\n')
}
NODE
}
case "${1:-}" in
  --version) printf 'v2.1.0\n'; exit 0 ;;
  status)
    [ -z "${FM_FAKE_STATUS_FAIL:-}" ] || exit 1
    [ -f "$STATE" ] || exit 1
    cat "$STATE"
    exit 0
    ;;
  get)
    shift
    lease=0 json=0 holder=${TREEHOUSE_LEASE_HOLDER:-}
    while [ $# -gt 0 ]; do
      case "$1" in
        --help) printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>] [--json]'; exit 0 ;;
        --lease) lease=1; shift ;;
        --json) json=1; shift ;;
        --lease-holder) holder=${2:-}; shift 2 ;;
        *) echo "fake treehouse: unknown get flag $1" >&2; exit 2 ;;
      esac
    done
    [ "$lease" = 1 ] || { echo "fake treehouse: interactive get is not modelled; the pane owns it" >&2; exit 1; }
    [ -z "${FM_FAKE_LEASE_FAIL:-}" ] || exit 1
    lock
    line=$(pool lease "$holder") || exit 1
    IFS=$'\t' read -r path lease_id lease_holder leased_at <<<"$line"
    [ -n "$path" ] || exit 1
    refresh_copy "$path"
    printf '🌳 Leased worktree at %s\n' "$path" >&2
    if [ "$json" = 1 ]; then
      printf '{"path":"%s","lease_id":"%s","lease_holder":"%s","leased_at":"%s"}\n' "$path" "$lease_id" "$lease_holder" "$leased_at"
    else
      printf '%s\n' "$path"
    fi
    exit 0
    ;;
  enter)
    shift
    [ "${1:-}" = --print-path ] || { echo "fake treehouse: interactive enter is not modelled; the pane owns it" >&2; exit 1; }
    pool path-of "${2:-}"
    exit $?
    ;;
  return)
    shift
    if_lease= if_holder= path=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) shift ;;
        --if-lease-id) if_lease=${2:-}; shift 2 ;;
        --if-lease-holder) if_holder=${2:-}; shift 2 ;;
        *) path=$1; shift ;;
      esac
    done
    [ -z "${FM_FAKE_RETURN_FAIL:-}" ] || exit 1
    lock
    pool return "$path" "$if_lease" "$if_holder" >/dev/null || exit 1
    refresh_copy "$path"
    printf '🌳 Worktree returned to pool.\n'
    exit 0
    ;;
esac
echo "fake treehouse: unsupported command $*" >&2
exit 2
SH
  chmod +x "$fb/treehouse"
}

# fm_fake_pool_write_tmux <fakebin>: a tmux stub whose single pane is a fake
# pool client. `treehouse enter <name>` moves the pane into that named copy
# and changes nothing else; the legacy interactive `treehouse get` hands out
# the first free unleased copy exactly as the pre-lease pool did (marking it
# in use by the pane's process, which the pool forgets when the pane exits);
# `pwd -P > file` answers from the pane's current directory. Launch literals
# are recorded, kills are logged to killed, FM_FAKE_PANE_COMMAND names the
# pane's foreground command, and FM_FAKE_LAUNCH_FAIL=1 makes the agent launch
# fail.
fm_fake_pool_write_tmux() {
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
STATE=${FM_FAKE_POOL_STATE:-$D/status.json}
printf '%s\n' "$*" >> "$D/tmux.log"
pane_cwd() { [ ! -f "$D/cwd" ] || cat "$D/cwd"; }
case "${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ ! -f "$D/windows" ] || cat "$D/windows"
    exit 0
    ;;
  new-window)
    cwd=
    while [ $# -gt 0 ]; do
      case "$1" in
        -c) cwd=${2:-}; shift 2 ;;
        -n) printf '%s\n' "${2:-}" >> "$D/windows"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s' "$cwd" > "$D/cwd"
    printf '@41\n'
    exit 0
    ;;
  kill-window)
    printf '%s\n' "$*" >> "$D/killed"
    : > "$D/windows"
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_path*) pane_cwd; printf '\n'; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}"; exit 0 ;;
        *pane_pid*) printf '%s\n' "${FM_FAKE_PANE_PID:-2147483646}"; exit 0 ;;
      esac
    done
    printf 'firstmate\n'
    exit 0
    ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    text=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$text" >> "$D/literal"
      [ -z "${FM_FAKE_LAUNCH_FAIL:-}" ] || case "$text" in *claude*|*codex*) exit 1 ;; esac
      exit 0
    fi
    printf '%s\n' "$text" >> "$D/keys"
    case "$text" in
      'treehouse get')
        handout=$(node -e '
const fs = require("fs")
const file = process.argv[1]
const entries = JSON.parse(fs.readFileSync(file, "utf8"))
const e = entries.find(x => x.status === "available" && x.lease_id === "" && x.processes.length === 0)
if (!e) process.exit(1)
e.status = "in-use"
e.processes = [{pid: 4242, command: "bash"}]
fs.writeFileSync(file, JSON.stringify(entries) + "\n")
process.stdout.write(e.path)
' "$STATE") || exit 0
        printf '%s' "$handout" > "$D/cwd"
        git -C "$handout" reset -q --hard
        if git -C "$handout" remote get-url origin >/dev/null 2>&1; then
          git -C "$handout" checkout -q --detach refs/remotes/origin/main
        else
          git -C "$handout" checkout -q --detach main
        fi
        ;;
      'treehouse enter '*)
        [ -z "${FM_FAKE_POOL_ENTER_STALL:-}" ] || exit 0
        name=${text#treehouse enter }
        node -e '
const fs = require("fs")
const [file, name] = process.argv.slice(1)
const e = JSON.parse(fs.readFileSync(file, "utf8")).find(x => x.name === name)
if (e) process.stdout.write(e.path)
' "$STATE" "$name" > "$D/cwd"
        ;;
      'pwd -P > '*)
        ( cd "$(pane_cwd)" && eval "$text" ) || true
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}
