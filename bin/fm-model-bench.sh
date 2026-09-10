#!/usr/bin/env bash
# fm-model-bench.sh - run one task on several models at once, in genuine
# isolation, and report which arm finished fastest and cheapest. It reports;
# the reader concludes. docs/model-bench.md owns why every step exists.
#
# Usage:
#   fm-model-bench.sh run <project-dir> --arm <harness>:<model> --arm <harness>:<model> [--arm ...]
#       (--task-file <path> | --task <text>) --feasible <statement>
#       [--env KEY=VALUE]... [--base <ref>] [--run-id <id>] [--effort <level>]
#       [--backend <name>] [--dry-run] [--no-wait] [--timeout <seconds>] [--poll <seconds>] [--settle <seconds>]
#   fm-model-bench.sh verify <run-id>
#   fm-model-bench.sh send <run-id> <text...>
#   fm-model-bench.sh report <run-id> [--json]
#
# run sets up one arm per --arm, verifies every arm, launches them through
# bin/fm-spawn.sh, watches their status files until every arm reaches a
# terminal line (or --timeout), waits up to --settle seconds (default 180) for
# each arm's session record to close the turn that wrote that line, then
# prints the comparison. The settle wait exists because a harness writes its
# turn-close record a few seconds after the status line lands; reporting
# before it lands would leave the final turn open, and an open turn
# contributes no active time. Arms are named
# a1, a2, ... in --arm order; arm task ids are <run-id>-a<n>, and each arm
# works on branch fm/<run-id>-a<n>. --arm takes <harness>:<model>, and the
# harness must be one this tool can read a session record for (codex or
# claude); anything else is refused because its running model could never be
# confirmed. The model is passed to fm-spawn verbatim.
#
# Setup, per arm (all of it also runs under --dry-run):
#   isolation   data/<run-id>/arms/a<n>/source.git is a private bare
#               repository created empty and given exactly one ref, the
#               starting branch at --base (default: the project checkout's
#               HEAD, branch name taken from the checkout, else main); the
#               arm's project clone beside it has origin=that bare repository
#               and nothing else. The pooled worktree the arm works in comes
#               from that clone, so no arm can see another arm's refs.
#   pre-trust   the clone root is written into the harness's own trust store
#               before launch (codex: [projects."<path>"] trust_level =
#               "trusted" in $CODEX_HOME/config.toml; claude: projects.<path>
#               .hasTrustDialogAccepted = true in ~/.claude.json, or
#               $CLAUDE_CONFIG_DIR/.claude.json when that is set). Both
#               harnesses key trust on the main repository root and extend it
#               to linked worktrees, verified live, which is why the clone
#               root is the key. The entry is re-read after writing.
#   environment every --env KEY=VALUE is written once to data/<run-id>/env
#               and exported into every arm's shell identically by fm-spawn
#               --env-file; the names are also listed in the brief.
#   brief       one task body (data/<run-id>/task.md) is filled into the
#               local-only ship scaffold from bin/fm-brief.sh, with the
#               no-push rule and the definition of done retargeted at the
#               arm's private origin (every anchor must match exactly once or
#               setup refuses, so scaffold drift is loud); every arm's brief
#               must be byte-identical once its own task id is replaced by
#               {ARM}, or setup refuses and names the differing arm.
#   reader      the session-record reader is exercised on the newest record
#               the harness has already written on this machine; a harness
#               with no readable record refuses, because a running model that
#               could not be confirmed after launch is worth nothing.
# --feasible is required and recorded verbatim: this tool cannot judge whether
# the task is possible, and a task that turns out to be impossible measures
# refusal, not capability.
#
# --dry-run performs every setup and verification step above, prints the exact
# fm-spawn command each arm would receive, and launches nothing. Re-running it
# with the same --run-id re-verifies the existing run directory, so a change
# made to any arm since (an extra ref in its source repository, an edited
# brief) is caught before anything launches. verify <run-id> is the same
# re-verification without the argument list.
#
# Launch: each arm is spawned as an ordinary ship task (mode local-only, yolo
# off) whose backlog row this tool adds first; firstmate's watcher, status
# protocol, and teardown apply to it exactly as to any other task. After the
# spawn the recorded worktree is checked to belong to the pre-trusted clone and
# to see only the single origin ref; a failure here stops the run loudly
# rather than continuing with an arm whose launch may have been consumed by a
# dialog.
#
# send delivers one message to every arm, identically, through
# bin/fm-send.sh, and refuses to start unless every arm is still live. There
# is deliberately no way to steer a single arm here: every delivery result is
# recorded in data/<run-id>/broadcasts.log, and a partial delivery is
# reported by report as a warning that voids the like-for-like claim.
#
# report reads, per arm: the confirmed running model, active working time, and
# consumption from the arm's OWN session record matched on its exact worktree
# path (bin/fm-model-bench-analyze.mjs owns the arithmetic), sliced at the
# completion milestone, which is the moment the terminal status line landed
# (recorded by the watch loop, else the status file's mtime when its last line
# is terminal); the completion state from the status file; and the
# independence verdict from a byte comparison of every file the arm added or
# modified against every other arm. report never waits: run after --no-wait
# before the final turn has closed, the table says how much of that turn is
# still open. The independence check runs on every
# report, even when isolation is believed sound. A void arm is printed as VOID
# in the table and again in a banner after it; its numbers are never merged
# into the comparison. An arm whose running model cannot be positively
# confirmed is printed as UNCONFIRMED with its numbers withheld. The table
# also carries each arm's branch and private source repository so the work
# itself can be inspected. data/<run-id>/report.json holds the same data.
#
# Nothing here decides which model is best, and nothing here tears an arm
# down: bin/fm-teardown.sh owns that, per arm, with its ordinary landed-work
# rules (an arm that pushed its branch to its private origin has landed).
#
# FM_MODEL_BENCH_SPAWN_BIN and FM_MODEL_BENCH_SEND_BIN override the spawn and
# send executables for tests only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ANALYZE="$SCRIPT_DIR/fm-model-bench-analyze.mjs"
SPAWN_BIN="${FM_MODEL_BENCH_SPAWN_BIN:-$SCRIPT_DIR/fm-spawn.sh}"
SEND_BIN="${FM_MODEL_BENCH_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-model-bench: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'fm-model-bench: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Portable file mtime as ISO-8601 UTC (macOS stat -f, Linux stat -c).
file_mtime_iso() {  # <path>
  local epoch
  if [ "$(uname)" = Darwin ]; then
    epoch=$(stat -f %m "$1" 2>/dev/null) || return 1
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
  else
    epoch=$(stat -c %Y "$1" 2>/dev/null) || return 1
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
  fi
}

