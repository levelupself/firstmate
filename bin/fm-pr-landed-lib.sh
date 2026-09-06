#!/usr/bin/env bash
# Shared forge landing evidence for merge confirmation and trusted polling.
# Callers supply SCRIPT_DIR and PR_OWNER/PR_REPO/PR_NUMBER for GitHub.
# Success sets MERGE_COMMIT, DEFAULT_BRANCH and MERGED_AT.
# Returns: 0 landed, 1 unmerged, 2 missing ancestry/evidence, 3 lookup failure,
# 4 malformed evidence, 5 merged to a non-default base (wrong-base).
# No retries here: the merge caller owns retries, and the watcher bounds the
# entire poll process group with its existing check timeout.
# fm-pr-evidence.py owns scalar/JSON schema validation.

fm_pr_load_github_landing() {
  local parsed base_ref compare_query compare_status default_query rc
  local -a fields
  MERGE_QUERY=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
    --jq '{merged: .merged, merged_at: .merged_at, merge_commit: .merge_commit_sha, base_ref: .base.ref}' 2>/dev/null) \
    || return 3
  parsed=$(printf '%s\n' "$MERGE_QUERY" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" pr) || return $?
  mapfile -t fields <<< "$parsed"
  [ "${fields[0]}" = true ] || return 1
  MERGE_COMMIT=${fields[1]}
  base_ref=${fields[2]}
  # shellcheck disable=SC2034 # Public result consumed by the merge caller.
  MERGED_AT=${fields[3]:-}
  default_query=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO" \
    --jq '{default_branch: .default_branch}' 2>/dev/null) \
    || return 2
  DEFAULT_BRANCH=$(printf '%s\n' "$default_query" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" repository) || return $?
  [ "$base_ref" = "$DEFAULT_BRANCH" ] || return 5
  compare_query=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/compare/$MERGE_COMMIT...$DEFAULT_BRANCH" \
    --jq '{status: .status}' 2>/dev/null) \
    || return 2
  compare_status=$(printf '%s\n' "$compare_query" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" comparison) || {
    rc=$?
    return "$rc"
  }
  case "$compare_status" in ahead|identical) ;; *) return 2 ;; esac
}


fm_pr_load_gitlab_landing() {  # <host> <project-path> <number>
  local host=$1 project=$2 number=$3 raw parsed base_ref ancestor
  local -a fields
  raw=$(glab mr view "$number" -R "https://$host/$project" --output json 2>/dev/null) || return 3
  parsed=$(printf '%s\n' "$raw" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" gitlab-pr) || return $?
  mapfile -t fields <<< "$parsed"
  [ "${fields[0]}" = true ] || return 1
  MERGE_COMMIT=${fields[1]}
  base_ref=${fields[2]}
  # shellcheck disable=SC2034 # Public result consumed by the merge caller.
  MERGED_AT=${fields[3]:-}
  project=${project//\//%2F}
  raw=$(glab api --hostname "$host" "projects/$project" 2>/dev/null) || return 2
  DEFAULT_BRANCH=$(printf '%s\n' "$raw" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" gitlab-repository) || return $?
  [ "$base_ref" = "$DEFAULT_BRANCH" ] || return 5
  # Query the merge base: equality proves the merged commit is an ancestor of
  # the current default branch (also covers equality with its head).
  local encoded_branch
  encoded_branch=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DEFAULT_BRANCH") || return 2
  raw=$(glab api --hostname "$host" "projects/$project/repository/merge_base?refs[]=$MERGE_COMMIT&refs[]=$encoded_branch" 2>/dev/null) || return 2
  ancestor=$(printf '%s\n' "$raw" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" gitlab-ancestor) || return $?
  [ "$ancestor" = "$MERGE_COMMIT" ] || return 2
}

fm_pr_require_default_base() {  # <provider> <host> <project-path> <number>
  local provider=$1 host=$2 project=$3 number=$4 raw base_ref default_branch
  if [ "$provider" = github ]; then
    raw=$(gh-axi api "/repos/$project/pulls/$number" --jq '{base_ref: .base.ref}' 2>/dev/null) || return 3
    base_ref=$(printf '%s\n' "$raw" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" base) || return $?
    raw=$(gh-axi api "/repos/$project" --jq '{default_branch: .default_branch}' 2>/dev/null) || return 3
    default_branch=$(printf '%s\n' "$raw" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" repository) || return $?
  else
    raw=$(glab mr view "$number" -R "https://$host/$project" --output json 2>/dev/null) || return 3
    base_ref=$(printf '%s\n' "$raw" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" gitlab-base) || return $?
    project=${project//\//%2F}
    raw=$(glab api --hostname "$host" "projects/$project" 2>/dev/null) || return 3
    default_branch=$(printf '%s\n' "$raw" | python3 "$SCRIPT_DIR/fm-pr-evidence.py" gitlab-repository) || return $?
  fi
  if [ "$base_ref" != "$default_branch" ]; then
    printf 'error: wrong-base: PR targets %s; delivery requires default branch %s\n' "$base_ref" "$default_branch" >&2
    return 5
  fi
}
