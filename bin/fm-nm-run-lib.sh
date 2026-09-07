#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# The legacy head rule, applied by fm_nm_run_matches_worktree below whenever a
# run publishes no branch_sync relationship of its own. 0 if run head $2 matches
# worktree $1's code identity:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# Scalar value of a DIRECT `branch_sync:` child, or a direct child of that
# block's own `pipeline:` child, in captured `axi status` output $1.
# Indentation binds each scalar to its structural owner, so a same-named key
# under a sibling block (`local:`) or nested deeper is never read as if it were
# the published relationship.
fm_nm_branch_sync_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | awk -v key="$2" '
    /^[[:space:]]*branch_sync:[[:space:]]*$/ {
      active = 1
      base = match($0, /[^[:space:]]/) - 1
      next
    }
    active {
      if ($0 !~ /[^[:space:]]/) next
      indent = match($0, /[^[:space:]]/) - 1
      if (indent <= base) exit
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (indent == base + 2) pipeline = (line == "pipeline:")
      owned = (key == "state" && indent == base + 2) || \
              (key == "submitted_head" && pipeline && indent == base + 4)
      if (owned && index(line, key ":") == 1) {
        sub("^" key ":[[:space:]]*", "", line)
        print line
        exit
      }
    }
  '
}

# Exit code reserved for an authoritative ownership rejection (see below).
FM_NM_OWNERSHIP_REJECTED=2

# Does the run described by captured `axi status` output $2 belong to worktree
# $1's code identity? This is the whole attribution decision - callers add only
# the branch precondition and what to do with the answer.
#
# A run that publishes `branch_sync.state: pipeline_owned` is stating its own
# relationship to the branch: `pipeline.submitted_head` is the commit the crew
# handed over, while `pipeline.current_head` is the pipeline's own fix tip,
# which deliberately lives only in the pipeline's worktree until it is pushed
# and therefore cannot be resolved here. That published relationship is the
# authority, so it is decided by exact submitted-head equality alone and no
# weaker rule may overturn it in either direction:
#   0                          submitted head is this worktree's HEAD
#   FM_NM_OWNERSHIP_REJECTED   published relationship does NOT bind this
#                              worktree; equality/ancestry fallbacks must not
#                              resurrect it
# With no published relationship the legacy head rule in
# fm_nm_head_matches_worktree decides, returning 0 or 1.
fm_nm_run_matches_worktree() {  # <worktree> <toon-output>
  local wt=$1 out=$2 local_full sync_state submitted_head run_head
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  sync_state=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" state)")
  if [ "$sync_state" = pipeline_owned ]; then
    submitted_head=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" submitted_head)")
    [ "$submitted_head" = "$local_full" ] || return "$FM_NM_OWNERSHIP_REJECTED"
    return 0
  fi
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  fm_nm_head_matches_worktree "$wt" "$run_head"
}
