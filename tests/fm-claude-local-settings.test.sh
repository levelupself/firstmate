#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-claude-local-settings-tests)
trap 'rm -rf "$TMP_ROOT"' EXIT

git -C "$ROOT" check-ignore -q .claude/settings.local.json || fail ".claude/settings.local.json is not ignored"
if git -C "$ROOT" ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
  fail ".claude/settings.local.json is tracked"
fi

fixture="$TMP_ROOT/settings.local.json"
projects="$TMP_ROOT/armada"
mkdir -p "$projects"
jq -n --arg projects "$projects" '{env:{FM_PROJECTS_OVERRIDE:$projects}}' >"$fixture"
resolved=$(jq -er '.env.FM_PROJECTS_OVERRIDE' "$fixture") || fail "local settings override did not parse"
[ "$resolved" = "$projects" ] || fail "local settings override resolved incorrectly"

printf '%s\n' "ok - Claude local projects override remains untracked and resolves"