physical_path() {  # <path>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# Portable "set mtime to this epoch": touch -t takes local time, so the epoch
# is rendered in local time on both platforms.
touch_at_epoch() {  # <path> <epoch-seconds>
  local stamp
  if [ "$(uname)" = Darwin ]; then
    stamp=$(date -r "$2" +%Y%m%d%H%M.%S) || return 1
  else
    stamp=$(date -d "@$2" +%Y%m%d%H%M.%S) || return 1
  fi
  touch -t "$stamp" "$1"
}

# key=value records: data/<run-id>/run and data/<run-id>/arms/a<n>/arm.
rec_get() {  # <file> <key>
  [ -f "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" | tail -1
}

rec_set() {  # <file> <key> <value>  (replace or append, one key per line)
  local file=$1 key=$2 value=$3 tmp
  tmp="$file.tmp.$$"
  if [ -f "$file" ]; then
    awk -F= -v k="$key" '$1 != k' "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv -f "$tmp" "$file"
}

require_tool() {  # <name> <why>
  command -v "$1" >/dev/null 2>&1 || die "$1 is required: $2"
}

# --- harness facts ----------------------------------------------------------
#
# Every harness this tool supports needs three verified facts: where its trust
# store is and what shape an entry takes, and where it writes session records.
# A harness missing any of them is refused at --arm parsing rather than
# assumed to behave like codex.

harness_supported() {  # <harness>
  case "$1" in codex|claude) return 0 ;; esac
  return 1
}

harness_sessions_root() {  # <harness>
  case "$1" in
    codex) printf '%s/sessions' "${CODEX_HOME:-$HOME/.codex}" ;;
    claude) printf '%s/projects' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
  esac
}

harness_trust_store() {  # <harness>
  case "$1" in
    codex) printf '%s/config.toml' "${CODEX_HOME:-$HOME/.codex}" ;;
    claude)
      if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        printf '%s/.claude.json' "$CLAUDE_CONFIG_DIR"
      else
        printf '%s/.claude.json' "$HOME"
      fi
      ;;
  esac
}

# pretrust_<harness> <path>: idempotently record <path> as trusted, then prove
# the entry is present by reading the store back. Both write a temp file
# beside the store and move it into place so a crash never leaves a torn
# store, and both preserve the store's mode.
pretrust_codex() {  # <path>
  local path=$1 store header tmp mode
  store=$(harness_trust_store codex)
  header="[projects.\"$path\"]"
  if [ -f "$store" ] && grep -Fxq -- "$header" "$store"; then
    :
  else
    mkdir -p "$(dirname "$store")"
    tmp="$store.fm-model-bench.$$"
    if [ -f "$store" ]; then
      cp -p -- "$store" "$tmp"
      # A table header must start on its own line, separated from the table
      # above by one blank line as codex itself writes them; a store whose last
      # line is unterminated would otherwise glue the header onto it.
      if [ -s "$tmp" ]; then
        [ "$(tail -c 1 "$tmp" | od -An -c | tr -d ' ')" = '\n' ] || printf '\n' >> "$tmp"
        [ "$(tail -c 2 "$tmp" | od -An -c | tr -d ' ')" = '\n\n' ] || printf '\n' >> "$tmp"
      fi
    else
      : > "$tmp"
    fi
    printf '%s\ntrust_level = "trusted"\n' "$header" >> "$tmp"
    mv -f -- "$tmp" "$store"
  fi
  # Read back: the header exists exactly once and the next setting line under
  # it is the trusted level. A different level already recorded for this path
  # is the captain's choice and is refused, never rewritten.
  [ "$(grep -Fxc -- "$header" "$store")" = 1 ] || die "codex trust store $store names $path more than once; refusing to guess which entry codex reads"
  mode=$(awk -v h="$header" '
    $0 == h { in_table = 1; next }
    in_table && /^[[:space:]]*\[/ { exit }
    in_table && /^[[:space:]]*trust_level[[:space:]]*=/ { print; exit }
  ' "$store")
  case "$mode" in
    *'"trusted"'*) ;;
    *) die "codex trust store $store records '$mode' for $path, not trust_level = \"trusted\"; refusing to launch into a directory codex will gate" ;;
  esac
}

pretrust_claude() {  # <path>
  local path=$1 store tmp
  store=$(harness_trust_store claude)
  [ -f "$store" ] || die "claude trust store $store does not exist; claude has never completed onboarding on this machine, so a launch would stop at a dialog"
  require_tool jq "claude's trust store is JSON"
  if [ "$(jq -r --arg p "$path" '.projects[$p].hasTrustDialogAccepted // false' "$store")" != true ]; then
    tmp="$store.fm-model-bench.$$"
    jq --arg p "$path" '.projects = (.projects // {}) | .projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' "$store" > "$tmp" \
      || { rm -f -- "$tmp"; die "could not rewrite claude trust store $store"; }
    chmod --reference="$store" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$store"
  fi
  [ "$(jq -r --arg p "$path" '.projects[$p].hasTrustDialogAccepted // false' "$store")" = true ] \
    || die "claude trust store $store does not read back hasTrustDialogAccepted for $path"
}

pretrust() {  # <harness> <path>
  case "$1" in
    codex) pretrust_codex "$2" ;;
    claude) pretrust_claude "$2" ;;
    *) die "no pre-trust shape is verified for harness $1" ;;
  esac
}

# The reader self-check: the newest record this harness has already written
# on this machine must yield a model through the same reader report will use.
# It proves the record layout and the reader agree before an arm exists.
reader_selfcheck() {  # <harness>
  local harness=$1 root newest cwd out
  root=$(harness_sessions_root "$harness")
  [ -d "$root" ] || die "$harness session records root $root does not exist; the running model could not be confirmed after launch. Run $harness once interactively on this machine first (or point CODEX_HOME / CLAUDE_CONFIG_DIR at the right home)."
  newest=$("$ANALYZE" newest-record --harness "$harness" --sessions-root "$root" 2>/dev/null || true)
  [ -n "$newest" ] || die "no $harness session record exists under $root; the running model could not be confirmed after launch. Run $harness once interactively on this machine first."
  case "$harness" in
    codex) cwd=$(head -1 "$newest" | jq -r 'select(.type == "session_meta") | .payload.cwd // empty' 2>/dev/null || true) ;;
    claude) cwd=$(jq -r 'select(.cwd != null) | .cwd' "$newest" 2>/dev/null | head -1 || true) ;;
  esac
  [ -n "$cwd" ] || die "the newest $harness record $newest carries no workspace path; the reader cannot match records on a worktree, so the running model could not be confirmed"
  out=$("$ANALYZE" session --harness "$harness" --workspace "$cwd" --record "$newest" 2>&1) \
    || die "the $harness session reader could not read $newest: $out"
  [ "$(printf '%s' "$out" | jq -r '.models | length')" -ge 1 ] \
    || die "the $harness session reader found no model in $newest; the running model could not be confirmed after launch"
}

# --- run record layout ------------------------------------------------------

