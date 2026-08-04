#!/usr/bin/env bash

fm_task_meta_lock_acquire() {  # <meta-file>
  local meta=$1 attempt=0 owner=
  FM_TASK_META_LOCK_DIR="${meta}.mutation-lock"
  while ! mkdir -- "$FM_TASK_META_LOCK_DIR" 2>/dev/null; do
    if [ -f "$FM_TASK_META_LOCK_DIR/pid" ]; then
      owner=$(cat "$FM_TASK_META_LOCK_DIR/pid" 2>/dev/null || true)
      case "$owner" in
        ''|*[!0-9]*) ;;
        *)
          if ! kill -0 "$owner" 2>/dev/null; then
            rm -f -- "$FM_TASK_META_LOCK_DIR/pid" 2>/dev/null || true
            rmdir -- "$FM_TASK_META_LOCK_DIR" 2>/dev/null || true
            continue
          fi
          ;;
      esac
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 200 ] || return 1
    sleep 0.05
  done
  if ! printf '%s\n' "$$" > "$FM_TASK_META_LOCK_DIR/pid"; then
    rmdir -- "$FM_TASK_META_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
}

fm_task_meta_lock_release() {
  [ -n "${FM_TASK_META_LOCK_DIR:-}" ] || return 0
  rm -f -- "$FM_TASK_META_LOCK_DIR/pid" 2>/dev/null || return 1
  rmdir -- "$FM_TASK_META_LOCK_DIR" 2>/dev/null || return 1
  FM_TASK_META_LOCK_DIR=
}
