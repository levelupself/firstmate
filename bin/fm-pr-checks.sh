#!/usr/bin/env bash
# Report a GitHub PR's CI checks as exactly one of passing, failing, or ABSENT.
# ABSENT means gh-axi found no registered checks and is never a passing result.
# A pending check is failing for merge-readiness purposes, while skipped checks
# do not prevent an otherwise passing result.
# The forge's mergeable_state is reported beside the check state so an absent
# run caused by a merge conflict remains distinguishable from a repository that
# has no configured CI.
# Usage: fm-pr-checks.sh <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 1 ] || ! fm_pr_url_parse "$1" || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi

PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER

if ! CHECKS_OUTPUT=$(gh-axi pr checks "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO"); then
  echo "error: PR CI checks are unavailable" >&2
  exit 1
fi
if ! MERGEABLE_OUTPUT=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
  --jq '{mergeable_state: .mergeable_state}'); then
  echo "error: PR mergeable state is unavailable" >&2
  exit 1
fi

MERGEABLE_STATE=$(printf '%s\n' "$MERGEABLE_OUTPUT" | sed -n \
  -e 's/^mergeable_state: \([a-z_][a-z_]*\)$/\1/p' \
  -e 's/^mergeable_state: "\([a-z_][a-z_]*\)"$/\1/p')
case "$MERGEABLE_STATE" in
  ''|*$'\n'*)
    echo "error: PR mergeable state response is invalid" >&2
    exit 1
    ;;
esac

CHECK_STATE=
if printf '%s\n' "$CHECKS_OUTPUT" | grep -Eq '^checks: .*no CI checks configured'; then
  CHECK_STATE=ABSENT
else
  SUMMARY=$(printf '%s\n' "$CHECKS_OUTPUT" | sed -n 's/^summary: "\(.*\)"$/\1/p')
  case "$SUMMARY" in
    ''|*$'\n'*)
      echo "error: PR CI check response is invalid" >&2
      exit 1
      ;;
  esac
  FAILED=$(printf '%s\n' "$SUMMARY" | sed -n 's/^[0-9][0-9]* passed, \([0-9][0-9]*\) failed.*$/\1/p')
  PENDING=$(printf '%s\n' "$SUMMARY" | sed -n 's/^.* \([0-9][0-9]*\) pending, [0-9][0-9]* total$/\1/p')
  [ -n "$PENDING" ] || PENDING=0
  case "$FAILED:$PENDING" in
    *[!0-9:]*|:*|*:)
      echo "error: PR CI check summary is invalid" >&2
      exit 1
      ;;
  esac
  if [ "$FAILED" -eq 0 ] && [ "$PENDING" -eq 0 ]; then
    CHECK_STATE=passing
  else
    CHECK_STATE=failing
  fi
fi

printf 'check_state: %s\n' "$CHECK_STATE"
printf 'mergeable_state: %s\n' "$MERGEABLE_STATE"
printf '%s\n' "$CHECKS_OUTPUT"