RUN_ID=
RUN_DIR=
run_dir() { printf '%s/%s' "$DATA" "$RUN_ID"; }
arm_dir() { printf '%s/arms/%s' "$RUN_DIR" "$1"; }
arm_rec() { printf '%s/arm' "$(arm_dir "$1")"; }
run_rec() { printf '%s/run' "$RUN_DIR"; }

run_id_valid() {  # <id>
  fm_task_id_creation_valid "$1" || return 1
  [ "${#1}" -le 56 ]
}

list_arms() {  # prints arm names in order
  local d
  for d in "$RUN_DIR"/arms/a*/; do
    [ -f "$d/arm" ] || continue
    basename "$d"
  done | sort -t a -k 2 -n
}

# --- verification -----------------------------------------------------------

# Before launch the private source repository holds exactly the starting ref
# and the clone exactly its checkout of it. After launch the arm's own branch
# (fm/<task-id>, created in the pooled worktree and pushed to origin) is the
# only addition allowed on either side; anything else is a leak.
verify_isolation() {  # <arm>
  local arm=$1 rec bare clone branch sha remotes lsr refs expected wt own
  rec=$(arm_rec "$arm")
  bare=$(rec_get "$rec" source_git)
  clone=$(rec_get "$rec" clone)
  branch=$(rec_get "$(run_rec)" base_branch)
  sha=$(rec_get "$(run_rec)" base_sha)
  own="fm/$(rec_get "$rec" task_id)"
  [ -d "$bare" ] || die "$arm: private source repository $bare is missing"
  [ -d "$clone" ] || die "$arm: clone $clone is missing"
  remotes=$(git -C "$clone" remote) || die "$arm: could not list remotes of $clone"
  [ "$remotes" = origin ] || die "$arm: clone $clone must have exactly one remote named origin, found: ${remotes:-none}"
  [ "$(physical_path "$(git -C "$clone" remote get-url origin)")" = "$(physical_path "$bare")" ] \
    || die "$arm: origin of $clone is '$(git -C "$clone" remote get-url origin)', not the arm's private source repository $bare"
  lsr=$(git -C "$clone" ls-remote --refs origin | grep -v "	refs/heads/$own\$" || true) || die "$arm: could not list refs of $bare"
  expected=$(printf '%s\trefs/heads/%s' "$sha" "$branch")
  [ "$lsr" = "$expected" ] || die "$arm: private source repository $bare must hold exactly one ref (refs/heads/$branch at $sha) plus at most the arm's own $own; it holds:
$(git -C "$clone" ls-remote --refs origin)"
  refs=$(git -C "$clone" for-each-ref --format='%(refname)' | grep -v "^refs/\(heads\|remotes/origin\)/$own\$" | sort)
  expected=$(printf 'refs/heads/%s\nrefs/remotes/origin/HEAD\nrefs/remotes/origin/%s' "$branch" "$branch" | sort)
  [ "$refs" = "$expected" ] || die "$arm: clone $clone holds refs beyond the starting branch and the arm's own $own:
$(git -C "$clone" for-each-ref --format='%(refname)')"
  wt=$(rec_get "$rec" worktree || true)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    verify_worktree_binding "$arm" "$wt"
  fi
}

