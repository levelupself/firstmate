#!/usr/bin/env bash
# Behavior tests for the Linear mirror: the backlog parser (fm-backlog-tsv.sh),
# the PR linker (fm-linear-pr-link.sh) and its fm-pr-check.sh hook, and the
# in-place refresh (fm-linear-refresh.sh).
#
# The contract these pin, in priority order:
#   1. Linear NEVER gates delivery. Unconfigured, unreachable, unauthenticated,
#      slow, or simply missing an issue, the PR check still records the PR, arms
#      the merge poll, and exits 0.
#   2. The PR body edit is strictly additive and idempotent.
#   3. Refresh updates matched issues in place, creates only new ids, and only
#      REPORTS ids that left the backlog.
#
# The network is stubbed with a fakebin `curl` that answers per GraphQL
# operation name, so these stay hermetic: no ports, no server, deterministic in
# CI. jq stays the real tool. Live verification against the real Linear API is
# recorded in docs/linear.md.
#
# The single-quoted fixtures below contain literal backticks and GraphQL-shaped
# text, not shell expansions.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
NODE_DIR=$(command -v node 2>/dev/null) && NODE_DIR=$(dirname "$NODE_DIR") || NODE_DIR=
[ -n "$NODE_DIR" ] && BASE_PATH="$NODE_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-linear-tests)

# A fakebin `curl` standing in for Linear's GraphQL endpoint. It extracts the
# operation name from the posted query, writes $FAKE_DIR/<op>.json to the -o
# file, prints $FAKE_DIR/<op>.code (default 200), and appends the operation plus
# its variables to $FAKE_DIR/calls.log. A missing fixture is a 500 with no body,
# which is how "Linear did not answer" is simulated.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile=/dev/null data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    --data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -m|-w|-X|-H) shift 2 ;;
    -s) shift ;;
    *) shift ;;
  esac
done
op=$(printf '%s' "$data" | jq -r '.query' 2>/dev/null \
  | sed -n 's/^[[:space:]]*\(query\|mutation\)[[:space:]]\{1,\}\([A-Za-z0-9_]*\).*/\2/p' | head -n1)
vars=$(printf '%s' "$data" | jq -c '.variables' 2>/dev/null)
printf '%s\t%s\n' "$op" "$vars" >> "$FAKE_DIR/calls.log"
if [ -n "${FAKE_CURL_FAIL:-}" ]; then exit 7; fi
if [ -n "${FAKE_CURL_SLEEP:-}" ]; then sleep "$FAKE_CURL_SLEEP"; fi
after=$(printf '%s' "$vars" | jq -r '.after // empty' 2>/dev/null)
fixture=$FAKE_DIR/$op
[ -z "$after" ] || [ ! -f "$FAKE_DIR/$op-$after.json" ] || fixture=$FAKE_DIR/$op-$after
if [ -f "$fixture.json" ]; then
  cat "$fixture.json" > "$ofile"
  if [ -f "$FAKE_DIR/$op.code" ]; then cat "$FAKE_DIR/$op.code"; else echo 200; fi
else
  : > "$ofile"
  echo 500
fi
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# A fakebin `gh` that serves a PR body from $FAKE_DIR/pr-body and records an
# edit by overwriting that file, so a second run sees the first run's result -
# which is what makes the idempotency test real rather than assumed.
make_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/gh.log"
case "${1:-} ${2:-}" in
  "pr view")
    [ -z "${FAKE_GH_VIEW_FAIL:-}" ] || { echo "gh: pr view refused" >&2; exit 1; }
    cat "$FAKE_DIR/pr-body"
    ;;
  "pr edit")
    [ -z "${FAKE_GH_EDIT_FAIL:-}" ] || { echo "gh: pr edit refused" >&2; exit 1; }
    while [ $# -gt 0 ]; do
      case "$1" in --body-file) cp "$2" "$FAKE_DIR/pr-body"; shift 2 ;; *) shift ;; esac
    done
    ;;
  "pr list")
    [ -z "${FAKE_GH_LIST_FAIL:-}" ] || { echo "gh: pr list refused" >&2; exit 1; }
    cat "$FAKE_DIR/pr-list.json"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
}

# A fakebin `gh-axi` recording every invocation, so a merge that must NOT reach
# Linear is distinguishable from one that must. FAKE_GH_AXI_MERGE_FAIL makes the
# merge itself fail while leaving the recording steps working.
make_fake_gh_axi() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/gh-axi.log"
case "${1:-} ${2:-}" in
  "pr merge")
    [ -z "${FAKE_GH_AXI_MERGE_FAIL:-}" ] || { echo "gh-axi: pr merge refused" >&2; exit 1; }
    ;;
  "api "*)
    printf '%s\n' 'merged: true' 'merged_at: "2026-08-20T12:45:00Z"'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
}

# Set up a home with state/, an .env, and a fresh fake-fixture dir, then export
# the environment the stubs read. It assigns HOME_DIR directly rather than
# printing it, because the exports have to land in the caller's shell.
new_home() {
  local name=$1 fakebin
  HOME_DIR="$TMP_ROOT/$name"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/fake"
  fakebin=$(make_fake_curl "$HOME_DIR")
  make_fake_gh "$fakebin"
  make_fake_gh_axi "$fakebin"
  export FAKE_DIR="$HOME_DIR/fake"
  : > "$FAKE_DIR/calls.log"
  : > "$FAKE_DIR/gh.log"
  : > "$FAKE_DIR/gh-axi.log"
  export PATH="$fakebin:$BASE_PATH"
  unset FAKE_CURL_FAIL FAKE_GH_VIEW_FAIL FAKE_GH_EDIT_FAIL FAKE_GH_LIST_FAIL FAKE_GH_AXI_MERGE_FAIL
}

issue_json() {
  # issue_json <identifier> <description-first-line> [state-type]
  jq -cn --arg ident "$1" --arg desc "$2" --arg st "${3:-backlog}" \
    '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
        {id:"uuid-\($ident)", identifier:$ident, url:"https://linear.app/x/issue/\($ident)",
         title:"t", description:$desc, state:{name:"Backlog", type:$st},
         team:{id:"team-uuid", key:"PSY"}}]}}}'
}

run_link() { "$ROOT/bin/fm-linear-pr-link.sh" "$@" 2>&1; }

# --- 1. inert without a key -------------------------------------------------

