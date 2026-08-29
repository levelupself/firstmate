#!/usr/bin/env bash
# fm-no-mistakes-attestation.sh - verify a pipeline attestation from stdin.
#
# Usage:
#   fm-no-mistakes-attestation.sh <head-commit>
set -eu

[ "$#" -eq 1 ] || {
  sed -n '2,5s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

jq -Rse --arg head "$1" '
  capture("<!-- no-mistakes-pipeline-attestation:v1 (?<json>[^\\n]+) -->").json
  | fromjson
  | .head_sha == $head and
    ([.steps[] | select(
      (.step == "intent" or .step == "rebase" or .step == "review" or
       .step == "test" or .step == "document" or .step == "lint" or
       .step == "push") and .status == "completed"
    ) | .step] | unique | length == 7)
' >/dev/null