# After launch the arm's pooled worktree must belong to the pre-trusted clone
# (its git common dir lives under that clone) and must still see only the one
# origin ref.
verify_worktree_binding() {  # <arm> <worktree>
  local arm=$1 wt=$2 rec clone common lsr
  rec=$(arm_rec "$arm")
  clone=$(rec_get "$rec" clone)
  common=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || die "$arm: worktree $wt is not a git worktree"
  case "$common" in /*) ;; *) common="$wt/$common" ;; esac
  common=$(physical_path "$common") || die "$arm: could not resolve the git common dir of $wt"
  [ "$common" = "$(physical_path "$clone")/.git" ] \
    || die "$arm: worktree $wt belongs to '$common', not the pre-trusted clone $clone; its launch may have been consumed by a trust dialog"
  [ "$(git -C "$wt" remote)" = origin ] || die "$arm: worktree $wt must see exactly one remote"
  lsr=$(git -C "$wt" ls-remote --refs origin | grep -vc "refs/heads/fm/" || true)
  [ "$lsr" -le 1 ] || die "$arm: worktree $wt sees more than the starting ref on origin"
}

verify_trust() {  # <arm>
  local arm=$1 rec harness clone
  rec=$(arm_rec "$arm")
  harness=$(rec_get "$rec" harness)
  clone=$(rec_get "$rec" clone)
  pretrust "$harness" "$(physical_path "$clone")"
}

# Every arm's brief, with its own task id replaced by {ARM}, must hash the
# same. The first differing arm is named with the first differing line.
verify_briefs() {
  local arm first_arm='' first_norm='' norm id tmp_a tmp_b
  tmp_a=$(mktemp "${TMPDIR:-/tmp}/fm-model-bench-brief.XXXXXX")
  tmp_b=$(mktemp "${TMPDIR:-/tmp}/fm-model-bench-brief.XXXXXX")
  for arm in $(list_arms); do
    id=$(rec_get "$(arm_rec "$arm")" task_id)
    [ -f "$DATA/$id/brief.md" ] || { rm -f "$tmp_a" "$tmp_b"; die "$arm: brief $DATA/$id/brief.md is missing"; }
    norm=$(sed "s|$id|{ARM}|g" "$DATA/$id/brief.md")
    if [ -z "$first_arm" ]; then
      first_arm=$arm
      first_norm=$norm
      continue
    fi
    if [ "$norm" != "$first_norm" ]; then
      printf '%s\n' "$first_norm" > "$tmp_a"
      printf '%s\n' "$norm" > "$tmp_b"
      note "briefs differ between $first_arm and $arm (arm id normalised to {ARM}):"
      diff -u --label "$first_arm" --label "$arm" "$tmp_a" "$tmp_b" | head -20 >&2 || true
      rm -f "$tmp_a" "$tmp_b"
      die "refusing: every arm must receive byte-identical instructions"
    fi
  done
  rm -f "$tmp_a" "$tmp_b"
}

verify_run() {
  local arm harness seen=' '
  [ -f "$(run_rec)" ] || die "run $RUN_ID has no record at $(run_rec)"
  [ -n "$(rec_get "$(run_rec)" feasibility)" ] || die "run $RUN_ID records no feasibility statement"
  [ "$(list_arms | wc -l)" -ge 2 ] || die "run $RUN_ID has fewer than two arms"
  for arm in $(list_arms); do
    verify_isolation "$arm"
    printf 'ok: %s isolation - one remote, one ref (%s at %s)\n' "$arm" "$(rec_get "$(run_rec)" base_branch)" "$(rec_get "$(run_rec)" base_sha | cut -c1-12)"
    verify_trust "$arm"
    printf 'ok: %s pre-trusted %s for %s\n' "$arm" "$(rec_get "$(arm_rec "$arm")" clone)" "$(rec_get "$(arm_rec "$arm")" harness)"
    harness=$(rec_get "$(arm_rec "$arm")" harness)
    case "$seen" in *" $harness "*) ;; *)
      reader_selfcheck "$harness"
      printf 'ok: %s session-record reader confirmed a model on this machine\n' "$harness"
      seen="$seen$harness "
      ;;
    esac
  done
  verify_briefs
  printf 'ok: briefs are byte-identical across %s arms once the arm id is normalised\n' "$(list_arms | wc -l | tr -d ' ')"
}

# --- setup ------------------------------------------------------------------

add_backlog_row() {  # <id> <title> <repo-name>
  local id=$1 title=$2 repo=$3 backlog="$DATA/backlog.md" tmp
  mkdir -p "$DATA"
  if [ -f "$backlog" ] && "$SCRIPT_DIR/fm-backlog-tsv.sh" "$backlog" | awk -F '\t' -v id="$id" '$2 == id { found = 1 } END { exit(found ? 0 : 1) }'; then
    return 0
  fi
  if fm_tasks_axi_backend_available "$CONFIG"; then
    (cd "$FM_HOME" && tasks-axi add "$id" "$title" --kind ship --repo "$repo" --file "$backlog" >/dev/null) \
      || die "could not add backlog row for $id through tasks-axi"
    return 0
  fi
  if [ ! -f "$backlog" ]; then
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$backlog"
  fi
  tmp="$backlog.fm-model-bench.$$"
  awk -v row="- [ ] $id - $title (repo: $repo) (kind: ship)" '
    /^## Done/ && !done { print row; print ""; done = 1 }
    { print }
  ' "$backlog" > "$tmp" && mv -f "$tmp" "$backlog"
}

# Fill the local-only scaffold for one arm. Anchors are exact scaffold lines;
# each must appear exactly once so a scaffold change cannot silently produce a
# brief that still tells the arm never to push.
write_arm_brief() {  # <arm>
  local arm=$1 rec id brief task env_names anchor replacement
  rec=$(arm_rec "$arm")
  id=$(rec_get "$rec" task_id)
  brief="$DATA/$id/brief.md"
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-brief.sh" "$id" "$(rec_get "$(run_rec)" project_name)" --mode local-only >/dev/null \
    || die "$arm: bin/fm-brief.sh could not scaffold $brief"
  env_names=$(awk -F= 'NF { printf "%s%s", (n++ ? ", " : ""), $1 }' "$RUN_DIR/env")
  task=$(cat "$RUN_DIR/task.md")
  task="$task

# Model gut-check arm
This task is one arm of a like-for-like comparison. Every arm receives these exact instructions, works alone in its own copy, and is measured from its own session record; nothing is asked of you beyond the task itself and the status protocol below.
Your only remote, \`origin\`, is a private source repository that holds nothing but the starting branch; there are no other branches to fetch and no other arm to look at.
Do not report token counts, timings, or model names anywhere: they are measured from your session record, not from you."
  if [ -n "$env_names" ]; then
    task="$task
These environment variables are exported in your shell before launch and are required by the task: $env_names."
  fi
  brief_replace_anchor "$brief" '{TASK}' "$task"
  anchor="1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`."
  replacement="1. Work only on your \`fm/$id\` branch and never open a PR. Push the finished branch to \`origin\` (your private source repository) with \`git push -u origin fm/$id\` as the last step before your terminal report."
  brief_replace_anchor "$brief" "$anchor" "$replacement"
  anchor="This task ships **local-only**: no remote, no PR, no pipeline."
  replacement="This task ships **local-only** into your private source repository: no PR, no pipeline."
  brief_replace_anchor "$brief" "$anchor" "$replacement"
  anchor="Committing is a midpoint, not the finish - after committing, run the local tests and verify branch \`fm/$id\` is ready to merge as it stands. Do NOT push, do NOT open a PR, do NOT merge."
  replacement="Committing is a midpoint, not the finish - after committing, run the local tests, verify branch \`fm/$id\` is complete as it stands, and push it to \`origin\`. Do NOT open a PR, do NOT merge."
  brief_replace_anchor "$brief" "$anchor" "$replacement"
  anchor="Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward."
  replacement="The starting branch cannot advance while you work, so no rebase is ever needed."
  brief_replace_anchor "$brief" "$anchor" "$replacement"
  anchor="This mode has exactly one terminal report: only once tests pass locally, the tree has no uncommitted changes, and the branch is mergeable exactly as it stands, append \`done: ready in branch fm/$id, tests pass, tree clean\` to the status file and stop."
  replacement="This mode has exactly one terminal report: only once tests pass locally, the tree has no uncommitted changes, and the branch is pushed to \`origin\`, append \`done: ready in branch fm/$id, tests pass, tree clean, pushed\` to the status file and stop."
  brief_replace_anchor "$brief" "$anchor" "$replacement"
  anchor="The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path."
  replacement="Nothing is merged: the pushed branch is inspected as evidence of the work."
  brief_replace_anchor "$brief" "$anchor" "$replacement"
}

# brief_replace_anchor <file> <anchor-line-or-token> <replacement>: replace
# exactly one occurrence, refusing zero or several. The replacement may span
# lines. Implemented with awk over whole lines for the anchors and a token
# substitution for {TASK}, never with sed patterns, so backticks, slashes,
# and brackets in either side are literal.
brief_replace_anchor() {  # <file> <anchor> <replacement>
  local file=$1 anchor=$2 replacement=$3 count tmp
  if [ "$anchor" = '{TASK}' ]; then
    count=$(grep -Fxc -- '{TASK}' "$file" || true)
  else
    count=$(grep -Fxc -- "$anchor" "$file" || true)
  fi
  [ "$count" = 1 ] || die "brief scaffold anchor matched $count times in $file (expected exactly once); the bin/fm-brief.sh scaffold has changed and this tool must be updated before any arm launches: $anchor"
  tmp="$file.fm-model-bench.$$"
  awk -v anchor="$anchor" -v replacement="$replacement" '
    $0 == anchor { print replacement; next }
    { print }
  ' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

setup_arm() {  # <arm> <harness> <model>
  local arm=$1 harness=$2 model=$3 rec dir bare clone project branch sha name id
  dir=$(arm_dir "$arm")
  rec=$(arm_rec "$arm")
  project=$(rec_get "$(run_rec)" project)
  name=$(rec_get "$(run_rec)" project_name)
  branch=$(rec_get "$(run_rec)" base_branch)
  sha=$(rec_get "$(run_rec)" base_sha)
  id="$RUN_ID-$arm"
  bare="$dir/source.git"
  clone="$dir/$name"
  mkdir -p "$dir"
  if [ -f "$rec" ]; then
    [ "$(rec_get "$rec" harness)" = "$harness" ] && [ "$(rec_get "$rec" model)" = "$model" ] \
      || die "$arm: run $RUN_ID already records $(rec_get "$rec" harness):$(rec_get "$rec" model), not $harness:$model"
  else
    rec_set "$rec" arm "$arm"
    rec_set "$rec" task_id "$id"
    rec_set "$rec" harness "$harness"
    rec_set "$rec" model "$model"
    rec_set "$rec" source_git "$bare"
    rec_set "$rec" clone "$clone"
    rec_set "$rec" branch "fm/$id"
    rec_set "$rec" sessions_root "$(harness_sessions_root "$harness")"
  fi
  if [ ! -d "$bare" ]; then
    git init --quiet --bare "$bare" || die "$arm: could not create $bare"
    # Reflogged so a later push into this private repository carries a
    # timestamp the report can show beside the completion milestone.
    git -C "$bare" config core.logAllRefUpdates true
    git -C "$project" push --quiet "$bare" "$sha:refs/heads/$branch" || die "$arm: could not push the starting branch into $bare"
    git -C "$bare" symbolic-ref HEAD "refs/heads/$branch"
  fi
  if [ ! -d "$clone" ]; then
    git clone --quiet --no-hardlinks "$(physical_path "$bare")" "$clone" || die "$arm: could not clone $bare"
  fi
  verify_isolation "$arm"
  pretrust "$harness" "$(physical_path "$clone")"
  if [ ! -f "$DATA/$id/brief.md" ]; then
    write_arm_brief "$arm"
  fi
}

# --- launch -----------------------------------------------------------------

launch_arm() {  # <arm>
  local arm=$1 rec id harness model clone out wt window
  local -a args
  rec=$(arm_rec "$arm")
  id=$(rec_get "$rec" task_id)
  harness=$(rec_get "$rec" harness)
  model=$(rec_get "$rec" model)
  clone=$(physical_path "$(rec_get "$rec" clone)")
  args=("$id" "$clone" --mode local-only --yolo off --harness "$harness" --model "$model" --env-file "$RUN_DIR/env")
  [ -z "$(rec_get "$(run_rec)" effort)" ] || args+=(--effort "$(rec_get "$(run_rec)" effort)")
  [ -z "$(rec_get "$(run_rec)" backend)" ] || args+=(--backend "$(rec_get "$(run_rec)" backend)")
  rec_set "$rec" launched_at "$(now_iso)"
  out=$(FM_HOME="$FM_HOME" "$SPAWN_BIN" "${args[@]}" 2>&1) || {
    rec_set "$rec" launch_error "spawn failed"
    printf '%s\n' "$out" >&2
    die "$arm: launch failed; run $RUN_ID is stopped with $arm unlaunched"
  }
  printf '%s\n' "$out" | grep -v '^spawned ' >&2 || true
  wt=$(printf '%s\n' "$out" | sed -n 's/^spawned .* worktree=//p' | tail -1)
  window=$(printf '%s\n' "$out" | sed -n 's/^spawned .* window=\([^ ]*\).*/\1/p' | tail -1)
  [ -n "$wt" ] || die "$arm: spawn reported no worktree; run $RUN_ID is stopped"
  rec_set "$rec" worktree "$wt"
  rec_set "$rec" window "$window"
  [ "$(rec_get "$STATE/$id.meta" model 2>/dev/null || true)" = "$model" ] \
    || die "$arm: task record for $id does not carry model=$model; run $RUN_ID is stopped"
  verify_worktree_binding "$arm" "$wt"
  printf 'launched %s %s:%s task=%s worktree=%s\n' "$arm" "$harness" "$model" "$id" "$wt"
}

