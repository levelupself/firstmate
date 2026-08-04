#!/usr/bin/env bash
# Source this file from Bash startup to provide one-word `review [task-id]`.
# Example: . /absolute/path/to/firstmate/bin/fm-review-shell.sh

_fm_review_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_fm_review_command="$_fm_review_script_dir/fm-review.sh"
review() {
  "$_fm_review_command" "$@"
}
unset _fm_review_script_dir
