#!/usr/bin/env bash
# Import a repository's already-merged pull requests into the Linear mirror, so
# the board can answer "what has been built and confirmed" for work that shipped
# before the merge started writing to Linear itself.
#
# Usage: fm-linear-import-prs.sh --repo <owner/name> [--dry-run] [--team <KEY>]
#                                [--limit <n>] [--backlog <file>] [--archive <file>]
#
# WHY GITHUB AND NOT THE BACKLOG. data/backlog.md prunes Done to the configured
# recent few, so it is not a record of what shipped; GitHub is the only complete
# one. data/done-archive.md CANNOT be used to recover the mapping either -
# matching archived entries to pull requests by proximity was tried on
# 2026-08-03 and produced cross-assigned results. That approach is not repeated
# here.
#
# THE MAPPING, AND WHY IT IS TRUSTWORTHY. The task id is derived from the branch
# name firstmate itself created when it dispatched the work: fm/<task-id>. That
# is an exact, mechanical join, not a guess. A branch that does not match
# fm/<numbered-task-id> is REPORTED AS UNMAPPED and nothing is written for it.
# An unmapped pull request listed honestly is a fine outcome; a wrongly attached
# one is the failure this shape exists to avoid. The backlog and its archive are
# read only to give a created issue a better title than the pull request subject
# - never to derive the mapping.
#
# EVERY WRITE IS AUDITABLE. One line per pull request records the verdict, the
# issue, the derived task id, the pull request number, and the branch the id came
# from. A created issue additionally carries that provenance in its description,
# so the mapping survives in Linear itself and not only in this run's output.
#
# Re-runnable: an issue already Done is not transitioned again and a pull request
# already attached is not attached again, so a second import converges.
#
# Exit codes: 0 imported (or inert because Linear is not configured), 2 usage,
# 3 Linear or GitHub unreachable, 4 some operations failed (including a team
# that cannot be resolved when an issue must be created).
#
# Single quotes below are on purpose twice over: $id and friends inside the
# GraphQL documents are GraphQL variables, not shell expansions, and the
# backticks in the composed description are literal markdown code spans.
# shellcheck disable=SC2016
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