plan_arm() {  # <arm>
  local arm=$1 rec id harness model clone
  rec=$(arm_rec "$arm")
  id=$(rec_get "$rec" task_id)
  harness=$(rec_get "$rec" harness)
  model=$(rec_get "$rec" model)
  clone=$(physical_path "$(rec_get "$rec" clone)")
  printf 'would launch %s: %s %s %s --mode local-only --yolo off --harness %s --model %s --env-file %s' \
    "$arm" "$SPAWN_BIN" "$id" "$clone" "$harness" "$model" "$RUN_DIR/env"
  [ -z "$(rec_get "$(run_rec)" effort)" ] || printf ' --effort %s' "$(rec_get "$(run_rec)" effort)"
  [ -z "$(rec_get "$(run_rec)" backend)" ] || printf ' --backend %s' "$(rec_get "$(run_rec)" backend)"
  printf '\n'
}

# --- status -----------------------------------------------------------------

# The last status line's verb and whether it is terminal for this tool. done
# and failed end the arm; blocked, needs-decision, and captain-held park it
# and end the watch too, because nothing here can answer for the arm.
arm_status_verb() {  # <task-id>
  local file="$STATE/$1.status" line
  [ -f "$file" ] || { printf 'launched'; return 0; }
  line=$(grep -E '^[a-z-]+( \[[^]]*\])?:' "$file" | tail -1 || true)
  [ -n "$line" ] || { printf 'launched'; return 0; }
  printf '%s' "$line" | sed -E 's/^([a-z-]+)( \[[^]]*\])?:.*/\1/'
}

verb_is_terminal() {  # <verb>
  case "$1" in done|failed|blocked|needs-decision|captain-held) return 0 ;; esac
  return 1
}

record_milestone() {  # <arm>
  local arm=$1 rec id verb
  rec=$(arm_rec "$arm")
  id=$(rec_get "$rec" task_id)
  verb=$(arm_status_verb "$id")
  verb_is_terminal "$verb" || return 1
  [ -z "$(rec_get "$rec" milestone || true)" ] || return 0
  rec_set "$rec" terminal "$verb"
  rec_set "$rec" milestone "$(file_mtime_iso "$STATE/$id.status")"
}

watch_run() {  # <timeout-seconds> <poll-seconds>
  local timeout=$1 poll=$2 started arm id verb last='' snapshot pending
  started=$(date +%s)
  while :; do
    snapshot=''
    pending=0
    for arm in $(list_arms); do
      id=$(rec_get "$(arm_rec "$arm")" task_id)
      verb=$(arm_status_verb "$id")
      if verb_is_terminal "$verb"; then
        record_milestone "$arm" || true
      else
        pending=$((pending + 1))
      fi
      snapshot="$snapshot $arm=$verb"
    done
    if [ "$snapshot" != "$last" ]; then
      printf '%s status:%s\n' "$(now_iso)" "$snapshot"
      last=$snapshot
    fi
    [ "$pending" -gt 0 ] || return 0
    if [ "$timeout" -gt 0 ] && [ $(($(date +%s) - started)) -ge "$timeout" ]; then
      note "watch timed out after ${timeout}s with $pending arm(s) still running; report will show them as incomplete"
      return 0
    fi
    sleep "$poll"
  done
}

