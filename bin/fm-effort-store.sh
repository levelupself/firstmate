#!/usr/bin/env bash
# Build and maintain the derived agentic-effort store.
#
# The store is the reference class for agentic engineering work: one SQLite file
# under this home's gitignored data/, joining the append-only lifecycle capture
# (data/cost-attribution.tsv), durable task-usage snapshots, and the project's
# own git history. It is derived, so it is safe to delete; `rebuild` recreates
# it exactly.
#
# Two fields cannot be derived from any artifact and are recorded by hand
# instead: why a task needed another round (discovery, meaning the work revealed
# more, versus churn, meaning the requirements moved) and whether the code would
# have failed loudly or quietly. Those live in the append-only
# data/effort-annotations.jsonl, which is an ingestion input rather than store
# content, so they survive the store's own delete-and-rebuild contract. Records
# are keyed by task, so any later source that can name a task contributes with
# no schema change.
#
# bin/fm-effort-store.mjs owns the schema, the join, and the missing-source
# contract; read its header before changing ingestion behavior.
#
# Usage:
#   fm-effort-store.sh rebuild [--db <path>] [--no-import-graph]
#   fm-effort-store.sh backfill-codeburn [--replace-existing] <export.json>
#   fm-effort-store.sh report [<task-id>] [--sync] [--db <path>]
#   fm-effort-store.sh fingerprint [--db <path>]
#   fm-effort-store.sh annotate <task-id> [annotation options]
#   fm-effort-store.sh capture <task-id> --outcome <outcome>
#   fm-effort-store.sh enqueue [--db <path>] [--no-import-graph]
#   fm-effort-store.sh path [--db <path>]
#   fm-effort-store.sh --help
#
# Annotation options (every one is optional and recorded exactly as given):
#   --failure-mode loudly|quietly   would a defect here be caught, or only felt
#   --round <n>:<discovery|churn>[:<note>]   repeatable, one per extra round
#   --title <text> --branch <name> --pr-url <url> --backend <name>
#   --commit <sha>                  repeatable; the task-to-commit link
#   --reverted yes|no
#
# `capture` is the lifecycle-owned synchronous append-and-enqueue path. It reads stamped
# task metadata, a prior raw row when volatile metadata is gone, the durable
# usage snapshot, and matching settled no-mistakes rounds. Operators normally
# use `report`; only `report --sync` waits for deferred ingestion.
# Capture never acquires the derived-store lock. Usage snapshots are persisted
# by fm-task-usage before its capture call and survive volatile metadata removal.
# Enqueue starts a detached job with one runner per database, coalescing pending
# requests after acquiring the store lock. Failed work remains queued; the next
# enqueue or report --sync retries it. No separately started daemon is required.
# state/.effort-queue-<db hash>/ holds requests; .runner.lock guards its worker.
# state/effort-git-cache/ holds disposable commit-keyed inventories and walks.
# rebuild refreshes this cache; ordinary deferred ingestion reuses it.
# The worker log is state/.effort-queue-<db hash>/worker.log.
#
# Environment:
#   FM_HOME                              selects the home whose data/ is used
#   FM_NO_MISTAKES_STATE_DB_OVERRIDE     test/runtime override for pipeline data
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENGINE="$SCRIPT_DIR/fm-effort-store.mjs"

usage() {
  sed -n '2,/^set -u/{ /^#/s/^# \{0,1\}//p; }' "$0"
}

die() {
  echo "fm-effort-store: $1" >&2
  exit 1
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help|help|'') usage; exit 0 ;;
  rebuild|backfill-codeburn|report|fingerprint|annotate|capture|path|enqueue|worker) shift ;;
  *) usage >&2; exit 2 ;;
esac

command -v node >/dev/null 2>&1 || die "node not found"
[ -f "$ENGINE" ] || die "ingestion engine missing at $ENGINE"

DB="$DATA/effort-store.sqlite"
IMPORT_GRAPH=true
TASK_ID=
SYNC=false
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --sync)
      [ "$COMMAND" = report ] || die "--sync is only supported by report"
      SYNC=true
      shift
      ;;
    --db)
      [ $# -ge 2 ] || die "--db needs a path"
      DB=$2
      shift 2
      ;;
    --no-import-graph)
      IMPORT_GRAPH=false
      shift
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done
      ;;
    -*)
      ARGS+=("$1")
      shift
      ;;
    *)
      if { [ "$COMMAND" = annotate ] || [ "$COMMAND" = capture ] || [ "$COMMAND" = report ]; } \
        && [ -z "$TASK_ID" ]; then
        TASK_ID=$1
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [ "$COMMAND" = path ]; then
  printf '%s\n' "$DB"
  exit 0
fi
if { [ "$COMMAND" = annotate ] || [ "$COMMAND" = capture ]; } && [ -z "$TASK_ID" ]; then
  die "$COMMAND needs a task id"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-effort-store.XXXXXX") || die "could not create a work directory"
LOCK="$STATE/.effort-store.lock"
LOCK_HELD=0
RUNNER_HELD=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK" || true
  [ "$RUNNER_HELD" = 0 ] || fm_lock_release "$RUNNER_LOCK" || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$STATE"

# The config is written by node so no shell quoting can corrupt a path, and the
# annotation arguments travel NUL-separated so a note may contain anything.
CONFIG="$WORK/config.json"
ARGV="$WORK/argv"
if [ "${#ARGS[@]}" -gt 0 ]; then
  printf '%s\0' "${ARGS[@]}" > "$ARGV"
