#!/usr/bin/env bash
set -eu
# shellcheck source=tests/release-copy-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/release-copy-helpers.sh"

for lease_mode in leased legacy; do
  for gap in pool-return ledger-release; do
    setup_case
    printf 'worktree_allocation=reused\n' >> "$meta"
    FM_HOME="$dir/home" "$ROOT/bin/fm-worktree-allocation.sh" acquire member "$dir/proj" "$wt" 2026-10-01T00:00:00Z >/dev/null
    if [ "$lease_mode" = legacy ]; then
      sed -i '/^pool_lease_id=/d' "$meta"
      fm_fake_pool_inventory "$(fm_fake_pool_entry 1 "$wt" available '[]')" > "$dir/fake/status.json"
    fi
    if out=$(FM_FAKE_RETURN_FAIL=1 run_teardown "$dir" member --release-copy); then fail 'failed return succeeded'; fi
    at=2026-10-02T00:00:00Z
    sed -i "s/^teardown_at=.*/teardown_at=$at/" "$meta"
    (cd "$dir/proj" && PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" treehouse return --force "$wt") >/dev/null
    if [ "$gap" = ledger-release ]; then
      FM_HOME="$dir/home" "$ROOT/bin/fm-worktree-allocation.sh" release member "$dir/proj" "$wt" "$at"
    fi
    cp "$dir/fake/status.json" "$dir/returned.pool"
    out=$(run_teardown "$dir" member --release-copy) || fail "$lease_mode $gap recovery failed: $out"
    [ "$(meta_value "$meta" copy_released_at)" = "$at" ] || fail 'release timestamp changed'
    out=$(run_teardown "$dir" member --release-copy) || fail "repeated release failed: $out"
    cmp "$dir/fake/status.json" "$dir/returned.pool" || fail 'retry returned copy again'
    git -C "$dir/proj" merge -q --ff-only fm/member
    out=$(run_teardown "$dir" member) || fail "recovered cleanup failed: $out"
    [ ! -f "$meta" ] || fail 'recovered records survived landing'
    cmp "$dir/fake/status.json" "$dir/returned.pool" || fail 'cleanup returned copy again'
    pass "$lease_mode $gap recovery, repeated release, and landed cleanup"
  done
done
