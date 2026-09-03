#!/usr/bin/env bash
# Behavior tests for approved local landing publication.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

commit_file() {
  local repo=$1 file=$2 value=$3 message=$4
  printf '%s\n' "$value" > "$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -q -m "$message"
}

home="$TMP_ROOT/home"
project="$TMP_ROOT/project"
mirror="$TMP_ROOT/mirror.git"
github="$TMP_ROOT/github.git"
mkdir -p "$home/state" "$home/data"
git init -q --bare "$mirror"
git init -q --bare "$github"
git init -q -b main "$project"
commit_file "$project" baseline.txt baseline baseline
git -C "$project" remote add mirror "$mirror"
git -C "$project" remote add github "$github"
git -C "$project" push -q mirror main
git -C "$project" push -q github main
git --git-dir="$mirror" symbolic-ref HEAD refs/heads/main
git --git-dir="$github" symbolic-ref HEAD refs/heads/main
git -C "$project" checkout -q -b fm/local-publish
commit_file "$project" feature.txt published feature
landed=$(git -C "$project" rev-parse HEAD)
git -C "$project" checkout -q main
cat > "$home/state/local-publish.meta" <<EOF
project=$project
mode=local-only
spawned_at=2026-09-03T00:00:00Z
EOF

FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-merge-local.sh" local-publish >/dev/null

[ "$(git --git-dir="$mirror" rev-parse main)" = "$landed" ] \
  || fail "approved landing did not update the local bare mirror"
[ "$(git --git-dir="$github" rev-parse main)" = "$landed" ] \
  || fail "approved landing did not update the GitHub remote"
pass "approved landing updates every configured remote whose HEAD names the project default"

git -C "$project" checkout -q -b fm/refused-publish
commit_file "$project" refused.txt refused refused
git -C "$project" checkout -q main
before=$(git -C "$project" rev-parse main)
competitor="$TMP_ROOT/competitor"
git clone -q "$mirror" "$competitor"
commit_file "$competitor" remote.txt remote remote
git -C "$competitor" push -q origin main
remote_before=$(git --git-dir="$mirror" rev-parse main)
cat > "$home/state/refused-publish.meta" <<EOF
project=$project
mode=local-only
spawned_at=2026-09-03T00:01:00Z
EOF

if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-merge-local.sh" refused-publish >"$TMP_ROOT/refused.out" 2>&1; then
  fail "non-fast-forward remote unexpectedly allowed a local landing"
fi
grep -F 'REFUSED: mirror cannot fast-forward refs/heads/main' "$TMP_ROOT/refused.out" >/dev/null \
  || fail "non-fast-forward refusal did not name the remote and branch"
[ "$(git -C "$project" rev-parse main)" = "$before" ] \
  || fail "refused remote publication still changed the local default"
[ "$(git --git-dir="$mirror" rev-parse main)" = "$remote_before" ] \
  || fail "refused remote publication rewrote the remote"
pass "a non-fast-forward remote stops the landing without force or local movement"

printf '# all fm-merge-local tests passed\n'