new_home inert
: > "$HOME_DIR/.env"
out=$(FM_HOME="$HOME_DIR" run_link demo-a1 https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "unconfigured linker exits 0"
assert_contains "$out" "no LINEAR_API_KEY configured" "unconfigured linker says what did not happen"
[ ! -s "$FAKE_DIR/calls.log" ] || fail "unconfigured linker must not touch the network"
[ ! -s "$FAKE_DIR/gh.log" ] || fail "unconfigured linker must not touch the PR"
pass "no LINEAR_API_KEY: the linker is a hard no-op that exits 0"

# --- 2. no mirrored issue is the normal case, not an error ------------------

new_home nomatch
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'body from the pipeline\n' > "$FAKE_DIR/pr-body"
jq -cn '{data:{issues:{nodes:[]}}}' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 070-unmirrored https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "missing issue exits 0"
assert_contains "$out" "no mirrored issue for 070-unmirrored" "missing issue is reported plainly"
assert_no_grep "pr edit" "$FAKE_DIR/gh.log" "missing issue must not edit the PR"
pass "no mirrored issue: reported, PR untouched, exit 0"

# A rejected server-side filter falls back to a bounded full scan.
# Reaching that bound while Linear still advertises another page is unknown,
# never proof that no mirrored issue exists.
new_home lookupbound
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'body from the pipeline\n' > "$FAKE_DIR/pr-body"
jq -cn '{errors:[{message:"Unknown argument contains"}]}' > "$FAKE_DIR/fmFind.json"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:true,endCursor:"next"},nodes:[]}}}' > "$FAKE_DIR/fmFindAll.json"
out=$(FM_HOME="$HOME_DIR" run_link 070-unmirrored https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "bounded fallback remains non-gating"
assert_contains "$out" "lookup unavailable" "a bounded incomplete scan is reported as unavailable"
n=$(grep -c '^fmFindAll' "$FAKE_DIR/calls.log" || true)
[ "$n" = 50 ] || fail "expected the fallback page bound of 50, got $n"
assert_no_grep "no mirrored issue" <(printf '%s\n' "$out") "an incomplete scan must not claim no issue exists"
pass "lookup fallback reports unavailable when its page bound is reached"

# A successful server-side filter can itself have more than 50 results. The
# lookup must follow its pageInfo rather than treating page one as exhaustive.
new_home filteredpages
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:true,endCursor:"next"},nodes:[]}}}' > "$FAKE_DIR/fmFind.json"
issue_json PSY-70 '`firstmate: 070-beyond-first-page`' > "$FAKE_DIR/fmFind-next.json"
printf 'body from the pipeline\n' > "$FAKE_DIR/pr-body"
out=$(FM_HOME="$HOME_DIR" run_link 070-beyond-first-page https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "filtered lookup follows later pages"
assert_contains "$out" "linked PSY-70" "a filtered result beyond page one is found"
n=$(grep -c '^fmFind' "$FAKE_DIR/calls.log" || true)
[ "$n" = 2 ] || fail "expected two filtered lookup pages, got $n"
pass "filtered lookup searches every advertised page before reporting absence"

# The lookup has one total time budget across the rejected filtered request and
# every fallback page. Expiry is unknown, while a completed scan is absence.
new_home lookupdeadline
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
jq -cn '{errors:[{message:"Unknown argument contains"}]}' > "$FAKE_DIR/fmFind.json"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:true,endCursor:"next"},nodes:[]}}}' > "$FAKE_DIR/fmFindAll.json"
start=$(date +%s)
if ( . "$ROOT/bin/fm-linear-lib.sh"; FM_HOME="$HOME_DIR" fml_load_config; FML_TIMEOUT=2; FAKE_CURL_SLEEP=1 fml_find_issue 070-unmirrored ); then rc=0; else rc=$?; fi
elapsed=$(( $(date +%s) - start ))
expect_code 2 "$rc" "an expired lookup is unavailable"
[ "$elapsed" -le 3 ] || fail "total lookup deadline took ${elapsed}s for a 2s budget"

jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$FAKE_DIR/fmFind.json"
if ( . "$ROOT/bin/fm-linear-lib.sh"; FM_HOME="$HOME_DIR" fml_load_config; FML_TIMEOUT=2; fml_find_issue 070-unmirrored ); then rc=0; else rc=$?; fi
expect_code 1 "$rc" "a completed lookup still reports absence"
pass "lookup fallback shares one deadline and distinguishes expiry from absence"

# --- 3. a mirrored issue gets a strictly additive reference -----------------

new_home match
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf '## Evidence\n\n- review: pass\n- tests: pass\n' > "$FAKE_DIR/pr-body"
cp "$FAKE_DIR/pr-body" "$HOME_DIR/body.before"
issue_json PSY-42 '`firstmate: 010-basic-combat-damage`

body' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "successful link exits 0"
assert_contains "$out" "linked PSY-42" "the link is reported"
assert_contains "$out" "Part of PSY-42" "the appended reference is named"
assert_grep "Part of PSY-42" "$FAKE_DIR/pr-body" "the magic-word line reached the PR body"
assert_grep "<!-- firstmate:linear -->" "$FAKE_DIR/pr-body" "the marker reached the PR body"
before_bytes=$(wc -c < "$HOME_DIR/body.before")
head -c "$before_bytes" "$FAKE_DIR/pr-body" | cmp -s - "$HOME_DIR/body.before" \
  || fail "the edit was not a pure append: the original body bytes changed"
pass "mirrored issue: the reference is appended and the original body survives byte-for-byte"

# --- 4. idempotent: running the check twice links exactly once ---------------

out2=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "second run exits 0"
assert_contains "$out2" "already referenced" "the second run reports it left the body alone"
n=$(grep -c 'Part of PSY-42' "$FAKE_DIR/pr-body")
[ "$n" = 1 ] || fail "expected exactly one reference after two runs, found $n"
n=$(grep -c 'pr edit' "$FAKE_DIR/gh.log")
[ "$n" = 1 ] || fail "expected exactly one PR edit across two runs, found $n"
pass "running the PR check twice adds the reference exactly once"

# A body that merely MENTIONS the identifier is not linked: Linear needs a magic
# word. Treating a bare mention as "already linked" would silently skip exactly
# the PRs that discuss their own issue - this feature's own PR among them.
new_home baremention
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'This PR is described in docs; see PSY-42 for background.\n' > "$FAKE_DIR/pr-body"
issue_json PSY-42 '`firstmate: 010-basic-combat-damage`' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1)
assert_contains "$out" "linked PSY-42" "a bare mention must not be mistaken for an existing link"
assert_grep "Part of PSY-42" "$FAKE_DIR/pr-body" "the reference is still appended over a bare mention"

# A magic word already present IS a link, whoever wrote it, so leave it alone.
printf 'Fixes PSY-42 in passing.\n' > "$FAKE_DIR/pr-body"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1)
assert_contains "$out" "already referenced" "a magic word already in the body counts as linked"
assert_no_grep "Part of PSY-42" "$FAKE_DIR/pr-body" "no second reference is appended"

