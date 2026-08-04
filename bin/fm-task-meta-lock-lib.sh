#!/usr/bin/env bash

fm_task_meta_lock_acquire() {  # <meta-file>
  local meta=$1 attempt=0 owner= gate
  FM_TASK_META_LOCK_DIR="${meta}.mutation-lock"
  gate="${FM_TASK_META_LOCK_DIR}.gate"
  while [ "$attempt" -lt 200 ]; do
    if ! mkdir -- "$gate" 2>/dev/null; then
      attempt=$((attempt + 1))
      sleep 0.05
      continue
    fi
    if mkdir -- "$FM_TASK_META_LOCK_DIR" 2>/dev/null; then
      if printf '%s\n' "$$" > "$FM_TASK_META_LOCK_DIR/pid"; then
        rmdir -- "$gate" 2>/dev/null || return 1
        return 0
      fi
      rmdir -- "$FM_TASK_META_LOCK_DIR" 2>/dev/null || true
      rmdir -- "$gate" 2>/dev/null || true
      return 1
    fi
    owner=$(cat "$FM_TASK_META_LOCK_DIR/pid" 2>/dev/null || true)
    case "$owner" in
      ''|*[!0-9]*) ;;
      *)
        if ! kill -0 "$owner" 2>/dev/null; then
          rm -f -- "$FM_TASK_META_LOCK_DIR/pid" 2>/dev/null || true
          rmdir -- "$FM_TASK_META_LOCK_DIR" 2>/dev/null || true
        fi
        ;;
    esac
    rmdir -- "$gate" 2>/dev/null || return 1
    attempt=$((attempt + 1))
    sleep 0.05
  done
  return 1
}

fm_task_meta_lock_release() {
  [ -n "${FM_TASK_META_LOCK_DIR:-}" ] || return 0
  rm -f -- "$FM_TASK_META_LOCK_DIR/pid" 2>/dev/null || return 1
  rmdir -- "$FM_TASK_META_LOCK_DIR" 2>/dev/null || return 1
  FM_TASK_META_LOCK_DIR=
}
