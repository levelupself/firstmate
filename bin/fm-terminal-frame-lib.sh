#!/usr/bin/env bash
# Shared terminal-frame painting and sizing for the fleet and cockpit watch loops.

# fm_terminal_dimension: one live dimension of the controlling terminal, or a
# non-zero return when it cannot be measured.
#
# Deliberately not gated on `[ -t 1 ]`. Every caller measures inside a command
# substitution, where stdout is a pipe and that test is always false, so such a
# gate reports nothing and the caller silently substitutes a built-in default
# for the pane's real size - which is how an oversized frame ends up scrolling
# its own head off the top of a short pane. Both probes below read the pane's
# own terminal regardless of how stdout is redirected.
fm_terminal_dimension() {  # <lines|cols>
  local name=$1 field value=
  case "$name" in
    lines) field=1 ;;
    cols) field=2 ;;
    *) return 1 ;;
  esac
  if [ -r /dev/tty ]; then
    value=$(stty size 2>/dev/null < /dev/tty | awk -v f="$field" '{print $f}')
  fi
  case "$value" in
    ''|*[!0-9]*) value=$(tput "$name" 2>/dev/null || true) ;;
  esac
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

# fm_terminal_fit_height: bound <frame> to <height> rows, keeping the head and
# truncating the tail with an explicit count of what was dropped.
#
# The head is what the panel orders first on purpose, so overflow has to cost
# the tail. Letting the terminal scroll instead would cost the head, which is
# the opposite of the ordering the panel exists to provide.
fm_terminal_fit_height() {  # <height> <frame> [width]
  local height=$1 frame=$2 width=${3:-} total hidden summary
  total=$(printf '%s\n' "$frame" | awk 'END {print NR}')
  if [ "$total" -le "$height" ]; then
    printf '%s\n' "$frame"
    return 0
  fi
  hidden=$((total - height + 1))
  printf '%s\n' "$frame" | head -n $((height - 1))
  summary="… $hidden more rows not shown"
  if [ -n "$width" ]; then
    printf '%s\n' "$summary" | jq -Rr --argjson width "$width" '
      if length <= $width then .
      elif $width <= 1 then .[:$width]
      else .[:($width - 1)] + "…" end
    '
  else
    printf '%s\n' "$summary"
  fi
}

# Newlines separate rows rather than terminating them. A trailing newline after
# the last row walks the cursor past the bottom of the pane, which scrolls the
# whole frame up by one and silently eats its first line - so a frame sized to
# exactly fill the pane would lose its own top row. The closing erase-to-end
# still clears everything below the final row.
fm_terminal_paint_frame() {  # <complete-frame>
  local frame=$1 line painted=$'\033[?2026h\033[H' first=1
  while IFS= read -r line; do
    [ "$first" = 1 ] || painted+=$'\n'
    first=0
    painted+="$line"$'\033[K'
  done <<< "$frame"
  painted+=$'\033[J\033[?2026l'
  printf '%s' "$painted"
}

fm_terminal_watch_reset() {
  printf '\033[?2026l\033[0m\n'
}
