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
  "$ROOT/bin/fm-merge-local.sh" local-publish > "$TMP_ROOT/local-publish.out"

grep -F 'local-merge for local-publish proceeded with no backlog present' \
  "$TMP_ROOT/local-publish.out" >/dev/null \
  || fail "approved landing did not explicitly report the absent backlog"

[ "$(git --git-dir="$mirror" rev-parse main)" = "$landed" ] \
  || fail "approved landing did not update the local bare mirror"
[ "$(git --git-dir="$github" rev-parse main)" = "$landed" ] \
  || fail "approved landing did not update the GitHub remote"
pass "approved landing updates every configured remote whose HEAD names the project default"

git -C "$project" checkout -q -b fm/missing-backlog-row
commit_file "$project" missing-row.txt missing missing
missing_row_head=$(git -C "$project" rev-parse HEAD)
git -C "$project" checkout -q main
cat > "$home/state/missing-backlog-row.meta" <<EOF
project=$project
mode=local-only
spawned_at=2026-09-03T00:00:30Z
EOF
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-merge-local.sh" missing-backlog-row > "$TMP_ROOT/missing-row.out" 2>&1; then
  fail "local landing unexpectedly accepted a missing backlog row"
fi
grep -F 'task missing-backlog-row is absent from the backlog' "$TMP_ROOT/missing-row.out" >/dev/null \
  || fail "local landing refusal did not identify the missing row"
[ "$(git -C "$project" rev-parse main)" != "$missing_row_head" ] \
  || fail "local landing changed main before refusing the missing row"
rm "$home/data/backlog.md"
pass "local landing refuses a missing row before repository mutation"

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

unpublished="$TMP_ROOT/unpublished"
git init -q -b main "$unpublished"
commit_file "$unpublished" baseline.txt baseline baseline
git -C "$unpublished" checkout -q -b fm/no-publication-remote
commit_file "$unpublished" unpublished.txt unpublished unpublished
git -C "$unpublished" checkout -q main
unpublished_before=$(git -C "$unpublished" rev-parse main)
cat > "$home/state/no-publication-remote.meta" <<EOF
project=$unpublished
mode=local-only
spawned_at=2026-09-03T00:02:00Z
EOF

if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-merge-local.sh" no-publication-remote >"$TMP_ROOT/no-publication-remote.out" 2>&1; then
  fail "landing without a publication remote unexpectedly succeeded"
fi
grep -F 'REFUSED: no configured remote advertises main as its default branch' \
  "$TMP_ROOT/no-publication-remote.out" >/dev/null \
  || fail "missing publication remote refusal was not clear"
grep -F 'configured remotes inspected: none' "$TMP_ROOT/no-publication-remote.out" >/dev/null \
  || fail "missing publication remote refusal did not report the inspected set"
[ "$(git -C "$unpublished" rev-parse main)" = "$unpublished_before" ] \
  || fail "missing publication remote refusal changed the local default"
pass "a landing without a discoverable publication remote is refused"

printf '# all fm-merge-local tests passed\n'