DRY=
REPO=
TEAM_KEY=
LIMIT=200
BACKLOG="$FM_HOME/data/backlog.md"
ARCHIVE="$FM_HOME/data/done-archive.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1; shift ;;
    --repo) REPO=${2:-}; shift 2 ;;
    --team) TEAM_KEY=${2:-}; shift 2 ;;
    --limit) LIMIT=${2:-}; shift 2 ;;
    --backlog) BACKLOG=${2:-}; shift 2 ;;
    --archive) ARCHIVE=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "fm-linear-import-prs: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$REPO" in
  ''|*[!A-Za-z0-9._/-]*|*/*/*|/*|*/) echo "fm-linear-import-prs: --repo must be <owner>/<name>" >&2; exit 2 ;;
  */*) ;;
  *) echo "fm-linear-import-prs: --repo must be <owner>/<name>" >&2; exit 2 ;;
esac
case "$LIMIT" in ''|*[!0-9]*) echo "fm-linear-import-prs: --limit must be a number" >&2; exit 2 ;; esac

# shellcheck source=bin/fm-linear-lib.sh
. "$FM_ROOT/bin/fm-linear-lib.sh"
fml_load_config
[ -n "$TEAM_KEY" ] || TEAM_KEY=$FML_TEAM

if ! fml_available; then
  echo "linear: $(fml_unavailable_reason); import did not run"
  exit 0
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "fm-linear-import-prs: gh is not installed, so the merged pull requests cannot be read" >&2
  exit 3
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-import.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 143' HUP INT TERM

# --- what actually shipped, from GitHub --------------------------------------

if ! gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
  --json number,url,title,headRefName,mergedAt > "$TMP/prs.json" 2>"$TMP/gh.err"; then
  echo "fm-linear-import-prs: could not list merged pull requests for $REPO ($(head -n1 "$TMP/gh.err" 2>/dev/null))" >&2
  exit 3
fi
if ! jq -e 'type == "array"' "$TMP/prs.json" >/dev/null 2>&1; then
  echo "fm-linear-import-prs: could not parse the merged pull request list for $REPO" >&2
  exit 3
fi
jq -r '.[] | [(.number|tostring), .url, .headRefName, (.mergedAt // ""), .title] | @tsv' \
  "$TMP/prs.json" | sort -t"$(printf '\t')" -k1,1n > "$TMP/prs.tsv"

# --- titles the backlog can still supply -------------------------------------
#
# Only ever a nicety for a CREATED issue. The mapping never depends on this file
# being complete, which is the whole reason the branch name is the join.

: > "$TMP/titles.tsv"
if [ -f "$BACKLOG" ]; then
  "$FM_ROOT/bin/fm-backlog-tsv.sh" "$BACKLOG" "$ARCHIVE" 2>/dev/null \
    | awk -F'\t' 'NF >= 3 { print $2 "\t" $3 }' > "$TMP/titles.tsv" || : > "$TMP/titles.tsv"
fi

# --- the team a created issue belongs to -------------------------------------

TEAM_ID=
DONE_STATE=
if [ -n "$TEAM_KEY" ]; then
  set +e
  team_row=$(fml_team_by_key "$TEAM_KEY" "$TMP/team.json")
  set -e
  TEAM_ID=$(printf '%s' "$team_row" | cut -f1)
  DONE_STATE=$(printf '%s' "$team_row" | cut -f2)
fi

created=0; linked=0; unmapped=0; unchanged=0; failed=0
: > "$TMP/unmapped.txt"

audit() { printf '  %-9s %-12s %-34s PR #%-5s branch %s\n' "$1" "${2:--}" "${3:--}" "$4" "$5"; }

# A firstmate task id as the dispatcher writes it: a numeric prefix and a slug.
# Deliberately stricter than the id validation used elsewhere, because the only
# question here is "did firstmate create this branch for a numbered backlog
# item", and every legacy hand-named fm/... branch must fail it rather than be
# mapped to something that looks close.
derive_task_id() {
  local branch=$1 id
  case "$branch" in
    fm/*) id=${branch#fm/} ;;
    *) return 1 ;;
  esac
  [[ "$id" =~ ^[0-9]+-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s' "$id"
}

# --- reconcile every merged pull request --------------------------------------

while IFS= read -r row; do
  [ -n "$row" ] || continue
  number=${row%%$'\t'*}; rest=${row#*$'\t'}
  pr_url=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  branch=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  merged_at=${rest%%$'\t'*}
  pr_title=${rest#*$'\t'}

  if ! task_id=$(derive_task_id "$branch"); then
    audit "unmapped" "" "" "$number" "$branch"
    printf '  PR #%-5s %s\n' "$number" "$branch" >> "$TMP/unmapped.txt"
    unmapped=$((unmapped + 1))
    continue
  fi

  set +e
  issue_row=$(fml_find_issue "$task_id")
  rc=$?
  set -e
  if [ "$rc" = 2 ]; then
    audit "FAILED" "" "$task_id" "$number" "$branch"
    echo "    lookup unavailable for $task_id; nothing written" >&2
    failed=$((failed + 1))
    continue
  fi

  issue_uuid=; ident=; state_type=; attached=
  if [ "$rc" = 0 ]; then
    ident=$(printf '%s' "$issue_row" | cut -f1)
    issue_uuid=$(printf '%s' "$issue_row" | cut -f2)
    state_type=$(printf '%s' "$issue_row" | cut -f5)
    [ -n "$TEAM_ID" ] || TEAM_ID=$(printf '%s' "$issue_row" | cut -f6)
    attached=$(printf '%s' "$issue_row" | cut -f7 | base64 -d 2>/dev/null || true)
    verdict=linked
  else
    # No mirrored issue: create one from what GitHub proves, recording where it
    # came from so the mapping stays checkable long after this run.
    title=$(awk -F'\t' -v id="$task_id" '$1 == id {print $2; exit}' "$TMP/titles.tsv")
    [ -n "$title" ] || title=$pr_title
    {
      printf '`firstmate: %s`\n' "$task_id"
      printf '\n**Delivered:** %s\n' "$pr_url"
      printf '\n**Imported from** merged pull request #%s in %s, branch `%s`%s.\n' \
        "$number" "$REPO" "$branch" "${merged_at:+, merged $merged_at}"
      printf '\nThe task id was derived from the branch name, which firstmate created when it dispatched the work.\n'
    } > "$TMP/desc"
    if [ -z "$TEAM_ID" ]; then
      audit "SKIP" "" "$task_id" "$number" "$branch"
      echo "    would create, but no team could be resolved (set LINEAR_TEAM_KEY or pass --team)" >&2
      failed=$((failed + 1))
      continue
    fi
    if [ -n "$DRY" ]; then
      audit "create" "(new)" "$task_id" "$number" "$branch"
      created=$((created + 1))
      continue
    fi
    vars=$(jq -cn --arg t "$TEAM_ID" --arg ti "$title" --rawfile d "$TMP/desc" '{t:$t, ti:$ti, d:$d}')
    if fml_graphql 'mutation fmCreate($t: String!, $ti: String!, $d: String!) {
      issueCreate(input: { teamId: $t, title: $ti, description: $d }) {
        success issue { id identifier }
      }
    }' "$vars" "$TMP/created.json" && fml_mutation_succeeded "$TMP/created.json" issueCreate; then
      ident=$(jq -r '.data.issueCreate.issue.identifier // ""' "$TMP/created.json")
      issue_uuid=$(jq -r '.data.issueCreate.issue.id // ""' "$TMP/created.json")
      state_type=
      verdict=created
      created=$((created + 1))
    else
      audit "FAILED" "" "$task_id" "$number" "$branch"
      echo "    create rejected by Linear" >&2
      failed=$((failed + 1))
      continue
    fi
  fi

  if [ -z "$issue_uuid" ] && [ -z "$DRY" ]; then
    audit "FAILED" "$ident" "$task_id" "$number" "$branch"
    failed=$((failed + 1))
    continue
  fi

  # Done, then the pull request. Both skipped when already true, so a repeated
  # import performs no writes at all.
  touched=0
  if [ "$state_type" != completed ]; then
    if [ -z "$DONE_STATE" ] && [ -n "$TEAM_ID" ]; then
      set +e
      DONE_STATE=$(fml_done_state_id "$TEAM_ID" "$TMP/team2.json")
      set -e
    fi
    if [ -z "$DONE_STATE" ]; then
      echo "    $task_id is shipped but the team has no completed status" >&2
      failed=$((failed + 1))
    elif [ -n "$DRY" ]; then
      touched=1
    elif fml_set_state "$issue_uuid" "$DONE_STATE" "$TMP/state.json"; then
      touched=1
    else
      audit "FAILED" "$ident" "$task_id" "$number" "$branch"
      echo "    Done transition rejected by Linear" >&2
      failed=$((failed + 1))
      continue
    fi
  fi

  if printf '%s\n' "$attached" | grep -Fxq "$pr_url"; then
    :
  elif [ -n "$DRY" ]; then
    touched=1
  elif fml_attach_url "$issue_uuid" "$pr_url" "Pull request" "$TMP/attach.json"; then
    touched=1
  else
    audit "FAILED" "$ident" "$task_id" "$number" "$branch"
    echo "    could not attach $pr_url" >&2
    failed=$((failed + 1))
    continue
  fi

  if [ "$verdict" = created ]; then
    audit "created" "$ident" "$task_id" "$number" "$branch"
  elif [ "$touched" = 0 ]; then
    audit "unchanged" "$ident" "$task_id" "$number" "$branch"
    unchanged=$((unchanged + 1))
  else
    audit "linked" "$ident" "$task_id" "$number" "$branch"
    linked=$((linked + 1))
  fi
done < "$TMP/prs.tsv"

# --- summary ------------------------------------------------------------------

pr_n=$(wc -l < "$TMP/prs.tsv" | tr -d '[:space:]')
echo
printf 'linear import%s: %s merged pull requests in %s%s\n' \
  "${DRY:+ (dry run)}" "$pr_n" "$REPO" "${TEAM_KEY:+, team $TEAM_KEY}"
printf '  created %s, linked %s, unchanged %s, unmapped %s, failed %s\n' \
  "$created" "$linked" "$unchanged" "$unmapped" "$failed"
if [ -s "$TMP/unmapped.txt" ]; then
  printf '\n  branch name does not carry a firstmate task id (%s) - REPORTED ONLY, nothing was written:\n' \
    "$unmapped"
  cat "$TMP/unmapped.txt"
fi

[ "$failed" = 0 ] || exit 4
