#!/usr/bin/env bash
# Shared terminal-frame painting for the fleet and cockpit watch loops.

fm_terminal_paint_frame() {  # <complete-frame>
  local frame=$1 line painted=$'\033[?2026h\033[H'
  while IFS= read -r line; do
    painted+="$line"$'\033[K\n'
  done <<< "$frame"
  painted+=$'\033[J\033[?2026l'
  printf '%s' "$painted"
}

fm_terminal_watch_reset() {
  printf '\033[?2026l\033[0m\n'
}