# The documented list form counts too.
printf 'Fixes ENG-1, DES-5 and PSY-42 together.\n' > "$FAKE_DIR/pr-body"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1)
assert_contains "$out" "already referenced" "a multi-issue magic-word list counts as linked"
pass "only a magic word counts as an existing link; a bare mention does not"

# --- 5. Linear unreachable never blocks anything ----------------------------

new_home unreachable
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'pipeline body\n' > "$FAKE_DIR/pr-body"
out=$(FAKE_CURL_FAIL=1 FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "unreachable Linear still exits 0"
assert_contains "$out" "lookup unavailable" "an unreachable Linear is reported as unavailable"
assert_contains "$out" "PR unaffected" "the operator is told the PR was not touched"
assert_no_grep "pr edit" "$FAKE_DIR/gh.log" "an unreachable Linear must not edit the PR"
pass "Linear unreachable: reported, PR untouched, exit 0"

# An authenticated-but-refusing Linear (HTTP 401) takes the same path.
echo 401 > "$FAKE_DIR/fmFind.code"
jq -cn '{errors:[{message:"Authentication required"}]}' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "unauthenticated Linear still exits 0"
assert_contains "$out" "lookup unavailable" "an unauthenticated Linear is reported as unavailable"
pass "Linear unauthenticated: reported, PR untouched, exit 0"

# A gh that refuses the edit is equally non-fatal.
new_home ghfail
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'pipeline body\n' > "$FAKE_DIR/pr-body"
issue_json PSY-42 '`firstmate: 010-basic-combat-damage`' > "$FAKE_DIR/fmFind.json"
out=$(FAKE_GH_EDIT_FAIL=1 FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1); rc=$?
expect_code 0 "$rc" "a refused PR edit still exits 0"
assert_contains "$out" "could not update the PR body" "a refused edit is reported"
pass "gh refusing the edit: reported, exit 0"

# --- 6. the join is the first line, exactly ---------------------------------

new_home strictjoin
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
printf 'body\n' > "$FAKE_DIR/pr-body"
# The server-side "contains" filter is deliberately loose; the client-side match
# is not. An issue that merely mentions the marker further down is not the join.
issue_json PSY-99 'Some other issue

see also `firstmate: 010-basic-combat-damage`' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 010-basic-combat-damage https://github.com/o/r/pull/1)
assert_contains "$out" "no mirrored issue" "a marker below the first line is not a join"
# A longer id must not be matched by its prefix.
issue_json PSY-98 '`firstmate: 004-engine-surface-testers`' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 004 https://github.com/o/r/pull/1)
assert_contains "$out" "no mirrored issue for 004" "a prefix of a longer id is not a join"
# A plain first line without backticks still joins.
issue_json PSY-97 'firstmate: 004' > "$FAKE_DIR/fmFind.json"
out=$(FM_HOME="$HOME_DIR" run_link 004 https://github.com/o/r/pull/1)
assert_contains "$out" "linked PSY-97" "a backtick-free first line still joins"
pass "the join is the description's first line and an exact id match"

# --- 7. fm-pr-check.sh keeps working regardless -----------------------------

new_home prcheck
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
fm_write_meta "$HOME_DIR/state/t1.meta" "window=fm-t1" "worktree=$HOME_DIR"
out=$(FAKE_CURL_FAIL=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-pr-check.sh" t1 https://github.com/o/r/pull/9 2>&1); rc=$?
expect_code 0 "$rc" "fm-pr-check exits 0 with Linear down"
assert_contains "$out" "armed: state/t1.check.sh" "the merge poll is still armed"
assert_contains "$out" "linear: lookup unavailable" "the Linear outcome is reported to the operator"
assert_grep "pr=https://github.com/o/r/pull/9" "$HOME_DIR/state/t1.meta" "the PR is still recorded in meta"
assert_present "$HOME_DIR/state/t1.check.sh" "the check shim is still written"
pass "fm-pr-check: records the PR and arms the poll even when Linear is down"

out=$(FM_LINEAR_DISABLE=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-pr-check.sh" t1 https://github.com/o/r/pull/9 2>&1)
assert_contains "$out" "disabled by FM_LINEAR_DISABLE" "the kill switch is honoured"
pass "FM_LINEAR_DISABLE turns the Linear step off without touching the rest of the check"

# --- 8. the backlog parser --------------------------------------------------

new_home parse
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] 061-alpha - Do the alpha thing (repo: firstmate) (kind: ship) (since 2026-08-02)
  a note line
  another note line

## Queued
- [ ] 014-axifiable-backlog - Standing list of axify candidates at data/axifiable.md; review when new surface (since 2026-07-31)
- [ ] 016-beta - Wire beta blocked-by: 028-spine (since 2026-07-31) (hold: captain must (really) choose) (hold-kind: captain)

## Done
- [x] 011-gamma - Harden the gamma https://github.com/o/r/pull/38 blocked-by: 028-spine (merged 2026-08-02)
- [x] 060-delta - Scout the delta data/060-delta/report.md (reported 2026-08-02)
MD
cat > "$HOME_DIR/data/done-archive.md" <<'MD'
## Archived 2026-07-31
- [x] 001-ancient - An old shipped thing https://github.com/o/r/pull/2 (merged 2026-07-30)
MD
tsv=$("$ROOT/bin/fm-backlog-tsv.sh" "$HOME_DIR/data/backlog.md" "$HOME_DIR/data/done-archive.md")
printf '%s\n' "$tsv" > "$HOME_DIR/parsed.tsv"
assert_grep "in_flight	061-alpha	Do the alpha thing" "$HOME_DIR/parsed.tsv" "in-flight annotations are stripped from the title"
assert_grep "queued	014-axifiable-backlog	Standing list of axify candidates at data/axifiable.md; review when new surface" \
  "$HOME_DIR/parsed.tsv" "a path inside the sentence survives, only a trailing link is stripped"
assert_grep "done	011-gamma	Harden the gamma	https://github.com/o/r/pull/38	028-spine" \
  "$HOME_DIR/parsed.tsv" "a Done PR URL and its blocked-by are extracted"
assert_grep "done	060-delta	Scout the delta	data/060-delta/report.md" \
  "$HOME_DIR/parsed.tsv" "a scout report path is extracted"
assert_grep "done	001-ancient" "$HOME_DIR/parsed.tsv" "the pruned archive is read too"
assert_grep "queued	016-beta	Wire beta" "$HOME_DIR/parsed.tsv" "a hold reason containing parentheses is cut whole"
[ "$(printf '%s\n' "$tsv" | wc -l)" = 6 ] || fail "expected 6 parsed items, got $(printf '%s\n' "$tsv" | wc -l)"
[ "$(printf '%s\n' "$tsv" | awk -F'\t' '$2=="061-alpha"{print $6}')" = 'a note line\nanother note line' ] \
  || fail "the indented note block was not captured with escaped newlines"
pass "the backlog parser reads every item form, both files, and strips only trailing bookkeeping"

# --- 9. refresh updates in place ---------------------------------------------

new_home refresh
printf 'LINEAR_API_KEY=lin_api_test\nLINEAR_TEAM_KEY=PSY\n' > "$HOME_DIR/.env"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## Queued
- [ ] 010-known - Known and already mirrored (repo: p) blocked-by: 028-spine
- [ ] 099-brandnew - Never mirrored before (repo: p)

## Done
- [x] 011-shipped - Shipped thing https://github.com/o/r/pull/38 (merged 2026-08-02)
MD
: > "$HOME_DIR/data/done-archive.md"
# Linear already holds 010-known (with a stale title), 011-shipped (still open),
# and 555-retired, which has left the backlog.
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"u1",identifier:"PSY-7",url:"l/7",title:"stale title",description:"`firstmate: 010-known`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}},
  {id:"u2",identifier:"PSY-8",url:"l/8",title:"Shipped thing",description:"`firstmate: 011-shipped`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}},
  {id:"u3",identifier:"PSY-9",url:"l/9",title:"gone",description:"`firstmate: 555-retired`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}}]}}}' > "$FAKE_DIR/fmList.json"
jq -cn '{data:{teams:{nodes:[{id:"team-uuid",key:"PSY",states:{nodes:[
  {id:"s-backlog",name:"Backlog",type:"backlog",position:0},
  {id:"s-done",name:"Done",type:"completed",position:3}]}}]}}}' > "$FAKE_DIR/fmTeam.json"
