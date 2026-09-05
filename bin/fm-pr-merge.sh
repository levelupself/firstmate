#!/usr/bin/env bash
# Merge a task's PR after recording durable task-to-PR provenance.
# A live task first records pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# A task whose volatile metadata is already gone is accepted only when the
# backlog's Done history records the same canonical PR, or an earlier exact
# merge receipt proves a retry of the same request.
# Every accepted request writes a prepared data/pr-merges/<task-id>.receipt
# before the forge mutation. A successful merge advances it to merged only
# after the forge reports the merge commit on its current default branch;
# post-mutation confirmation retries three times. When the project's origin is
# a local filesystem mirror, the confirmed commit is fetched from the matching
# GitHub remote and pushed to that mirror by fast-forward only before the merge
# outcome is stamped. The merged receipt records that branch and commit plus
# the forge merge time when available. An unavailable forge time stays empty
# rather than becoming "now".
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
# Before an unmerged PR reaches the forge mutation, bin/fm-pr-checks.sh must
# report passing; failing and ABSENT checks both preserve prepared provenance
# and refuse the merge.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-meta-lock-lib.sh
. "$SCRIPT_DIR/fm-task-meta-lock-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
"$SCRIPT_DIR/fm-backlog-integrity.sh" check-row "$ID" --allow-absent || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
PROVENANCE_DIR="$DATA/pr-merges"
PROVENANCE_RECEIPT="$PROVENANCE_DIR/$ID.receipt"
MERGE_LOCK="$STATE/.pr-merge-$ID.lock"
MERGE_LOCK_HELD=0
CURRENT_SPAWNED_AT=$(sed -n 's/^spawned_at=//p' "$META" 2>/dev/null | tail -1)
PROJECT=$(sed -n 's/^project=//p' "$META" 2>/dev/null | tail -1)

merge_lock_cleanup() {
  if [ "$MERGE_LOCK_HELD" = 1 ]; then
    fm_lock_release "$MERGE_LOCK" || true
    MERGE_LOCK_HELD=0
  fi
}

trap merge_lock_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$MERGE_LOCK"
MERGE_LOCK_HELD=1

receipt_value() {
  local key=$1
  sed -n "s/^${key}=//p" "$PROVENANCE_RECEIPT" 2>/dev/null | tail -1
}

