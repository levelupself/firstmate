#!/usr/bin/env bash

# shellcheck source=bin/fm-wake-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"

fm_task_meta_lock_acquire() {  # <meta-file>
  local meta=$1 attempt=0
  FM_TASK_META_LOCK_DIR="${meta}.mutation-lock"
  while [ "$attempt" -lt 200 ]; do
    fm_lock_try_acquire "$FM_TASK_META_LOCK_DIR" && return 0
    attempt=$((attempt + 1))
    sleep 0.05
  done
  return 1
}

fm_task_meta_lock_release() {
  [ -n "${FM_TASK_META_LOCK_DIR:-}" ] || return 0
  fm_lock_release "$FM_TASK_META_LOCK_DIR"
  FM_TASK_META_LOCK_DIR=
}