# After every arm is terminal, wait for each arm's session record to close the
# turn that wrote the terminal line, so the slice lands on a closed bracket.
settle_run() {  # <max-seconds>
  local max=$1 started arm rec id harness wt root launched milestone out pending waited_note=0
  started=$(date +%s)
  while :; do
    pending=''
    for arm in $(list_arms); do
      rec=$(arm_rec "$arm")
      milestone=$(rec_get "$rec" milestone || true)
      [ -n "$milestone" ] || continue
      id=$(rec_get "$rec" task_id)
      harness=$(rec_get "$rec" harness)
      root=$(rec_get "$rec" sessions_root)
      launched=$(rec_get "$rec" launched_at || true)
      wt=$(rec_get "$STATE/$id.meta" worktree 2>/dev/null || true)
      [ -n "$wt" ] || wt=$(rec_get "$rec" worktree || true)
      [ -n "$wt" ] && [ -n "$launched" ] || continue
      out=$("$ANALYZE" session --harness "$harness" --workspace "$wt" --sessions-root "$root"         --launched-at "$launched" --milestone "$milestone" 2>/dev/null) || continue
      [ "$(printf '%s' "$out" | jq -r '.slice_note // empty')" = '' ] || pending="$pending $arm"
    done
    [ -n "$pending" ] || return 0
    if [ $(($(date +%s) - started)) -ge "$max" ]; then
      note "gave up waiting for the final turn of$pending to close in the session record after ${max}s; the report marks that turn open"
      return 0
    fi
    [ "$waited_note" -eq 1 ] || { printf '%s waiting for the final turn of%s to close in the session record\n' "$(now_iso)" "$pending"; waited_note=1; }
    sleep 3
  done
}

# --- report -----------------------------------------------------------------

# Materialise every file the arm added or modified into <out>, each with its
# mtime set to the moment that exact content first appeared on the arm's
# branch (or the file's own mtime when uncommitted), so the independence
# check can order two identical copies.
materialize_changes() {  # <arm> <out-dir>
  local arm=$1 out=$2 rec wt bare base branch src ref path blob first commit
  rec=$(arm_rec "$arm")
  wt=$(rec_get "$rec" worktree || true)
  bare=$(rec_get "$rec" source_git)
  branch=$(rec_get "$rec" branch)
  base=$(rec_get "$(run_rec)" base_sha)
  rm -rf "$out"
  mkdir -p "$out"
  if [ -n "$wt" ] && [ -d "$wt/.git" ] || [ -n "$wt" ] && [ -f "$wt/.git" ]; then
    src=$wt
    ref=HEAD
  elif git -C "$bare" rev-parse --verify --quiet "refs/heads/$branch^{commit}" >/dev/null 2>&1; then
    src=$bare
    ref="refs/heads/$branch"
  else
    return 0
  fi
  git -C "$src" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 || return 0
  {
    git -C "$src" diff --name-only --diff-filter=AM "$base" "$ref" 2>/dev/null || true
    if [ "$src" = "$wt" ]; then
      git -C "$wt" diff --name-only --diff-filter=AM "$base" 2>/dev/null || true
      git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true
    fi
  } | LC_ALL=C sort -u | while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$out/$(dirname "$path")"
    if [ "$src" = "$wt" ] && [ -f "$wt/$path" ]; then
      cp -p -- "$wt/$path" "$out/$path"
      blob=$(git -C "$wt" hash-object -- "$wt/$path")
    else
      git -C "$src" show "$ref:$path" > "$out/$path" 2>/dev/null || { rm -f "$out/$path"; continue; }
      blob=$(git -C "$src" rev-parse --verify --quiet "$ref:$path")
    fi
    first=''
    for commit in $(git -C "$src" rev-list --reverse "$base..$ref" 2>/dev/null); do
      if [ "$(git -C "$src" rev-parse --verify --quiet "$commit:$path" 2>/dev/null || true)" = "$blob" ]; then
        first=$(git -C "$src" show -s --format=%ct "$commit")
        break
      fi
    done
    [ -z "$first" ] || touch_at_epoch "$out/$path" "$first"
  done
}