jq -cn '{data:{issueUpdate:{success:true}}}' > "$FAKE_DIR/fmUpdate.json"
jq -cn '{data:{issueUpdate:{success:true}}}' > "$FAKE_DIR/fmState.json"
jq -cn '{data:{attachmentLinkURL:{success:true}}}' > "$FAKE_DIR/fmAttach.json"
jq -cn '{data:{issueCreate:{success:true,issue:{id:"u-new",identifier:"PSY-50"}}}}' > "$FAKE_DIR/fmCreate.json"

out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 0 "$rc" "refresh exits 0"
assert_contains "$out" "created 1, updated 2" "one create for the new id, updates for the two matched ids"
assert_contains "$out" "moved to Done 1" "the shipped item is transitioned"
assert_contains "$out" "PR links 1" "the shipped item carries its PR"
assert_contains "$out" "REPORTED ONLY, nothing was deleted" "retired ids are reported, not deleted"
assert_contains "$out" "555-retired" "the retired id is named"
n=$(grep -c '^fmCreate' "$FAKE_DIR/calls.log")
[ "$n" = 1 ] || fail "expected exactly 1 create, got $n"
grep -q '^fmCreate.*099-brandnew' "$FAKE_DIR/calls.log" || fail "the create was not for the genuinely new id"
# 010-known has a blocked-by but NO link: an empty middle TSV column must not
# shift later fields left. If it did, the body would land in "Blocked by" and
# the blocker id in "Delivered", silently corrupting a real issue.
sent=$(grep '^fmUpdate' "$FAKE_DIR/calls.log" | cut -f2 | jq -r 'select(.d | test("010-known")) | .d')
assert_contains "$sent" "**Blocked by:** 028-spine" "the blocked-by lands in the Blocked by line"
assert_not_contains "$sent" "**Delivered:**" "an item with no recorded link gets no Delivered line"
grep -q "555-retired" "$FAKE_DIR/gh.log" 2>/dev/null && fail "a retired id must never trigger an action"
pass "refresh: updates matched issues in place, creates only new ids, reports retired ids"

# Running it again against a Linear that now reflects the first run must be a
# no-op: this is the property that stops a second refresh doubling the board.
# The second fixture is built from the titles and descriptions the FIRST run
# actually sent, so this is a real feedback loop rather than a hand-written
# guess at what convergence looks like.
jq -s --slurpfile ids <(jq -cn '[{k:"010-known",i:"u1",d:"PSY-7"},{k:"011-shipped",i:"u2",d:"PSY-8"},{k:"099-brandnew",i:"u-new",d:"PSY-50"}]') '
  [ .[] | select(.ti and .d) ] as $sent
  | {data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},
      nodes:[ $sent[] as $s
        | ($s.d | split("\n")[0] | gsub("`"; "") | ltrimstr("firstmate: ")) as $key
        | ($ids[0][] | select(.k == $key)) as $m
        | {id:$m.i, identifier:$m.d, url:"l", title:$s.ti, description:$s.d,
           state:{name:(if $key == "011-shipped" then "Done" else "Backlog" end),
                  type:(if $key == "011-shipped" then "completed" else "backlog" end)},
           team:{id:"team-uuid", key:"PSY"},
           attachments:{nodes:(if $key == "011-shipped" then [{url:"https://github.com/o/r/pull/38"}] else [] end)}} ]}}}' \
  <(grep -E '^fm(Update|Create)' "$FAKE_DIR/calls.log" | cut -f2 | jq -c '.') \
  > "$FAKE_DIR/fmList.json"
: > "$FAKE_DIR/calls.log"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1)
assert_contains "$out" "created 0, updated 0, unchanged 3" "a converged refresh changes nothing"
n=$(grep -c '^fmCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a converged refresh must not create anything, got $n creates"
n=$(grep -c '^fmUpdate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a converged refresh must not update anything, got $n updates"
n=$(grep -c '^fmAttach\|^fmAttachCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a converged refresh must not attach anything, got $n attachment calls"
pass "refresh is convergent: a second run against its own result performs no mutations"

jq '.data.issues.nodes |= map(if .identifier == "PSY-8" then .attachments.nodes = [] else . end)' \
  "$FAKE_DIR/fmList.json" > "$HOME_DIR/list-without-attachment.json"
mv "$HOME_DIR/list-without-attachment.json" "$FAKE_DIR/fmList.json"
: > "$FAKE_DIR/calls.log"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 0 "$rc" "attachment retry exits 0"
assert_contains "$out" "unchanged 2" "only fully converged issues remain unchanged"
assert_contains "$out" "PR links 1" "the missing PR attachment is reconciled"
n=$(grep -c '^fmAttach' "$FAKE_DIR/calls.log" || true)
[ "$n" = 1 ] || fail "expected exactly one attachment retry, got $n"
n=$(grep -c '^fmUpdate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "an attachment retry must not rewrite issue content"
pass "refresh retries a missing attachment after content has converged"

new_home refreshdrydone
printf 'LINEAR_API_KEY=lin_api_test\nLINEAR_TEAM_KEY=PSY\n' > "$HOME_DIR/.env"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## Done
- [x] 012-newly-done - Newly finished https://github.com/o/r/pull/41 (merged 2026-08-02)
MD
: > "$HOME_DIR/data/done-archive.md"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$FAKE_DIR/fmList.json"
jq -cn '{data:{teams:{nodes:[{id:"team-uuid",key:"PSY",states:{nodes:[
  {id:"s-done",name:"Done",type:"completed",position:3}]}}]}}}' > "$FAKE_DIR/fmTeam.json"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" --dry-run 2>&1); rc=$?
