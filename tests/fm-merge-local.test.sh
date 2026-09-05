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

# Real Git talks to a controlled receive-pack endpoint. Upload-pack remains
# readable; only the remote's write capability/failure changes between cases.
transport="$TMP_ROOT/transport"
cat > "$transport" <<'EOF'
#!/usr/bin/env bash
set -eu
service=$1 repo=$2 access=$3
printf '%s %s\n' "$service" "$access" >> "$repo.calls"
if [ "$service" = git-receive-pack ]; then
  case "$access" in
    denied)
      echo 'remote: Permission to fixtures/upstream.git denied to fixture-writer.' >&2
      exit 1 ;;
    write-denied)
      echo 'remote: Write access to repository not granted.' >&2
      exit 1 ;;
    unreachable)
      echo 'fatal: unable to access own remote: Could not resolve host: own.invalid' >&2
      exit 1 ;;
    auth-failed)
      echo 'fatal: Authentication failed for own remote' >&2
      exit 1 ;;
    forbidden)
      echo 'fatal: The requested URL returned error: 403' >&2
      exit 1 ;;
  esac
fi
exec "$service" "$repo"
EOF
chmod +x "$transport"

capability_case() {
  local case_id=$1 own_name=$2 other_name=$3 access=$4
  local repo="$TMP_ROOT/$case_id" own="$TMP_ROOT/$case_id-own.git"
  local other="$TMP_ROOT/$case_id-other.git" output="$TMP_ROOT/$case_id.out"
  local base target
  git init -q -b main "$repo"
  git -C "$repo" config protocol.ext.allow always
  commit_file "$repo" baseline.txt baseline baseline
  base=$(git -C "$repo" rev-parse HEAD)
  git clone -q --bare "$repo" "$own"
  git clone -q --bare "$repo" "$other"
  git -C "$repo" remote add "$own_name" "$own"
  git -C "$repo" remote add "$other_name" "ext::$transport %S $other $access"
  git -C "$repo" checkout -q -b "fm/$case_id"
  commit_file "$repo" feature.txt feature feature
  target=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  cat > "$home/state/$case_id.meta" <<EOF
project=$repo
mode=local-only
spawned_at=2026-09-05T00:00:00Z
EOF
  case "$access" in
    denied|write-denied)
      if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
          "$ROOT/bin/fm-merge-local.sh" "$case_id" > "$output" 2>&1; then
        fail "read-only $other_name blocked approved landing: $(cat "$output")"
      fi
      [ "$(git -C "$repo" rev-parse main)" = "$target" ] || fail "fork landing did not move main"
      [ "$(git --git-dir="$own" rev-parse main)" = "$target" ] || fail "own remote was left behind"
      [ "$(git --git-dir="$other" rev-parse main)" = "$base" ] || fail "read-only upstream changed"
      grep -F "excluded remote $other_name: push access denied" "$output" >/dev/null \
        || fail "outcome omitted excluded remote and reason"
      grep -F "published remote $own_name:" "$output" >/dev/null \
        || fail "outcome omitted published remote"
      [ "$(grep -c 'git-receive-pack' "$other.calls")" -eq 1 ] \
        || fail "excluded upstream was not capability-checked exactly once"
      pass "fork lands with writable $own_name and visibly excludes read-only $other_name ($access)"
      ;;
    *)
      if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
          "$ROOT/bin/fm-merge-local.sh" "$case_id" > "$output" 2>&1; then
        fail "$access own remote unexpectedly allowed landing"
      fi
      grep -F "REFUSED: $other_name cannot fast-forward" "$output" >/dev/null \
        || fail "uncertain push failure did not name $other_name: $(cat "$output")"
      case "$access" in
        unreachable) grep -F 'Could not resolve host: own.invalid' "$output" >/dev/null ;;
        auth-failed) grep -F 'Authentication failed' "$output" >/dev/null ;;
        forbidden) grep -F 'returned error: 403' "$output" >/dev/null ;;
      esac || fail "concrete $access failure was hidden"
      [ "$(git -C "$repo" rev-parse main)" = "$base" ] || fail "failed preflight moved main"
      [ "$(git --git-dir="$own" rev-parse main)" = "$base" ] || fail "failed preflight published another remote"
      [ "$(git --git-dir="$other" rev-parse main)" = "$base" ] || fail "failed preflight moved failing remote"
      pass "$access own remote refuses with concrete failure and no branch movement"
      ;;
  esac
}

# Names deliberately contradict conventional origin/fork/upstream assumptions.
capability_case readonly-origin fork origin denied
capability_case readonly-fork origin fork denied
capability_case readonly-arbitrary zebra alpha write-denied
capability_case unreachable-own mirror upstream unreachable
capability_case unauthenticated-own mirror fork auth-failed
capability_case ambiguous-forbidden mirror origin forbidden

printf '# all fm-merge-local tests passed\n' 