report_run() {  # [--json]
  local want_json=${1:-} arm rec id harness model wt milestone verb line launched root session indep_args=() indep changed
  local report="$RUN_DIR/report.json" arms_json='[]' warn_json='[]' broadcasts_json='[]' hb
  require_tool jq "report assembly"
  for arm in $(list_arms); do
    rec=$(arm_rec "$arm")
    id=$(rec_get "$rec" task_id)
    harness=$(rec_get "$rec" harness)
    model=$(rec_get "$rec" model)
    root=$(rec_get "$rec" sessions_root)
    wt=$(rec_get "$STATE/$id.meta" worktree 2>/dev/null || true)
    [ -n "$wt" ] || wt=$(rec_get "$rec" worktree || true)
    launched=$(rec_get "$rec" launched_at || true)
    record_milestone "$arm" >/dev/null 2>&1 || true
    milestone=$(rec_get "$rec" milestone || true)
    verb=$(arm_status_verb "$id")
    line=$(grep -E '^[a-z-]+( \[[^]]*\])?:' "$STATE/$id.status" 2>/dev/null | tail -1 || true)
    hb=$(rec_get "$STATE/$id.meta" model 2>/dev/null || true)
    if [ -n "$hb" ] && [ "$hb" != "$model" ]; then
      warn_json=$(printf '%s' "$warn_json" | jq --arg w "$arm: task record carries model=$hb, not the requested $model" '. + [$w]')
    fi
    if [ -n "$wt" ] && [ -n "$launched" ]; then
      session=$("$ANALYZE" session --harness "$harness" --workspace "$wt" --sessions-root "$root" \
        --launched-at "$launched" ${milestone:+--milestone "$milestone"} 2>&1) \
        || { warn_json=$(printf '%s' "$warn_json" | jq --arg w "$arm: session record unreadable: $session" '. + [$w]'); session=null; }
    else
      session=null
      [ -n "$launched" ] || warn_json=$(printf '%s' "$warn_json" | jq --arg w "$arm: never launched" '. + [$w]')
    fi
    materialize_changes "$arm" "$(arm_dir "$arm")/changed"
    changed=$(find "$(arm_dir "$arm")/changed" -type f 2>/dev/null | wc -l | tr -d ' ')
    indep_args+=("$arm=$(arm_dir "$arm")/changed")
    arms_json=$(printf '%s' "$arms_json" | jq \
      --arg arm "$arm" --arg id "$id" --arg harness "$harness" --arg model "$model" \
      --arg wt "$wt" --arg branch "$(rec_get "$rec" branch)" --arg bare "$(rec_get "$rec" source_git)" \
      --arg launched "$launched" --arg milestone "$milestone" --arg verb "$verb" --arg line "$line" \
      --argjson session "$session" --argjson changed "$changed" \
      '. + [{arm: $arm, task_id: $id, harness: $harness, model: $model, worktree: $wt, branch: $branch,
             source_git: $bare, launched_at: (if $launched == "" then null else $launched end),
             milestone: (if $milestone == "" then null else $milestone end), state: $verb, state_line: $line,
             session: $session, changed_files: $changed}]')
  done
  indep=$("$ANALYZE" independence "${indep_args[@]}") || die "independence check failed"
  if [ -f "$RUN_DIR/broadcasts.log" ]; then
    broadcasts_json=$(jq -Rs 'split("\n") | map(select(length > 0) | fromjson)' "$RUN_DIR/broadcasts.log")
    if [ "$(printf '%s' "$broadcasts_json" | jq '[.[] | select(.failed | length > 0)] | length')" != 0 ]; then
      warn_json=$(printf '%s' "$warn_json" | jq '. + ["a broadcast did not reach every arm; the arms no longer received identical instructions"]')
    fi
  fi
  jq -n \
    --arg run "$RUN_ID" --arg project "$(rec_get "$(run_rec)" project)" --arg name "$(rec_get "$(run_rec)" project_name)" \
    --arg sha "$(rec_get "$(run_rec)" base_sha)" --arg branch "$(rec_get "$(run_rec)" base_branch)" \
    --arg feasible "$(rec_get "$(run_rec)" feasibility)" --arg created "$(rec_get "$(run_rec)" created_at)" \
    --arg effort "$(rec_get "$(run_rec)" effort || true)" --arg now "$(now_iso)" \
    --rawfile env "$RUN_DIR/env" --rawfile task "$RUN_DIR/task.md" \
    --argjson arms "$arms_json" --argjson indep "$indep" --argjson warnings "$warn_json" --argjson broadcasts "$broadcasts_json" '
    {schema: "fm-model-bench-report.v1", run_id: $run, project: $project, project_name: $name,
     base_sha: $sha, base_branch: $branch, feasibility: $feasible, effort: (if $effort == "" then null else $effort end),
     env: ($env | split("\n") | map(select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$")) | map({(.k): .v}) | add // {}),
     task: $task, created_at: $created, reported_at: $now, broadcasts: $broadcasts, warnings: $warnings,
     arms: ($arms | map(. as $a | . + {independence: ($indep.arms[$a.arm] // {verdict: "unchecked", copied_by: [], matches: []})})),
     void_arms: $indep.void_arms, identical_pairs: $indep.pairs}' > "$report"
  if [ "$want_json" = --json ]; then
    cat "$report"
  else
    "$ANALYZE" render "$report"
  fi
}

# --- commands ---------------------------------------------------------------

cmd_run() {
  local project='' task_file='' task_text='' feasible='' base=HEAD effort='' backend='' dry=0 wait=1 timeout=0 poll=20 settle=180
  local -a arms=() envs=()
  local a spec harness model project_phys name sha branch existing i arm status_now
  while [ $# -gt 0 ]; do
    a=$1
    case "$a" in
      --arm) [ $# -ge 2 ] || die "--arm requires <harness>:<model>"; arms+=("$2"); shift 2 ;;
      --task-file) [ $# -ge 2 ] || die "--task-file requires a path"; task_file=$2; shift 2 ;;
      --task) [ $# -ge 2 ] || die "--task requires text"; task_text=$2; shift 2 ;;
      --feasible) [ $# -ge 2 ] || die "--feasible requires a statement"; feasible=$2; shift 2 ;;
      --env) [ $# -ge 2 ] || die "--env requires KEY=VALUE"; envs+=("$2"); shift 2 ;;
      --base) [ $# -ge 2 ] || die "--base requires a ref"; base=$2; shift 2 ;;
      --run-id) [ $# -ge 2 ] || die "--run-id requires an id"; RUN_ID=$2; shift 2 ;;
      --effort) [ $# -ge 2 ] || die "--effort requires a level"; effort=$2; shift 2 ;;
      --backend) [ $# -ge 2 ] || die "--backend requires a name"; backend=$2; shift 2 ;;
      --timeout) [ $# -ge 2 ] || die "--timeout requires seconds"; timeout=$2; shift 2 ;;
      --poll) [ $# -ge 2 ] || die "--poll requires seconds"; poll=$2; shift 2 ;;
      --settle) [ $# -ge 2 ] || die "--settle requires seconds"; settle=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --no-wait) wait=0; shift ;;
      -h|--help) usage; exit 0 ;;
      --*) die "unknown option $a" ;;
      *) [ -z "$project" ] || die "unexpected argument $a"; project=$a; shift ;;
    esac
  done
  [ -n "$project" ] || die "run needs a <project-dir>"
  [ "${#arms[@]}" -ge 2 ] || die "run needs at least two --arm <harness>:<model> entries; one arm is not a comparison"
  [ -n "$feasible" ] || die "--feasible <statement> is required: assert that the task is achievable, because an impossible task measures refusal, not capability"
  [ -n "$task_file" ] || [ -n "$task_text" ] || die "pass --task-file <path> or --task <text>"
  [ -z "$task_file" ] || [ -z "$task_text" ] || die "--task-file and --task are exclusive"
  [ -z "$task_file" ] || [ -f "$task_file" ] || die "task file not found: $task_file"
  case "$timeout$poll$settle" in *[!0-9]*) die "--timeout, --poll, and --settle take whole seconds" ;; esac
  [ "$poll" -ge 1 ] || die "--poll must be at least 1"
  require_tool git "arm isolation"
  require_tool node "session arithmetic"
  require_tool jq "record handling"
  for spec in "${arms[@]}"; do
    harness=${spec%%:*}
    model=${spec#*:}
    [ "$harness" != "$spec" ] && [ -n "$harness" ] && [ -n "$model" ] || die "--arm must be <harness>:<model>, got '$spec'"
    harness_supported "$harness" || die "harness '$harness' is not supported: this tool can read session records for codex and claude only, so an arm on '$harness' could never have its running model confirmed"
    command -v "$harness" >/dev/null 2>&1 || die "harness '$harness' is not installed on PATH"
    case "$model" in *[[:space:]]*) die "model '$model' contains whitespace" ;; esac
  done
  for a in "${envs[@]}"; do
    case "$a" in
      [A-Za-z_]*=*) ;;
      *) die "--env must be KEY=VALUE with a shell-safe KEY, got '$a'" ;;
    esac
    case "${a%%=*}" in
      *[!A-Za-z0-9_]*) die "--env KEY must match [A-Za-z_][A-Za-z0-9_]*, got '${a%%=*}'" ;;
      GOTMPDIR|TRACEPARENT|FM_*) die "--env may not set ${a%%=*}: firstmate owns that variable in every arm" ;;
    esac
    case "$a" in *$'\n'*) die "--env values are single lines" ;; esac
  done
  project_phys=$(physical_path "$project") || die "project directory not found: $project"
  git -C "$project_phys" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$project_phys is not a git checkout"
  sha=$(git -C "$project_phys" rev-parse --verify --quiet "$base^{commit}") || die "--base '$base' is not a commit in $project_phys"
  if git -C "$project_phys" show-ref --verify --quiet "refs/heads/$base"; then
    branch=$base
  else
    branch=$(git -C "$project_phys" symbolic-ref --short -q HEAD || true)
    [ -n "$branch" ] || branch=main
  fi
  name=$(basename "$project_phys")
  [ -n "$RUN_ID" ] || RUN_ID="mb-$(date -u +%m%d)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  run_id_valid "$RUN_ID" || die "run id '$RUN_ID' must be path-safe and at most 56 characters"
  RUN_DIR=$(run_dir)
  existing=0
  if [ -e "$RUN_DIR" ]; then
    [ "$dry" -eq 1 ] && [ "$(rec_get "$(run_rec)" status 2>/dev/null || true)" = dry-run ] \
      || die "run $RUN_ID already exists at $RUN_DIR; a run directory is never reused (a dry run may be re-verified with --dry-run)"
    existing=1
    [ "$(rec_get "$(run_rec)" base_sha)" = "$sha" ] || die "run $RUN_ID was set up at $(rec_get "$(run_rec)" base_sha), not $sha"
  fi
  if [ -n "$(git -C "$project_phys" status --porcelain 2>/dev/null)" ]; then
    note "notice: $project_phys has uncommitted changes; arms start from commit $sha and never see them"
  fi
  fm_refuse_if_gate_agent
  mkdir -p "$RUN_DIR/arms"
  if [ "$existing" -eq 0 ]; then
    if [ -n "$task_file" ]; then cp -- "$task_file" "$RUN_DIR/task.md"; else printf '%s\n' "$task_text" > "$RUN_DIR/task.md"; fi
    [ -s "$RUN_DIR/task.md" ] || die "the task body is empty"
    : > "$RUN_DIR/env"
    for a in "${envs[@]}"; do printf '%s\n' "$a" >> "$RUN_DIR/env"; done
    rec_set "$(run_rec)" run_id "$RUN_ID"
    rec_set "$(run_rec)" project "$project_phys"
    rec_set "$(run_rec)" project_name "$name"
    rec_set "$(run_rec)" base_ref "$base"
    rec_set "$(run_rec)" base_sha "$sha"
    rec_set "$(run_rec)" base_branch "$branch"
    rec_set "$(run_rec)" feasibility "$feasible"
    rec_set "$(run_rec)" effort "$effort"
    rec_set "$(run_rec)" backend "$backend"
    rec_set "$(run_rec)" created_at "$(now_iso)"
    rec_set "$(run_rec)" status setup
  fi
  i=0
  for spec in "${arms[@]}"; do
    i=$((i + 1))
    setup_arm "a$i" "${spec%%:*}" "${spec#*:}"
  done
  verify_run
  printf 'feasibility (asserted by the caller, not checked): %s\n' "$feasible"
  if [ "$dry" -eq 1 ]; then
    rec_set "$(run_rec)" status dry-run
    for arm in $(list_arms); do plan_arm "$arm"; done
    printf 'dry run: nothing launched; run %s is verified at %s\n' "$RUN_ID" "$RUN_DIR"
    return 0
  fi
  for arm in $(list_arms); do
    add_backlog_row "$(rec_get "$(arm_rec "$arm")" task_id)" "Model gut-check $RUN_ID arm $arm" "$name"
  done
  rec_set "$(run_rec)" status launching
  for arm in $(list_arms); do
    launch_arm "$arm"
  done
  rec_set "$(run_rec)" status launched
  if [ "$wait" -eq 1 ]; then
    watch_run "$timeout" "$poll"
    settle_run "$settle"
    report_run
    rec_set "$(run_rec)" status reported
  else
    status_now=$(now_iso)
    printf '%s launched %s arms; run "%s report %s" when they finish (or "%s send %s <text>" to steer every arm at once)\n' \
      "$status_now" "$(list_arms | wc -l | tr -d ' ')" "$0" "$RUN_ID" "$0" "$RUN_ID"
  fi
}

