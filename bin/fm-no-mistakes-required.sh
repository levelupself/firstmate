#!/usr/bin/env bash
# fm-no-mistakes-required.sh - prove an unsigned PR is an upstream catch-up.
#
# Usage:
#   fm-no-mistakes-required.sh <repo> <base-commit> <head-commit> <upstream-commit>
#
# The caller fetches the pull request and configured upstream histories, then
# supplies their server-derived commits.
# This checker reads only the commit graph.
# Titles, bodies, labels, authors, commit messages, and environment claims do
# not participate in the verdict.
set -eu

usage() {
  sed -n '2,9s/^# \{0,1\}//p' "$0" >&2
}

fail() {
  printf 'fm-no-mistakes-required: %s\n' "$*" >&2
  exit 1
}

is_ancestor() {
  git -C "$repo" merge-base --is-ancestor "$1" "$2" 2>/dev/null
}

resolve_commit() {
  git -C "$repo" rev-parse --verify "$1^{commit}" 2>/dev/null
}

[ "$#" -eq 4 ] || {
  usage
  exit 2
}

repo=$1
base_arg=$2
head_arg=$3
upstream_arg=$4

git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "not a git repository: $repo"
base=$(resolve_commit "$base_arg") \
  || fail "base commit is unavailable: $base_arg"
head=$(resolve_commit "$head_arg") \
  || fail "head commit is unavailable: $head_arg"
upstream=$(resolve_commit "$upstream_arg") \
  || fail "upstream commit is unavailable: $upstream_arg"

is_ancestor "$base" "$head" \
  || fail 'pull request head does not contain the current base commit'

candidate=
candidate_upstream_parent=
candidate_count=0
while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  parents=$(git -C "$repo" rev-list --parents -n 1 "$commit")
  # Deliberate word splitting turns "commit parent..." into graph fields.
  # shellcheck disable=SC2086
  set -- $parents
  [ "$#" -eq 3 ] || continue
  first_parent=$2
  second_parent=$3
  if is_ancestor "$first_parent" "$base" &&
    is_ancestor "$second_parent" "$upstream" &&
    ! is_ancestor "$second_parent" "$base"; then
    candidate=$commit
    candidate_upstream_parent=$second_parent
    candidate_count=$((candidate_count + 1))
  fi
done < <(git -C "$repo" rev-list --first-parent "$base..$head")

[ "$candidate_count" -gt 0 ] \
  || fail 'no qualifying upstream catch-up merge was found in the pull request commit graph'
[ "$candidate_count" -eq 1 ] \
  || fail "multiple qualifying upstream catch-up merges were found ($candidate_count)"

# The pull request delta may contain upstream commits, the one catch-up merge,
# and later two-parent merges that bring the current base back into the branch.
# Reject every ordinary authored commit outside those graph-derived sets.
while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  if is_ancestor "$commit" "$upstream" || [ "$commit" = "$candidate" ]; then
    continue
  fi
  if git -C "$repo" rev-list --first-parent "$base..$head" | grep -qxF -- "$commit"; then
    parents=$(git -C "$repo" rev-list --parents -n 1 "$commit")
    # shellcheck disable=SC2086
    set -- $parents
    if [ "$#" -eq 3 ] && is_ancestor "$3" "$base"; then
      continue
    fi
  fi
  fail "pull request contains a non-upstream commit outside the catch-up merge spine: $commit"
done < <(git -C "$repo" rev-list "$base..$head")

printf 'verified upstream catch-up merge %s with upstream parent %s\n' \
  "$candidate" "$candidate_upstream_parent"