else
  : > "$ARGV"
fi

node -e '
const fs = require("fs")
const path = require("path")
const [out, dbPath, rawFile, annotationsFile, dataDir, stateDir, importGraph, taskId] = process.argv.slice(1)
const pipelineDbPath = process.env.FM_NO_MISTAKES_STATE_DB_OVERRIDE
  || (process.env.HOME ? path.join(process.env.HOME, ".no-mistakes", "state.sqlite") : null)
fs.writeFileSync(out, JSON.stringify({
  dbPath,
  rawFile,
  annotationsFile,
  dataDir,
  stateDir,
  importGraph: importGraph === "true",
  taskId: taskId || null,
  pipelineDbPath,
}))
' "$CONFIG" "$DB" "$DATA/cost-attribution.tsv" "$DATA/effort-annotations.jsonl" \
  "$DATA" "$STATE" "$IMPORT_GRAPH" "$TASK_ID" || die "could not stage the ingestion config"

QUEUE_KEY=$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("path").resolve(process.argv[1])).digest("hex"))' "$DB") || die "could not identify queue"
QUEUE="$STATE/.effort-queue-$QUEUE_KEY"
RUNNER_LOCK="$QUEUE/.runner.lock"

queue_request() {
  mkdir -p "$QUEUE" || return 1
  mktemp "$QUEUE/request.XXXXXXXX" >/dev/null
}

start_worker() {
  # Detach with all descriptors closed so command substitutions and lifecycle
  # tools return immediately. The worker acquires its own process-owned lock.
  node -e '
    const {spawn} = require("child_process")
    const child = spawn(process.argv[1], process.argv.slice(2), {detached:true, stdio:"ignore"})
    child.on("error", error => { process.stderr.write(error.message + "\n"); process.exitCode = 1 })
    child.unref()
  ' "$SCRIPT_DIR/fm-effort-store.sh" worker --db "$DB" "${GRAPH_ARGS[@]}"
}

GRAPH_ARGS=()
[ "$IMPORT_GRAPH" = true ] || GRAPH_ARGS+=(--no-import-graph)

run_queue() {
  mkdir -p "$QUEUE" || return 1
  if [ "$SYNC" = true ]; then
    fm_lock_acquire_wait "$RUNNER_LOCK" || return 1
  else
    fm_lock_try_acquire "$RUNNER_LOCK" || return 0
  fi
  RUNNER_HELD=1
  if [ "$SYNC" = true ]; then
    # Recheck publication after the preceding worker exits, avoiding a redundant
    # rebuild when it published between the initial report and lock acquisition.
    if ! node "$ENGINE" current "$CONFIG" "$ARGV"; then
      shopt -s nullglob
      local pending=("$QUEUE"/request.*)
      [ "${#pending[@]}" -gt 0 ] || queue_request || return 1
    fi
  fi
  while :; do
    local requests=()
    shopt -s nullglob
    requests=("$QUEUE"/request.*)
    if [ "${#requests[@]}" -gt 0 ]; then
      fm_lock_acquire_wait "$LOCK" || return 1
      LOCK_HELD=1
      # Include every request queued during the wait, but leave requests that
      # arrive during ingestion for the next pass. Failure preserves the batch.
      requests=("$QUEUE"/request.*)
      if ! node "$ENGINE" ingest "$CONFIG" "$ARGV"; then
        return 1
      fi
      rm -f -- "${requests[@]}"
      fm_lock_release "$LOCK"
      LOCK_HELD=0
      continue
    fi
    fm_lock_release "$RUNNER_LOCK"
    RUNNER_HELD=0
    # Close the exit/enqueue race: a submitter either starts a new runner after
    # release, or its request is observed here and this runner reacquires.
    requests=("$QUEUE"/request.*)
    [ "${#requests[@]}" -gt 0 ] || return 0
    fm_lock_try_acquire "$RUNNER_LOCK" || return 0
    RUNNER_HELD=1
  done
}

case "$COMMAND" in
  capture)
    # Serialize only this task's previous-row read and append, never ingestion.
    [[ "$TASK_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "capture needs a safe task id"
    CAPTURE_LOCK="$STATE/.effort-capture-$TASK_ID.lock"
    fm_lock_acquire_wait "$CAPTURE_LOCK" || die "could not lock task capture"
    node "$ENGINE" capture "$CONFIG" "$ARGV"
    result=$?
    fm_lock_release "$CAPTURE_LOCK"
    [ "$result" -eq 0 ] || exit "$result"
    queue_request || die "could not queue ingestion"
    start_worker || die "could not start ingestion worker"
    ;;
  enqueue)
    queue_request || die "could not queue ingestion"
    start_worker || die "could not start ingestion worker"
    ;;
  worker)
    mkdir -p "$QUEUE" || die "could not create queue"
    run_queue >>"$QUEUE/worker.log" 2>&1
    ;;
  report)
    if [ "$SYNC" = true ]; then
      run_queue >/dev/null || die "pending ingestion failed; see $QUEUE/worker.log"
    fi
    node "$ENGINE" report "$CONFIG" "$ARGV"
    ;;
  rebuild|backfill-codeburn)
    fm_lock_acquire_wait "$LOCK" || die "could not acquire the effort-store lock"
    LOCK_HELD=1
    node "$ENGINE" "$COMMAND" "$CONFIG" "$ARGV"
    ;;
  *) node "$ENGINE" "$COMMAND" "$CONFIG" "$ARGV" ;;
esac