cmd_verify() {
  [ $# -eq 1 ] || { usage >&2; exit 2; }
  RUN_ID=$1
  run_id_valid "$RUN_ID" || die "invalid run id"
  RUN_DIR=$(run_dir)
  [ -d "$RUN_DIR" ] || die "run $RUN_ID not found at $RUN_DIR"
  verify_run
  printf 'run %s verified\n' "$RUN_ID"
}

cmd_send() {
  [ $# -ge 2 ] || { usage >&2; exit 2; }
  RUN_ID=$1
  shift
  run_id_valid "$RUN_ID" || die "invalid run id"
  RUN_DIR=$(run_dir)
  [ -d "$RUN_DIR" ] || die "run $RUN_ID not found at $RUN_DIR"
  local text="$*" arm id verb delivered='[]' failed='[]' out
  [ -n "$text" ] || die "send needs a message"
  fm_refuse_if_gate_agent
  for arm in $(list_arms); do
    id=$(rec_get "$(arm_rec "$arm")" task_id)
    [ -f "$STATE/$id.meta" ] || die "$arm ($id) has no live task record; refusing to send to some arms but not others"
    verb=$(arm_status_verb "$id")
    case "$verb" in
      done|failed) die "$arm ($id) already reported $verb; refusing to send to some arms but not others" ;;
    esac
  done
  for arm in $(list_arms); do
    id=$(rec_get "$(arm_rec "$arm")" task_id)
    if out=$(FM_HOME="$FM_HOME" "$SEND_BIN" "$id" "$text" 2>&1); then
      delivered=$(printf '%s' "$delivered" | jq --arg a "$arm" '. + [$a]')
    else
      printf '%s\n' "$out" >&2
      failed=$(printf '%s' "$failed" | jq --arg a "$arm" '. + [$a]')
    fi
  done
  jq -cn --arg at "$(now_iso)" --arg text "$text" --argjson d "$delivered" --argjson f "$failed" \
    '{at: $at, text: $text, delivered: $d, failed: $f}' >> "$RUN_DIR/broadcasts.log"
  if [ "$(printf '%s' "$failed" | jq 'length')" != 0 ]; then
    die "broadcast reached $(printf '%s' "$delivered" | jq -r 'join(",")') but not $(printf '%s' "$failed" | jq -r 'join(",")'); the arms no longer share identical instructions and report will say so"
  fi
  printf 'sent to %s\n' "$(printf '%s' "$delivered" | jq -r 'join(", ")')"
}

cmd_report() {
  [ $# -ge 1 ] || { usage >&2; exit 2; }
  RUN_ID=$1
  shift
  run_id_valid "$RUN_ID" || die "invalid run id"
  RUN_DIR=$(run_dir)
  [ -d "$RUN_DIR" ] || die "run $RUN_ID not found at $RUN_DIR"
  case "${1:-}" in
    ''|--json) ;;
    *) die "report takes only --json" ;;
  esac
  report_run "${1:-}"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  send) shift; cmd_send "$@" ;;
  report) shift; cmd_report "$@" ;;
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command '$1' (run, verify, send, report)" ;;
esac