receipt_matches_request() {
  local authorization merged_at merged_epoch phase prepared_epoch schema
  [ -f "$PROVENANCE_RECEIPT" ] && [ ! -L "$PROVENANCE_RECEIPT" ] || return 1
  [ "$(grep -c '^schema=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
  [ "$(grep -c '^task_id=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
  [ "$(grep -c '^pr=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
  [ "$(grep -c '^phase=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
  [ "$(grep -c '^authorization=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
  [ "$(grep -c '^prepared_epoch=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
  [ "$(grep -c '^spawned_at=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
  schema=$(receipt_value schema)
  [ "$schema" = fm-pr-merge.v1 ] || [ "$schema" = fm-pr-merge.v2 ] \
    || [ "$schema" = fm-pr-merge.v3 ] || [ "$schema" = fm-pr-merge.v4 ] || return 1
  [ "$(receipt_value task_id)" = "$ID" ] || return 1
  [ "$(receipt_value pr)" = "$URL" ] || return 1
  printf '%s\n' "$(receipt_value spawned_at)" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || return 1
  [ -z "$CURRENT_SPAWNED_AT" ] || [ "$(receipt_value spawned_at)" = "$CURRENT_SPAWNED_AT" ] || return 1
  authorization=$(receipt_value authorization)
  [ "$authorization" = live-meta ] || [ "$authorization" = done-record ] || return 1
  prepared_epoch=$(receipt_value prepared_epoch)
  case "$prepared_epoch" in ''|*[!0-9]*) return 1 ;; esac
  phase=$(receipt_value phase)
  case "$phase" in
    prepared)
      if [ "$schema" = fm-pr-merge.v2 ] || [ "$schema" = fm-pr-merge.v3 ] || [ "$schema" = fm-pr-merge.v4 ]; then
        [ "$(grep -c '^merged_epoch=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 0 ] || return 1
        [ "$(grep -c '^merged_at=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] \
          && [ -z "$(receipt_value merged_at)" ]
      else
        [ "$(grep -c '^merged_at=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 0 ] || return 1
        [ "$(grep -c '^merged_epoch=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 0 ]
      fi
      ;;
    merged)
      if [ "$schema" = fm-pr-merge.v2 ] || [ "$schema" = fm-pr-merge.v3 ] || [ "$schema" = fm-pr-merge.v4 ]; then
        [ "$(grep -c '^merged_epoch=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 0 ] || return 1
        [ "$(grep -c '^merged_at=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
        merged_at=$(receipt_value merged_at)
        [ -z "$merged_at" ] \
          || printf '%s\n' "$merged_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
      else
        [ "$(grep -c '^merged_at=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 0 ] || return 1
        [ "$(grep -c '^merged_epoch=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
        merged_epoch=$(receipt_value merged_epoch)
        case "$merged_epoch" in ''|*[!0-9]*) return 1 ;; esac
      fi
      ;;
    *) return 1 ;;
  esac
  if [ "$schema" = fm-pr-merge.v3 ] || [ "$schema" = fm-pr-merge.v4 ]; then
    [ "$(grep -c '^repository=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
    [ "$(grep -c '^default_branch=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
    [ "$(grep -c '^merge_commit=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
    [ "$(receipt_value repository)" = "$PR_OWNER/$PR_REPO" ] || return 1
    if [ "$phase" = merged ]; then
      git check-ref-format --branch "$(receipt_value default_branch)" >/dev/null 2>&1 || return 1
      printf '%s\n' "$(receipt_value merge_commit)" | grep -Eq '^[0-9a-f]{40}$' || return 1
    else
      [ -z "$(receipt_value default_branch)" ] || return 1
      [ -z "$(receipt_value merge_commit)" ] || return 1
    fi
  fi
  if [ "$schema" = fm-pr-merge.v4 ]; then
    [ "$(grep -c '^project=' "$PROVENANCE_RECEIPT" 2>/dev/null || true)" -eq 1 ] || return 1
    [ -n "$(receipt_value project)" ] || return 1
    [ -z "$PROJECT" ] || [ "$(receipt_value project)" = "$PROJECT" ] || return 1
  fi
}

done_history_matches_request() {
  "$SCRIPT_DIR/fm-backlog-tsv.sh" "$DATA/backlog.md" "$DATA/done-archive.md" |
    awk -F '\t' -v id="$ID" -v url="$URL" '
      $1 == "done" && $2 == id && $4 == url { found = 1 }
      END { exit(found ? 0 : 1) }
    '
}

write_provenance_receipt() {
  local phase=$1 authorization=$2 prepared_epoch=$3 merged_at=${4:-} merge_commit=${5:-} tmp
  if [ -e "$DATA" ] || [ -L "$DATA" ]; then
    [ -d "$DATA" ] && [ ! -L "$DATA" ] || {
      echo "error: merge provenance data directory is unavailable" >&2
      return 1
    }
  else
    mkdir -p "$DATA" || return 1
  fi
  if [ -e "$PROVENANCE_DIR" ] || [ -L "$PROVENANCE_DIR" ]; then
    [ -d "$PROVENANCE_DIR" ] && [ ! -L "$PROVENANCE_DIR" ] || {
      echo "error: merge provenance directory is unavailable" >&2
      return 1
    }
  else
    mkdir "$PROVENANCE_DIR" || return 1
  fi
  if [ -e "$PROVENANCE_RECEIPT" ] || [ -L "$PROVENANCE_RECEIPT" ]; then
    [ -f "$PROVENANCE_RECEIPT" ] && [ ! -L "$PROVENANCE_RECEIPT" ] || {
      echo "error: merge provenance receipt is unavailable" >&2
      return 1
    }
    receipt_matches_request || {
      echo "error: merge provenance conflicts with this task and PR" >&2
      return 1
    }
  fi
  umask 077
  tmp=$(mktemp "$PROVENANCE_DIR/.$ID.receipt.XXXXXX") || return 1
  {
    printf '%s\n' \
      'schema=fm-pr-merge.v4' \
      "task_id=$ID" \
      "pr=$URL" \
      "repository=$PR_OWNER/$PR_REPO" \
      "project=$PROJECT" \
      "default_branch=$DEFAULT_BRANCH" \
      "merge_commit=$merge_commit" \
      "spawned_at=$CURRENT_SPAWNED_AT" \
      "phase=$phase" \
      "authorization=$authorization" \
      "prepared_epoch=$prepared_epoch" \
      "merged_at=$merged_at"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$PROVENANCE_RECEIPT"
}

AUTHORIZATION=
if [ -e "$PROVENANCE_RECEIPT" ] || [ -L "$PROVENANCE_RECEIPT" ]; then
  if ! receipt_matches_request \
    && [ -n "$CURRENT_SPAWNED_AT" ] \
    && { [ "$(receipt_value schema)" = fm-pr-merge.v1 ] || [ "$(receipt_value schema)" = fm-pr-merge.v2 ] || [ "$(receipt_value schema)" = fm-pr-merge.v3 ] || [ "$(receipt_value schema)" = fm-pr-merge.v4 ]; } \
    && [ "$(receipt_value task_id)" = "$ID" ] \
    && [ "$(receipt_value phase)" = merged ] \
    && printf '%s\n' "$(receipt_value spawned_at)" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    && [ "$(receipt_value spawned_at)" != "$CURRENT_SPAWNED_AT" ]; then
    HISTORY_DIR="$PROVENANCE_DIR/history"
    [ ! -e "$HISTORY_DIR" ] || { [ -d "$HISTORY_DIR" ] && [ ! -L "$HISTORY_DIR" ]; } \
      || { echo "error: merge provenance history is unavailable" >&2; exit 1; }
    mkdir -p "$HISTORY_DIR"
    OLD_SPAWNED_AT=$(receipt_value spawned_at)
    HISTORY_RECEIPT="$HISTORY_DIR/$ID.${OLD_SPAWNED_AT//:/-}.receipt"
    [ ! -e "$HISTORY_RECEIPT" ] || { echo "error: merge provenance history conflicts" >&2; exit 1; }
    mv "$PROVENANCE_RECEIPT" "$HISTORY_RECEIPT"
  fi
fi
if [ -e "$PROVENANCE_RECEIPT" ] || [ -L "$PROVENANCE_RECEIPT" ]; then
  receipt_matches_request || {
    echo "error: merge provenance conflicts with this task and PR" >&2
    exit 1
  }
  CURRENT_SPAWNED_AT=$(receipt_value spawned_at)
  AUTHORIZATION=$(receipt_value authorization)
  if [ "$(receipt_value schema)" = fm-pr-merge.v4 ]; then
    PROJECT=$(receipt_value project)
  elif [ "$(receipt_value phase)" = prepared ] && [ -z "$PROJECT" ]; then
    echo "error: prepared merge provenance has no project checkout identity" >&2
    exit 1
  fi
elif [ -f "$META" ] && [ ! -L "$META" ]; then
  printf '%s\n' "$CURRENT_SPAWNED_AT" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || {
    echo "error: task launch identity is unavailable" >&2
    exit 1
  }
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
  AUTHORIZATION=live-meta
else
  echo "error: task metadata is unavailable and no launch-bound merge receipt exists" >&2
  exit 1
fi
[ -n "$PROJECT" ] || {
  echo "error: project checkout identity is unavailable" >&2
  exit 1
}

PREPARED_EPOCH=$(receipt_value prepared_epoch)
case "$PREPARED_EPOCH" in ''|*[!0-9]*) PREPARED_EPOCH=$(date +%s) ;; esac
DEFAULT_BRANCH=
if [ "$(receipt_value phase)" != merged ]; then
  write_provenance_receipt prepared "$AUTHORIZATION" "$PREPARED_EPOCH"
fi

load_merge_evidence() {
  local merge_confirmed base_ref compare_query compare_status default_query
  MERGE_QUERY=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
    --jq '{merged: .merged, merged_at: .merged_at, merge_commit: .merge_commit_sha, base_ref: .base.ref}' 2>/dev/null) \
    || return 3
  merge_confirmed=$(printf '%s\n' "$MERGE_QUERY" | sed -n 's/^merged: //p' | tail -1)
  case "$merge_confirmed" in
    true) ;;
    false) return 1 ;;
    *) return 3 ;;
  esac
  default_query=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO" \
    --jq '{default_branch: .default_branch}' 2>/dev/null) \
    || return 2
  DEFAULT_BRANCH=$(printf '%s\n' "$default_query" | sed -n 's/^default_branch: \([^[:space:]].*\)$/\1/p' | tail -1)
  git check-ref-format --branch "$DEFAULT_BRANCH" >/dev/null 2>&1 || return 2
  MERGE_COMMIT=$(printf '%s\n' "$MERGE_QUERY" | sed -n 's/^merge_commit: "\([0-9a-f]*\)"$/\1/p' | tail -1)
  base_ref=$(printf '%s\n' "$MERGE_QUERY" | sed -n 's/^base_ref: "\([^"]*\)"$/\1/p' | tail -1)
  printf '%s\n' "$MERGE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || return 2
  [ "$base_ref" = "$DEFAULT_BRANCH" ] || return 2
  compare_query=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/compare/$MERGE_COMMIT...$DEFAULT_BRANCH" \
    --jq '{status: .status}' 2>/dev/null) \
    || return 2
  compare_status=$(printf '%s\n' "$compare_query" | sed -n 's/^status: \([^[:space:]].*\)$/\1/p' | tail -1)
  case "$compare_status" in ahead|identical) ;; *) return 2 ;; esac
  MERGED_AT=$(printf '%s\n' "$MERGE_QUERY" | sed -n 's/^merged_at: "\([^"]*\)"$/\1/p' | tail -1)
  if ! printf '%s\n' "$MERGED_AT" | grep -Eq '^$|^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    MERGED_AT=
  fi
}

load_post_merge_evidence() {
  local attempt
  for attempt in 1 2 3; do
    if load_merge_evidence; then
      return 0
    fi
    [ "$attempt" -eq 3 ] || sleep 1
  done
  return 1
}

github_remote_matches_pr() {
  local remote=$1 remote_url slug
  while IFS= read -r remote_url; do
    case "$remote_url" in
      https://github.com/*) slug=${remote_url#https://github.com/} ;;
      git@github.com:*) slug=${remote_url#git@github.com:} ;;
      ssh://git@github.com/*) slug=${remote_url#ssh://git@github.com/} ;;
      *) continue ;;
    esac
    slug=${slug%.git}
    if [ "${slug,,}" = "${PR_OWNER,,}/${PR_REPO,,}" ]; then
      return 0
    fi
  done < <(git -C "$PROJECT" config --get-all "remote.$remote.url" 2>/dev/null || true)
  return 1
}

sync_local_mirror() {
  local forge_fetch forge_remote forge_tip mirror_after mirror_before mirror_fetch
  local origin_url push_output remote
  local -a forge_remotes=()

  if [ -z "$PROJECT" ]; then
    echo "error: forge merge succeeded, but merge provenance has no project checkout identity" >&2
    return 1
  fi
  if ! git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: forge merge succeeded, but the project checkout is unavailable; local mirror state is unknown" >&2
    return 1
  fi
  origin_url=$(git -C "$PROJECT" config --get remote.origin.url 2>/dev/null) || {
    echo "error: forge merge succeeded, but project origin is unavailable; local mirror state is unknown" >&2
    return 1
  }
  case "$origin_url" in
    /*|./*|../*|~/*|file://*) ;;
    *)
      echo "mirror: not configured; project origin is not a local filesystem mirror"
      return 0
      ;;
  esac

  while IFS= read -r remote; do
    [ -n "$remote" ] && [ "$remote" != origin ] || continue
    if github_remote_matches_pr "$remote"; then
      forge_remotes+=("$remote")
    fi
  done < <(git -C "$PROJECT" remote)
  if [ "${#forge_remotes[@]}" -ne 1 ]; then
    echo "error: forge merge succeeded, but the project has ${#forge_remotes[@]} GitHub remotes matching $PR_OWNER/$PR_REPO; local mirror origin was not updated" >&2
    return 1
  fi
  forge_remote=${forge_remotes[0]}

  if ! forge_fetch=$(git -C "$PROJECT" fetch --no-tags "$forge_remote" \
      "refs/heads/$DEFAULT_BRANCH" 2>&1); then
    echo "error: forge merge succeeded, but $forge_remote/$DEFAULT_BRANCH could not be fetched; local mirror origin was not updated: $forge_fetch" >&2
    return 1
  fi
  forge_tip=$(git -C "$PROJECT" rev-parse FETCH_HEAD)
  if ! git -C "$PROJECT" merge-base --is-ancestor "$MERGE_COMMIT" "$forge_tip"; then
    echo "error: forge merge succeeded, but $forge_remote/$DEFAULT_BRANCH does not contain confirmed commit $MERGE_COMMIT; local mirror origin was not updated" >&2
    return 1
  fi

  if ! mirror_fetch=$(git -C "$PROJECT" fetch --no-tags "$origin_url" \
      "refs/heads/$DEFAULT_BRANCH" 2>&1); then
    echo "error: forge merge succeeded, but local mirror origin refs/heads/$DEFAULT_BRANCH could not be read: $mirror_fetch" >&2
    return 1
  fi
  mirror_before=$(git -C "$PROJECT" rev-parse FETCH_HEAD)
  if [ "$mirror_before" = "$MERGE_COMMIT" ]; then
    echo "mirror: origin refs/heads/$DEFAULT_BRANCH already at $MERGE_COMMIT"
    return 0
  fi
  if git -C "$PROJECT" merge-base --is-ancestor "$mirror_before" "$MERGE_COMMIT"; then
    if push_output=$(git -C "$PROJECT" push --porcelain "$origin_url" \
        "$MERGE_COMMIT:refs/heads/$DEFAULT_BRANCH" 2>&1); then
      echo "mirror: origin refs/heads/$DEFAULT_BRANCH fast-forwarded $mirror_before -> $MERGE_COMMIT"
      return 0
    fi
    if git -C "$PROJECT" fetch --no-tags "$origin_url" "refs/heads/$DEFAULT_BRANCH" >/dev/null 2>&1; then
      mirror_after=$(git -C "$PROJECT" rev-parse FETCH_HEAD)
      if git -C "$PROJECT" merge-base --is-ancestor "$MERGE_COMMIT" "$mirror_after"; then
        echo "mirror: origin refs/heads/$DEFAULT_BRANCH already contains $MERGE_COMMIT at $mirror_after"
        return 0
      fi
    fi
    echo "REFUSED: local mirror origin cannot fast-forward refs/heads/$DEFAULT_BRANCH to $MERGE_COMMIT; forge merge succeeded and the mirror was not forced: $push_output" >&2
    return 1
  fi
  if git -C "$PROJECT" merge-base --is-ancestor "$MERGE_COMMIT" "$mirror_before"; then
    echo "mirror: origin refs/heads/$DEFAULT_BRANCH already contains $MERGE_COMMIT at $mirror_before"
    return 0
  fi
  echo "REFUSED: local mirror origin cannot fast-forward refs/heads/$DEFAULT_BRANCH from $mirror_before to $MERGE_COMMIT because the histories diverged; forge merge succeeded and the mirror was not forced" >&2
  return 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

if load_merge_evidence; then
  :
else
  merge_evidence_rc=$?
  case "$merge_evidence_rc" in
    1)
      if ! CHECK_REPORT=$("$SCRIPT_DIR/fm-pr-checks.sh" "$URL"); then
        echo "error: PR CI check status is unavailable; provenance remains prepared" >&2
        exit 1
      fi
      CHECK_STATE=$(printf '%s\n' "$CHECK_REPORT" | sed -n 's/^check_state: \([^[:space:]][^[:space:]]*\)$/\1/p')
      case "$CHECK_STATE" in
        passing) ;;
        failing|ABSENT)
          printf '%s\n' "$CHECK_REPORT" >&2
          echo "error: PR CI checks are $CHECK_STATE; provenance remains prepared" >&2
          exit 1
          ;;
        *)
          echo "error: PR CI check status is invalid; provenance remains prepared" >&2
          exit 1
          ;;
      esac
      ;;
    2) echo "error: merged PR default-branch evidence is unavailable; provenance remains prepared" >&2; exit 1 ;;
    *) echo "error: forge merge state is unavailable; provenance remains prepared" >&2; exit 1 ;;
  esac
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
  load_post_merge_evidence || {
    echo "error: forge did not confirm the merged PR on its default branch; provenance remains prepared" >&2
    exit 1
  }
fi
sync_local_mirror || exit 1
write_provenance_receipt merged "$AUTHORIZATION" "$PREPARED_EPOCH" "$MERGED_AT" "$MERGE_COMMIT"
if [ -f "$META" ]; then
  if [ -n "$MERGED_AT" ]; then
    fm_task_meta_set_once "$META" merged_at "$MERGED_AT" || {
      echo "error: merged PR succeeded but its forge timestamp could not be recorded" >&2
      exit 1
    }
  fi
  fm_task_meta_set_once "$META" outcome pr-merged || {
    echo "error: merged PR succeeded but its lifecycle outcome could not be recorded" >&2
    exit 1
  }
fi
"$FM_ROOT/bin/fm-effort-store.sh" capture "$ID" --outcome pr-merged >/dev/null || {
  echo "error: merged PR succeeded but its effort record could not be captured" >&2
  exit 1
}
"$SCRIPT_DIR/fm-backlog-integrity.sh" landed "$ID" PR-merge --pr "$URL" || {
  echo "error: merged PR succeeded but the backlog outcome could not be recorded" >&2
  exit 1
}

# The merge has landed. Record that outcome in Linear - Done, plus the pull
# request as an attachment - because this is the last moment the task id and the
# pull request are known together; data/backlog.md prunes Done to the recent few.
# Non-fatal by contract (bin/fm-linear-merge-write.sh always exits 0), and last
# so a merge that failed above never reaches it.
"$SCRIPT_DIR/fm-linear-merge-write.sh" "$ID" "$URL" || true
