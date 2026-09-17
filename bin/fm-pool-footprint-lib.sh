#!/usr/bin/env bash
# Ignored-footprint measurement shared by the three pool footprint gates:
# teardown's return post-condition, spawn's pool-acquisition pre-condition, and
# the scheduled sweep's pool-total audit (bin/fm-pool-footprint.sh owns the CLI).
# A copy's footprint is every path `git ls-files --others --ignored
# --exclude-standard --directory -z` reports, summed with `du` without following
# symlinks, so tracked and non-ignored content never counts and a symlinked
# entry counts only as the link itself. Budgets are decimal GB from
# FM_POOL_COPY_BUDGET_GB (default 12) and FM_POOL_TOTAL_BUDGET_GB (default 80);
# docs/configuration.md owns their meaning. Every function fails closed: an
# unmeasurable copy or an invalid budget returns non-zero and prints nothing
# usable, so a caller can never read silence as "under budget".

# fm_pool_footprint_budget_bytes <env-name> <default-gb>: the budget in bytes.
fm_pool_footprint_budget_bytes() {
  local name=$1 default=$2 value
  value=${!name:-$default}
  awk -v g="$value" 'BEGIN {
    if (g !~ /^([0-9]+\.?[0-9]*|\.[0-9]+)$/ || g + 0 <= 0) exit 1
    printf "%.0f\n", g * 1e9
  }' || { echo "error: $name must be a positive decimal GB value, got '$value'" >&2; return 1; }
}

fm_pool_copy_budget_bytes() {
  fm_pool_footprint_budget_bytes FM_POOL_COPY_BUDGET_GB 12
}

fm_pool_total_budget_bytes() {
  fm_pool_footprint_budget_bytes FM_POOL_TOTAL_BUDGET_GB 80
}

# fm_pool_footprint_gb <bytes>: decimal GB with two decimals, for budgets.
fm_pool_footprint_gb() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b / 1e9 }'
}

# fm_pool_footprint_human <bytes>: a decimal size with its natural unit, so a
# refusal over a small fixture or a huge pool reads correctly either way.
fm_pool_footprint_human() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1e9) printf "%.2f GB", b / 1e9
    else if (b >= 1e6) printf "%.1f MB", b / 1e6
    else if (b >= 1e3) printf "%.0f KB", b / 1e3
    else printf "%d B", b
  }'
}

# fm_pool_footprint_entries <copy>: the copy's ignored top-level entries, one
# NUL-delimited relative to the copy, directories collapsed to their root.
fm_pool_footprint_entries() {
  local copy=$1
  [ -d "$copy" ] || return 1
  git -C "$copy" ls-files --others --ignored --exclude-standard --directory -z 2>/dev/null
}

# _fm_pool_footprint_du_sum <copy> <path>...: `du -sk` over the given paths,
# relative to the copy, summed in bytes. Batched so a wide entry list never
# exceeds the argument limit, and a single failing `du` fails the sum.
_fm_pool_footprint_du_sum() {
  local copy=$1 total=0 batch_total output
  shift
  while [ "$#" -gt 0 ]; do
    local -a batch=()
    while [ "$#" -gt 0 ] && [ "${#batch[@]}" -lt 200 ]; do
      batch+=("$1")
      shift
    done
    output=$(cd "$copy" && du -skc -- "${batch[@]}") || return 1
    batch_total=$(printf '%s\n' "$output" | awk 'END { printf "%.0f\n", $1 * 1024 }')
    total=$((total + batch_total))
  done
  printf '%s\n' "$total"
}

# fm_pool_footprint_bytes <copy>: the copy's ignored footprint in bytes.
fm_pool_footprint_bytes() {
  local copy=$1 entry listing_fd listing_pid
  local -a entries=()
  [ -d "$copy" ] || return 1
  git -C "$copy" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  exec {listing_fd}< <(fm_pool_footprint_entries "$copy")
  listing_pid=$!
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    entries+=("${entry%/}")
  done <&"$listing_fd"
  exec {listing_fd}<&-
  wait "$listing_pid" || return 1
  [ "${#entries[@]}" -gt 0 ] || { printf '0\n'; return 0; }
  _fm_pool_footprint_du_sum "$copy" "${entries[@]}"
}

# fm_pool_footprint_report <copy> [<count>]: the largest ignored paths as
# "<bytes>\t<shell-escaped absolute path>" lines, largest first, at most <count> (default 10).
# Each ignored directory is expanded one level so the report names the profile
# or scratch subtree that carries the weight rather than only its root.
fm_pool_footprint_report() {
  local copy=$1 count=${2:-10} entry child listing_fd listing_pid bytes rows='' row
  local -a leaves=()
  [ -d "$copy" ] || return 1
  exec {listing_fd}< <(fm_pool_footprint_entries "$copy")
  listing_pid=$!
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    entry=${entry%/}
    if [ -d "$copy/$entry" ] && [ ! -L "$copy/$entry" ]; then
      for child in "$copy/$entry"/* "$copy/$entry"/.[!.]* "$copy/$entry"/..?*; do
        [ -e "$child" ] || [ -L "$child" ] || continue
        leaves+=("${child#"$copy/"}")
      done
    else
      leaves+=("$entry")
    fi
  done <&"$listing_fd"
  exec {listing_fd}<&-
  wait "$listing_pid" || return 1
  [ "${#leaves[@]}" -gt 0 ] || return 0
  for entry in "${leaves[@]}"; do
    bytes=$(_fm_pool_footprint_du_sum "$copy" "$entry") || return 1
    printf -v row '%s\t%q\n' "$bytes" "$copy/$entry"
    rows+=$row
  done
  printf '%s' "$rows" | LC_ALL=C sort -rn -k1,1 | sed -n "1,${count}p"
}

# fm_pool_footprint_report_lines <copy> [<count>]: the same report rendered
# for humans as "  <size>  <path>" lines.
fm_pool_footprint_report_lines() {
  local bytes p
  fm_pool_footprint_report "$1" "${2:-10}" | while IFS=$'\t' read -r bytes p; do
    printf '  %s  %s\n' "$(fm_pool_footprint_human "$bytes")" "$p"
  done
}