expect_code 0 "$rc" "new done dry run exits 0"
assert_contains "$out" "create    012-newly-done" "dry run reports the create"
assert_contains "$out" "->done" "dry run reports the Done transition"
assert_contains "$out" "PR links 1" "dry run reports the PR attachment"
[ ! -s "$FAKE_DIR/calls.log" ] || {
  mutations=$(grep -c '^fmCreate\|^fmUpdate\|^fmState\|^fmAttach' "$FAKE_DIR/calls.log" || true)
  [ "$mutations" = 0 ] || fail "dry run issued $mutations mutations"
}
pass "dry run plans create, Done transition, and PR attachment without mutations"

# A successful HTTP/GraphQL exchange can still carry a rejected mutation.
# That item is failed, while later items continue reconciling normally.
new_home refreshreject
printf 'LINEAR_API_KEY=lin_api_test\nLINEAR_TEAM_KEY=PSY\n' > "$HOME_DIR/.env"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## Queued
- [ ] 010-rejected - Linear rejects this update (repo: p)
- [ ] 011-continues - This update must still run (repo: p)
MD
: > "$HOME_DIR/data/done-archive.md"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"u1",identifier:"PSY-7",url:"l/7",title:"stale",description:"`firstmate: 010-rejected`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}},
  {id:"u2",identifier:"PSY-8",url:"l/8",title:"stale",description:"`firstmate: 011-continues`",
   state:{name:"Backlog",type:"backlog"},team:{id:"team-uuid",key:"PSY"}}]}}}' > "$FAKE_DIR/fmList.json"
jq -cn '{data:{teams:{nodes:[{id:"team-uuid",key:"PSY",states:{nodes:[]}}]}}}' > "$FAKE_DIR/fmTeam.json"
jq -cn '{data:{issueUpdate:{success:false}}}' > "$FAKE_DIR/fmUpdate.json"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 4 "$rc" "a rejected mutation makes refresh incomplete"
assert_contains "$out" "FAILED    PSY-7" "a success:false mutation is reported as failed"
assert_contains "$out" "FAILED    PSY-8" "refresh continues after the first rejected mutation"
assert_contains "$out" "updated 0" "rejected mutations are not counted as updates"
assert_contains "$out" "failed 2" "rejected mutations contribute to the failed tally"
n=$(grep -c '^fmUpdate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 2 ] || fail "expected both updates to be attempted after rejection, got $n"
pass "refresh treats success:false as failure and continues remaining items"

# --- 10. refresh degrades quietly -------------------------------------------

new_home refreshbound
printf 'LINEAR_API_KEY=lin_api_test\nLINEAR_TEAM_KEY=PSY\n' > "$HOME_DIR/.env"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## Queued
- [ ] 099-brandnew - Must not be created from an incomplete listing (repo: p)
MD
: > "$HOME_DIR/data/done-archive.md"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:true,endCursor:"next"},nodes:[]}}}' > "$FAKE_DIR/fmList.json"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" --dry-run 2>&1); rc=$?
expect_code 3 "$rc" "a bounded incomplete listing is unavailable"
assert_contains "$out" "refresh did not run" "a bounded incomplete listing aborts refresh"
n=$(grep -c '^fmCreate\|^fmUpdate\|^fmState\|^fmAttach' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "an incomplete listing issued $n mutations"
pass "refresh aborts without mutations when listing pagination reaches its bound"

new_home refreshdown
: > "$HOME_DIR/.env"
mkdir -p "$HOME_DIR/data"; printf '# Backlog\n' > "$HOME_DIR/data/backlog.md"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 0 "$rc" "unconfigured refresh exits 0"
assert_contains "$out" "refresh did not run" "unconfigured refresh says what did not happen"

printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
out=$(FAKE_CURL_FAIL=1 FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-refresh.sh" 2>&1); rc=$?
expect_code 3 "$rc" "unreachable refresh reports a distinct exit code"
assert_contains "$out" "refresh did not run" "unreachable refresh says what did not happen"
pass "refresh degrades quietly when Linear is unconfigured or unreachable"

# --- 11. the merge writes the outcome to Linear ------------------------------
#
# THE MERGE is the one moment where the task id, the pull request, and a live
# backlog entry all exist together, so it is where the shipped outcome is
# recorded. Everything below still obeys rule 1: Linear never gates a merge.

# A home wired for fm-pr-merge.sh: task meta, a mirrored issue, a team whose
# states include Done, and successful mutation fixtures.
new_merge_home() {
  new_home "$1"
  printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
  printf 'pipeline body\n' > "$FAKE_DIR/pr-body"
  fm_write_meta "$HOME_DIR/state/t1.meta" "window=fm-t1" "worktree=$HOME_DIR" \
    "spawned_at=2026-08-20T12:00:00Z"
  jq -cn --arg st "${2:-backlog}" --argjson att "${3:-[]}" \
    '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
      {id:"uuid-42",identifier:"PSY-42",url:"https://linear.app/x/issue/PSY-42",
       title:"t",description:"`firstmate: t1`",
       state:{name:(if $st=="completed" then "Done" else "Backlog" end),type:$st},
       team:{id:"team-uuid",key:"PSY"},
       attachments:{nodes:$att}}]}}}' > "$FAKE_DIR/fmFind.json"
  jq -cn '{data:{team:{id:"team-uuid",key:"PSY",states:{nodes:[
    {id:"s-backlog",name:"Backlog",type:"backlog",position:0},
    {id:"s-done",name:"Done",type:"completed",position:3}]}}}}' > "$FAKE_DIR/fmTeamById.json"
  jq -cn '{data:{issueUpdate:{success:true}}}' > "$FAKE_DIR/fmState.json"
  jq -cn '{data:{attachmentLinkURL:{success:true}}}' > "$FAKE_DIR/fmAttach.json"
}

run_merge() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_NO_MISTAKES_STATE_DB_OVERRIDE="$HOME_DIR/no-mistakes-state.sqlite" \
    "$ROOT/bin/fm-pr-merge.sh" "$@" 2>&1
}

