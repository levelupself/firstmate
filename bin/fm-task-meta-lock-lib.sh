#!/usr/bin/env bash

FM_TASK_META_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_task_meta_lock_acquire() {  # <meta-file>
  local meta=$1 attempt=0
  if ! command -v fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_TASK_META_LOCK_LIB_DIR/fm-wake-lib.sh"
  fi
  FM_TASK_META_LOCK_DIR=$(fm_meta_lock_path "$meta") || return 1
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

# fm_task_meta_set_once <meta-file> <key> <value>: atomically add a lifecycle
# fact only when it is absent. Retries preserve the original event time.
fm_task_meta_set_once() {
  local meta=$1 key=$2 value=$3 dir tmp status=0
  case "$key" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) return 2 ;; esac
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  fm_task_meta_lock_acquire "$meta" || return 1
  if grep -q "^${key}=" "$meta" 2>/dev/null; then
    fm_task_meta_lock_release
    return 0
  fi
  dir=$(dirname "$meta")
  tmp=$(mktemp "$dir/.fm-meta-set.XXXXXX") || status=1
  if [ "$status" -eq 0 ]; then
    if ! awk -F= -v key="$key" '$1 != key' "$meta" > "$tmp" \
      || ! printf '%s=%s\n' "$key" "$value" >> "$tmp" \
      || ! chmod 0600 "$tmp" \
      || ! mv -f -- "$tmp" "$meta"; then
      status=1
    fi
  fi
  [ -z "${tmp:-}" ] || [ ! -e "$tmp" ] || rm -f -- "$tmp"
  fm_task_meta_lock_release || status=1
  return "$status"
}
