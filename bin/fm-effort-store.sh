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
#   fm-effort-store.sh report [<task-id>] [--db <path>]
#   fm-effort-store.sh fingerprint [--db <path>]
#   fm-effort-store.sh annotate <task-id> [annotation options]
#   fm-effort-store.sh capture <task-id> --outcome <outcome>
#   fm-effort-store.sh path [--db <path>]
#   fm-effort-store.sh --help
#
# Annotation options (every one is optional and recorded exactly as given):
#   --failure-mode loudly|quietly   would a defect here be caught, or only felt
#   --round <n>:<discovery|churn>[:<note>]   repeatable, one per extra round
#   --findings <n> --review-rounds <n> --ask-user <n> --gate-failures <n>
#   --title <text> --branch <name> --pr-url <url> --backend <name>
#   --commit <sha>                  repeatable; the task-to-commit link
#   --reverted yes|no
#
# `capture` is the lifecycle-owned append-and-rebuild path. It reads stamped
# task metadata and the durable usage snapshot. Operators normally use `report`.
#
# Environment:
#   FM_HOME                              selects the home whose data/ is used
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENGINE="$SCRIPT_DIR/fm-effort-store.mjs"

usage() {
  sed -n '2,45s/^# \{0,1\}//p' "$0"
}

die() {
  echo "fm-effort-store: $1" >&2
  exit 1
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help|help|'') usage; exit 0 ;;
  rebuild|report|fingerprint|annotate|capture|path) shift ;;
  *) usage >&2; exit 2 ;;
esac

command -v node >/dev/null 2>&1 || die "node not found"
[ -f "$ENGINE" ] || die "ingestion engine missing at $ENGINE"

DB="$DATA/effort-store.sqlite"
IMPORT_GRAPH=true
TASK_ID=
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
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
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK" || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$STATE"
fm_lock_acquire_wait "$LOCK" || die "could not acquire the effort-store lock"
LOCK_HELD=1

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
const [out, dbPath, rawFile, annotationsFile, dataDir, stateDir, importGraph, taskId] = process.argv.slice(1)
fs.writeFileSync(out, JSON.stringify({
  dbPath,
  rawFile,
  annotationsFile,
  dataDir,
  stateDir,
  importGraph: importGraph === "true",
  taskId: taskId || null,
}))
' "$CONFIG" "$DB" "$DATA/cost-attribution.tsv" "$DATA/effort-annotations.jsonl" \
  "$DATA" "$STATE" "$IMPORT_GRAPH" "$TASK_ID" || die "could not stage the ingestion config"

node "$ENGINE" "$COMMAND" "$CONFIG" "$ARGV"