new_merge_home mergewrite
out=$(run_merge t1 https://github.com/o/r/pull/38); rc=$?
expect_code 0 "$rc" "a merge that writes to Linear still exits 0"
grep -qxF 'pr merge 38 --repo o/r --squash' "$FAKE_DIR/gh-axi.log" \
  || fail "the merge itself did not happen"
grep -q '^fmState' "$FAKE_DIR/calls.log" || fail "the merge did not move the issue to Done"
sent=$(grep '^fmState' "$FAKE_DIR/calls.log" | cut -f2)
assert_contains "$sent" '"s-done"' "the Done transition did not target the team's completed status"
assert_contains "$sent" '"uuid-42"' "the Done transition did not target the mirrored issue"
grep -q '^fmAttach' "$FAKE_DIR/calls.log" || fail "the merge did not attach the pull request"
sent=$(grep '^fmAttach' "$FAKE_DIR/calls.log" | cut -f2)
assert_contains "$sent" 'https://github.com/o/r/pull/38' "the attached URL is not the merged pull request"
assert_contains "$out" "PSY-42" "the operator is told which issue was recorded"
pass "a merge records the mirrored issue as Done with its pull request attached"

# Ordering matters: nothing is written to Linear for a merge that did not happen.
new_merge_home mergewritefails
out=$(FAKE_GH_AXI_MERGE_FAIL=1 run_merge t1 https://github.com/o/r/pull/39); rc=$?
[ "$rc" != 0 ] || fail "a failed merge must not report success"
n=$(grep -c '^fmState\|^fmAttach' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a failed merge wrote $n mutations to Linear"
pass "a merge that failed writes nothing to Linear"

# Rule 1 again: Linear being down cannot fail a merge.
new_merge_home mergewritedown
out=$(FAKE_CURL_FAIL=1 run_merge t1 https://github.com/o/r/pull/40); rc=$?
expect_code 0 "$rc" "an unreachable Linear must not fail the merge"
grep -qxF 'pr merge 40 --repo o/r --squash' "$FAKE_DIR/gh-axi.log" \
  || fail "an unreachable Linear stopped the merge"
assert_contains "$out" "merge unaffected" "the operator is told the merge was not affected"
pass "Linear unreachable at merge time: reported, merge unaffected, exit 0"

new_merge_home mergewriteinert
: > "$HOME_DIR/.env"
out=$(run_merge t1 https://github.com/o/r/pull/44); rc=$?
expect_code 0 "$rc" "an unconfigured Linear must not fail the merge"
grep -qxF 'pr merge 44 --repo o/r --squash' "$FAKE_DIR/gh-axi.log" \
  || fail "an unconfigured Linear stopped the merge"
n=$(grep -c '^fmState\|^fmAttach' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "an unconfigured Linear issued $n mutations"
[ ! -s "$FAKE_DIR/calls.log" ] || fail "an unconfigured Linear must not touch the network at all"
# The absent credential is a first-class path, not an edge case: the operator
# who reads this output must be able to tell "Linear was not configured, so
# nothing was recorded" apart from "the outcome was recorded". A silent no-op
# reads as success and would hide a missing key indefinitely.
assert_contains "$out" "no LINEAR_API_KEY configured" "an unconfigured merge write does not name the missing credential"
assert_contains "$out" "nothing recorded" "an unconfigured merge write does not say that nothing was recorded"
pass "no LINEAR_API_KEY at merge time: the merge proceeds and the skipped write is reported, not silent"

# Re-merging (or a retried merge) must not re-transition a Done issue or stack a
# second copy of the same attachment.
new_merge_home mergewriteidem completed '[{"url":"https://github.com/o/r/pull/45"}]'
out=$(run_merge t1 https://github.com/o/r/pull/45); rc=$?
expect_code 0 "$rc" "a converged merge write exits 0"
n=$(grep -c '^fmState' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "an already-Done issue was transitioned again ($n times)"
n=$(grep -c '^fmAttach' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "an already-attached pull request was attached again ($n times)"
pass "merge write is idempotent: an already-Done, already-attached issue is left alone"

new_home attachambiguous
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
if ( . "$ROOT/bin/fm-linear-lib.sh"; FM_HOME="$HOME_DIR" fml_load_config; FAKE_CURL_FAIL=1 \
  fml_attach_url uuid-42 https://github.com/o/r/pull/46 'Pull request' "$HOME_DIR/attach.json" ); then
  rc=0
else
  rc=$?
fi
[ "$rc" -ne 0 ] || fail "an ambiguous attachment failure unexpectedly succeeded"
n=$(grep -c '^fmAttachCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "an ambiguous attachment failure attempted the legacy mutation"
pass "an ambiguous attachment failure never retries with a non-idempotent mutation"

new_home attachlegacy
printf 'LINEAR_API_KEY=lin_api_test\n' > "$HOME_DIR/.env"
jq -cn '{errors:[{message:"Cannot query field \"attachmentLinkURL\" on type \"Mutation\"."}]}' \
  > "$FAKE_DIR/fmAttach.json"
jq -cn '{data:{attachmentCreate:{success:true}}}' > "$FAKE_DIR/fmAttachCreate.json"
if ( . "$ROOT/bin/fm-linear-lib.sh"; FM_HOME="$HOME_DIR" fml_load_config; \
  fml_attach_url uuid-42 https://github.com/o/r/pull/47 'Pull request' "$HOME_DIR/attach.json" ); then
  rc=0
else
  rc=$?
fi
expect_code 0 "$rc" "a definitive missing-field response uses the legacy attachment mutation"
n=$(grep -c '^fmAttachCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 1 ] || fail "a definitive missing-field response did not attempt the legacy mutation once"

: > "$FAKE_DIR/calls.log"
jq -cn '{errors:[{message:"Cannot query field \"attachmentLinkURL\" on type \"Mutation\". Did you mean \"attachmentCreate\"?"}]}' \
  > "$FAKE_DIR/fmAttach.json"
if ( . "$ROOT/bin/fm-linear-lib.sh"; FM_HOME="$HOME_DIR" fml_load_config; \
  fml_attach_url uuid-42 https://github.com/o/r/pull/48 'Pull request' "$HOME_DIR/attach.json" ); then
  rc=0
else
  rc=$?
fi
expect_code 0 "$rc" "a suggestion-bearing missing-field response uses the legacy attachment mutation"
n=$(grep -c '^fmAttachCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 1 ] || fail "a suggestion-bearing missing-field response did not attempt the legacy mutation once"
pass "only a definitive schema rejection enables the legacy attachment mutation"

# --- 12. importing already-merged pull requests ------------------------------
#
# GitHub is the only complete record of what shipped. The mapping is derived
# from the branch name firstmate itself created (fm/<task-id>), never by
# proximity in the backlog archive - that approach cross-assigned on 2026-08-03.
# Numbered and legacy psychogenesis task branches are exact mappings. Anything
# else the branch cannot prove is REPORTED, never guessed.

new_import_home() {
  new_home "$1"
  printf 'LINEAR_API_KEY=lin_api_test\nLINEAR_TEAM_KEY=PSY\n' > "$HOME_DIR/.env"
  jq -cn '{data:{teams:{nodes:[{id:"team-uuid",key:"PSY",states:{nodes:[
    {id:"s-backlog",name:"Backlog",type:"backlog",position:0},
    {id:"s-done",name:"Done",type:"completed",position:3}]}}]}}}' > "$FAKE_DIR/fmTeam.json"
  jq -cn '{data:{issueUpdate:{success:true}}}' > "$FAKE_DIR/fmState.json"
  jq -cn '{data:{attachmentLinkURL:{success:true}}}' > "$FAKE_DIR/fmAttach.json"
  jq -cn '{data:{issueCreate:{success:true,issue:{id:"u-new",identifier:"PSY-50"}}}}' > "$FAKE_DIR/fmCreate.json"
}

run_import() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-linear-import-prs.sh" "$@" 2>&1; }

new_import_home import
jq -cn '[
  {number:38,url:"https://github.com/o/r/pull/38",title:"feat: known thing",
   headRefName:"fm/010-known",mergedAt:"2026-08-02T00:00:00Z"},
  {number:27,url:"https://github.com/o/r/pull/27",title:"fix: legacy thing",
   headRefName:"fm/psychogen-chatentry-v9",mergedAt:"2026-07-23T00:00:00Z"},
  {number:12,url:"https://github.com/o/r/pull/12",title:"chore: hand-made branch",
   headRefName:"main-patch",mergedAt:"2026-07-01T00:00:00Z"},
  {number:52,url:"https://github.com/o/r/pull/52",title:"chore: missing numeric separator",
   headRefName:"fm/123legacy-task",mergedAt:"2026-08-07T00:00:00Z"},
  {number:53,url:"https://github.com/o/r/pull/53",title:"chore: empty slug",
   headRefName:"fm/123-",mergedAt:"2026-08-07T00:00:00Z"},
  {number:54,url:"https://github.com/o/r/pull/54",title:"chore: bare number",
   headRefName:"fm/123",mergedAt:"2026-08-07T00:00:00Z"}]' > "$FAKE_DIR/pr-list.json"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"uuid-7",identifier:"PSY-7",url:"l/7",title:"Known thing",
   description:"`firstmate: 010-known`",state:{name:"Backlog",type:"backlog"},
   team:{id:"team-uuid",key:"PSY"},attachments:{nodes:[]}}]}}}' > "$FAKE_DIR/fmFind.json"

out=$(run_import --repo levelupself/psychogenesis); rc=$?
expect_code 0 "$rc" "an import that mapped what it could exits 0"
assert_contains "$out" "PSY-7" "the matched issue is named in the audit"
assert_contains "$out" "38" "the audit records which pull request the issue came from"
assert_contains "$out" "fm/010-known" "the audit records how the task id was derived"
grep -q '^fmState' "$FAKE_DIR/calls.log" || fail "the mapped pull request was not recorded as Done"
sent=$(grep '^fmAttach' "$FAKE_DIR/calls.log" | cut -f2)
assert_contains "$sent" "https://github.com/o/r/pull/38" "the mapped pull request was not attached"
# The legacy branch is an exact GitHub-derived mapping and must be imported.
assert_contains "$out" "psychogen-chatentry-v9" "the legacy task id is named in the audit"
sent=$(grep '^fmCreate' "$FAKE_DIR/calls.log" | cut -f2 | jq -r '.d')
assert_contains "$sent" 'firstmate: psychogen-chatentry-v9' "the legacy branch suffix is preserved as the task id"
# Branches outside both supported conventions must be reported and not guessed.
assert_contains "$out" "unmapped" "unmappable pull requests are reported"
assert_contains "$out" "main-patch" "a non-firstmate branch is named rather than guessed"
assert_contains "$out" "fm/123legacy-task" "a branch without a numeric-prefix separator is unmapped"
assert_contains "$out" "fm/123-" "a branch with an empty slug is unmapped"
assert_contains "$out" "fm/123" "a bare numeric branch is unmapped"
n=$(grep -c '^fmState\|^fmAttach\|^fmCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 5 ] || fail "expected exactly 5 mutations for 2 mappable PRs, got $n"
pass "import maps numbered and legacy task branches, and reports everything else instead of guessing"

# The legacy convention proves a mapping only for its authorized repository.
new_import_home importforeignlegacy
jq -cn '[
  {number:27,url:"https://github.com/other/project/pull/27",title:"fix: unrelated legacy thing",
   headRefName:"fm/psychogen-chatentry-v9",mergedAt:"2026-07-23T00:00:00Z"}
]' > "$FAKE_DIR/pr-list.json"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$FAKE_DIR/fmFind.json"
out=$(run_import --repo other/project); rc=$?
expect_code 0 "$rc" "a foreign repository with a legacy-shaped branch exits 0"
assert_contains "$out" "unmapped" "a foreign legacy-shaped branch is reported as unmapped"
assert_contains "$out" "fm/psychogen-chatentry-v9" "the rejected foreign branch is named in the audit"
n=$(grep -c '^fmState\|^fmAttach\|^fmCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a foreign legacy-shaped branch issued $n mutations"
pass "legacy psychogenesis task branches are restricted to their authorized repository"

# A dry run must plan the same thing and change nothing.
new_import_home importdry
cp "$TMP_ROOT/import/fake/pr-list.json" "$FAKE_DIR/pr-list.json"
cp "$TMP_ROOT/import/fake/fmFind.json" "$FAKE_DIR/fmFind.json"
out=$(run_import --repo levelupself/psychogenesis --dry-run); rc=$?
expect_code 0 "$rc" "a dry-run import exits 0"
assert_contains "$out" "PSY-7" "the dry run still reports the mapping it would make"
n=$(grep -c '^fmState\|^fmAttach\|^fmCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a dry-run import issued $n mutations"
pass "a dry-run import plans the mapping without writing to Linear"

# The plan has to be REVIEWABLE before anything reaches a real board, so a dry
# run must show what it would actually write - not just a verdict and an id.
new_import_home importdryplan
jq -cn '[
  {number:38,url:"https://github.com/o/r/pull/38",title:"feat: known thing",
   headRefName:"fm/010-known",mergedAt:"2026-08-02T00:00:00Z"},
  {number:51,url:"https://github.com/o/r/pull/51",title:"feat: area effects",
   headRefName:"fm/010-basic-combat-damage",mergedAt:"2026-08-06T05:49:02Z"}]' > "$FAKE_DIR/pr-list.json"
# 010-known is mirrored and still open; 010-basic-combat-damage is not mirrored
# at all, so one row plans a link and the other plans a create.
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"uuid-7",identifier:"PSY-7",url:"l/7",title:"Known thing",
   description:"`firstmate: 010-known`",state:{name:"Backlog",type:"backlog"},
   team:{id:"team-uuid",key:"PSY"},attachments:{nodes:[]}}]}}}' > "$FAKE_DIR/fmFind.json"
