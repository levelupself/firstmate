#!/usr/bin/env bash
# Behavioral regressions for bin/fm-backlog-tsv.sh: the recorded link on a Done
# row must survive every trailing annotation tasks-axi writes, because merge
# authorization for a torn-down task keys on that link.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TSV="$ROOT/bin/fm-backlog-tsv.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-tsv)

# Print "<state>\t<id>\t<link>" for one id across the given backlog files.
row_link() {
  local id=$1
  shift
  "$TSV" "$@" | awk -F '\t' -v id="$id" '$2 == id { print $1 "\t" $2 "\t" $4 }'
}

test_done_link_survives_priority_annotation() {
  local home out
  home="$TMP_ROOT/priority"
  mkdir -p "$home"
  cat > "$home/backlog.md" <<'MD'
## In flight

## Queued

## Done
- [x] with-priority - Delivered task https://github.com/example/repo/pull/21 (repo: repo) (kind: ship) (priority: 1) (merged 2026-08-18)
- [x] without-priority - Delivered task https://github.com/example/repo/pull/22 (repo: repo) (kind: ship) (merged 2026-08-18)
MD
  out=$(row_link with-priority "$home/backlog.md")
  [ "$out" = "$(printf 'done\twith-priority\thttps://github.com/example/repo/pull/21')" ] \
    || fail "priority annotation hid the Done link: got '$out'"
  out=$(row_link without-priority "$home/backlog.md")
  [ "$out" = "$(printf 'done\twithout-priority\thttps://github.com/example/repo/pull/22')" ] \
    || fail "plain Done link regressed: got '$out'"
  pass "fm-backlog-tsv keeps the Done link behind a priority annotation"
}

test_archived_done_link_survives_priority_annotation() {
  local home out
  home="$TMP_ROOT/archived-priority"
  mkdir -p "$home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/backlog.md"
  cat > "$home/done-archive.md" <<'MD'
# Done archive

## Archived 2026-08-20
- [x] archived-x1 - Archived task https://github.com/example/repo/pull/23 (repo: repo) (kind: ship) (priority: 0) (merged 2026-08-18)
MD
  out=$(row_link archived-x1 "$home/backlog.md" "$home/done-archive.md")
  [ "$out" = "$(printf 'done\tarchived-x1\thttps://github.com/example/repo/pull/23')" ] \
    || fail "priority annotation hid the archived Done link: got '$out'"
  pass "fm-backlog-tsv keeps an archived Done link behind a priority annotation"
}

test_done_link_survives_priority_annotation
test_archived_done_link_survives_priority_annotation
