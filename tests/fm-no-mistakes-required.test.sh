#!/usr/bin/env bash
# Behavioral tests for the graph-backed upstream catch-up exemption used by
# .github/workflows/no-mistakes-required.yml.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-no-mistakes-required.sh"
ATTESTATION_CHECK="$ROOT/bin/fm-no-mistakes-attestation.sh"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
fm_git_identity fmtest fmtest@example.invalid

new_graph() {
  local repo="$TMP_ROOT/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  printf 'common\n' > "$repo/common.txt"
  git -C "$repo" add common.txt
  git -C "$repo" commit -qm common

  git -C "$repo" branch upstream
  git -C "$repo" checkout -q upstream
  printf 'upstream\n' > "$repo/upstream.txt"
  git -C "$repo" add upstream.txt
  git -C "$repo" commit -qm 'upstream change'

  git -C "$repo" checkout -q main
  printf 'fork\n' > "$repo/fork.txt"
  git -C "$repo" add fork.txt
  git -C "$repo" commit -qm 'fork change'
  printf '%s\n' "$repo"
}

run_check() {
  local repo=$1 base=$2 head=$3 upstream=$4
  PR_TITLE='Upstream catch-up' \
    PR_BODY='This pull request is an upstream catch-up.' \
    PR_AUTHOR='trusted-maintainer' \
    PR_LABELS='upstream-catch-up,gate-exempt' \
    CATCHUP_EXEMPT='true' \
    "$CHECK" "$repo" "$base" "$head" "$upstream" 2>&1
}

test_accepts_graph_proven_catchup() {
  local repo base head upstream out rc
  repo=$(new_graph accepts)
  upstream=$(git -C "$repo" rev-parse upstream)
  git -C "$repo" checkout -q -b catchup main
  git -C "$repo" merge -q --no-ff upstream -m 'Merge upstream into fork'

  # Model a base advance while the catch-up is under review, followed by the
  # branch merging that current base as PR 58 did.
  git -C "$repo" checkout -q main
  printf 'later base\n' > "$repo/later-base.txt"
  git -C "$repo" add later-base.txt
  git -C "$repo" commit -qm 'later base change'
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q catchup
  git -C "$repo" merge -q --no-ff main -m 'Merge current base into catch-up'
  head=$(git -C "$repo" rev-parse HEAD)

  set +e
  out=$(run_check "$repo" "$base" "$head" "$upstream")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "valid upstream catch-up merge was rejected (rc=$rc): $out"
  assert_contains "$out" 'verified upstream catch-up merge' \
    'valid catch-up reports graph evidence'
  pass 'graph-proven upstream catch-up merge receives the exemption'
}

test_rejects_claim_without_graph_proof() {
  local repo base head upstream out rc
  repo=$(new_graph rejects)
  base=$(git -C "$repo" rev-parse main)
  upstream=$(git -C "$repo" rev-parse upstream)
  git -C "$repo" checkout -q -b claimed-catchup main
  printf 'claim only\n' > "$repo/claim.txt"
  git -C "$repo" add claim.txt
  git -C "$repo" commit -qm 'Upstream catch-up'
  head=$(git -C "$repo" rev-parse HEAD)

  set +e
  out=$(run_check "$repo" "$base" "$head" "$upstream")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'title and body claim received the catch-up exemption'
  assert_contains "$out" 'no qualifying upstream catch-up merge was found' \
    'claim-only pull request fails for missing graph proof'
  pass 'metadata and environment claims cannot substitute for commit-graph proof'
}

test_accepts_matching_pipeline_attestation() {
  local head=0123456789abcdef body incomplete
  body='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0123456789abcdef","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->'
  incomplete='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0123456789abcdef","steps":[{"step":"intent","status":"completed"},{"step":"push","status":"completed"}]} -->'
  printf '%s' "$body" | "$ATTESTATION_CHECK" "$head" \
    || fail 'matching completed pipeline attestation was rejected'
  ! printf '%s' "$body" | "$ATTESTATION_CHECK" deadbeef \
    || fail 'pipeline attestation for a different head was accepted'
  ! printf '%s' "$incomplete" | "$ATTESTATION_CHECK" "$head" \
    || fail 'incomplete pipeline attestation was accepted'
  pass 'pipeline attestation requires the matching head and completed phases'
}

case "${1:-all}" in
  valid)
    test_accepts_graph_proven_catchup
    ;;
  claim)
    test_rejects_claim_without_graph_proof
    ;;
  all)
    test_accepts_graph_proven_catchup
    test_rejects_claim_without_graph_proof
    test_accepts_matching_pipeline_attestation
    ;;
  *)
    fail "unknown test selector: $1"
    ;;
esac