mkdir -p "$HOME_DIR/data"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
# Backlog

## Done
- [x] 010-basic-combat-damage - Add non-targeted area effects (merged 2026-08-06)
MD
: > "$HOME_DIR/data/done-archive.md"

out=$(run_import --repo o/r --dry-run); rc=$?
expect_code 0 "$rc" "a dry-run plan exits 0"
[ -z "${FM_TEST_SHOW_PLAN:-}" ] || { echo "--- dry-run plan ---"; printf '%s\n' "$out"; echo "--- end ---"; }
# What it would CREATE: the title, where that title came from, and the exact
# description including the join line and the pull-request provenance.
assert_contains "$out" "Add non-targeted area effects" "the dry run does not name the title it would create"
assert_contains "$out" "backlog" "the dry run does not say where the title came from"
assert_contains "$out" "firstmate: 010-basic-combat-damage" "the dry run does not show the join line it would write"
assert_contains "$out" "pull request #51" "the dry run does not show the provenance it would record"
printed_description=$(printf '%s\n' "$out" | awk '
  /description it would write:/ { capture=1; next }
  capture && /^        \| / { sub(/^        \| /, ""); print; next }
  capture { exit }
')
expected_description=$(printf '%s\n\n**Delivered:** %s\n\n**Imported from** merged pull request #%s in %s, branch `%s`, merged %s.\n\nThe task id was derived from the branch name, which firstmate created when it dispatched the work.\n' \
  '`firstmate: 010-basic-combat-damage`' \
  'https://github.com/o/r/pull/51' \
  '51' 'o/r' 'fm/010-basic-combat-damage' '2026-08-06T05:49:02Z')
[ "$printed_description" = "$expected_description" ] || fail "the dry-run description differs from the description it would create"
# What it would ATTACH, exactly, for both the created and the linked row.
assert_contains "$out" "https://github.com/o/r/pull/51" "the dry run does not name the URL it would attach to the created issue"
assert_contains "$out" "https://github.com/o/r/pull/38" "the dry run does not name the URL it would attach to the linked issue"
# What it would do to STATUS.
assert_contains "$out" "Done" "the dry run does not say it would move the issue to Done"
# The verdict must read as a plan, not as something already done.
assert_contains "$out" "create    " "the dry run does not label the planned issue as a create"
assert_not_contains "$out" "created   (new)" "a dry run must not report a create as already done"
# And still nothing written.
n=$(grep -c '^fmState\|^fmAttach\|^fmAttachCreate\|^fmCreate' "$FAKE_DIR/calls.log" || true)
[ "$n" = 0 ] || fail "a dry-run plan issued $n mutations"
pass "a dry run prints the title, join line, provenance, attachment URL, and status change it would write"

# A pull request whose issue is already Done and already carries the link must
# plan nothing, so a reviewer can see the import has converged.
new_import_home importdryconverged
jq -cn '[{number:38,url:"https://github.com/o/r/pull/38",title:"feat: known thing",
  headRefName:"fm/010-known",mergedAt:"2026-08-02T00:00:00Z"}]' > "$FAKE_DIR/pr-list.json"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"uuid-7",identifier:"PSY-7",url:"l/7",title:"Known thing",
   description:"`firstmate: 010-known`",state:{name:"Done",type:"completed"},
   team:{id:"team-uuid",key:"PSY"},
   attachments:{nodes:[{url:"https://github.com/o/r/pull/38"}]}}]}}}' > "$FAKE_DIR/fmFind.json"
out=$(run_import --repo o/r --dry-run); rc=$?
expect_code 0 "$rc" "a converged dry run exits 0"
assert_contains "$out" "unchanged" "a converged row is not reported as unchanged"
assert_not_contains "$out" "would attach" "a converged row must not plan an attachment"
assert_not_contains "$out" "would move" "a converged row must not plan a status change"
pass "a dry run plans nothing for a pull request already Done and already attached"

# A completed issue that is missing only its attachment still names the status
# decision explicitly, even though that decision does not require a mutation.
new_import_home importdrycompleted
jq -cn '[{number:38,url:"https://github.com/o/r/pull/38",title:"feat: known thing",
  headRefName:"fm/010-known",mergedAt:"2026-08-02T00:00:00Z"}]' > "$FAKE_DIR/pr-list.json"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  {id:"uuid-7",identifier:"PSY-7",url:"l/7",title:"Known thing",
   description:"`firstmate: 010-known`",state:{name:"Done",type:"completed"},
   team:{id:"team-uuid",key:"PSY"},attachments:{nodes:[]}}]}}}' > "$FAKE_DIR/fmFind.json"
out=$(run_import --repo o/r --dry-run); rc=$?
expect_code 0 "$rc" "a completed-but-unattached dry run exits 0"
assert_contains "$out" "would leave status unchanged because the issue is already completed" "a completed-but-unattached plan omits its unchanged status decision"
assert_contains "$out" "would attach https://github.com/o/r/pull/38" "a completed-but-unattached plan omits its attachment"
pass "a completed-but-unattached dry run names its unchanged status"

# A shipped task id with no mirrored issue is created, carrying the join line
# and the provenance that makes the mapping auditable after the fact.
new_import_home importcreate
jq -cn '[{number:51,url:"https://github.com/o/r/pull/51",title:"feat: area effects",
  headRefName:"fm/010-basic-combat-damage",mergedAt:"2026-08-06T05:49:02Z"}]' > "$FAKE_DIR/pr-list.json"
jq -cn '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}' > "$FAKE_DIR/fmFind.json"
out=$(run_import --repo o/r); rc=$?
expect_code 0 "$rc" "creating a missing issue exits 0"
grep -q '^fmCreate' "$FAKE_DIR/calls.log" || fail "no issue was created for the shipped pull request"
sent=$(grep '^fmCreate' "$FAKE_DIR/calls.log" | cut -f2 | jq -r '.d')
assert_contains "$sent" 'firstmate: 010-basic-combat-damage' "the created issue carries the join line"
assert_contains "$sent" "https://github.com/o/r/pull/51" "the created issue records the pull request it came from"
first=$(printf '%s' "$sent" | head -n1)
assert_contains "$first" "firstmate: 010-basic-combat-damage" "the join must be the FIRST line or it is not a join"
pass "import creates a missing issue with the join line and its pull-request provenance"

printf '\nall linear tests passed\n'
