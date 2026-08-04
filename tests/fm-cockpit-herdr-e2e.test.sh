#!/usr/bin/env bash
# Real-Herdr cockpit placement and restart re-adoption in one guarded lab.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name cockpit-e2e)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-cockpit-e2e.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"

cleanup() {
  "$LAB_HELPER" teardown "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the guarded Herdr lab"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
helper=${FM_COCKPIT_LAB_HELPER:?}
session=${FM_COCKPIT_LAB_SESSION:?}
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "${2:-}" = "$session" ] || exit 1
    shift 2
    continue
  fi
  args+=("$1")
  shift
done
"$helper" run "$session" "${args[@]}"
SH
chmod +x "$FAKEBIN/herdr"

WORKSPACE_OUT=$("$LAB_HELPER" run "$SESSION" workspace create \
  --label firstmate --cwd "$HOME_DIR" --no-focus) || fail "could not create the cockpit workspace"
WORKSPACE=$(printf '%s' "$WORKSPACE_OUT" | jq -r '.result.workspace.workspace_id // empty')
TAB=$(printf '%s' "$WORKSPACE_OUT" | jq -r '.result.tab.tab_id // empty')
HEAD=$(printf '%s' "$WORKSPACE_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WORKSPACE" ] && [ -n "$TAB" ] && [ -n "$HEAD" ] || fail "workspace creation returned incomplete ids"

cockpit_env() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_COCKPIT_LAB_HELPER="$LAB_HELPER" \
    FM_COCKPIT_LAB_SESSION="$SESSION" \
    HERDR_ENV=1 \
    HERDR_SESSION="$SESSION" \
    HERDR_WORKSPACE_ID="$WORKSPACE" \
    HERDR_TAB_ID="$TAB" \
    HERDR_PANE_ID="$HEAD" \
    "$@"
}

cockpit_env "$ROOT/bin/fm-cockpit.sh" adopt >/dev/null \
  || fail "could not adopt the real Herdr frame"

place_real() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_COCKPIT_LAB_HELPER="$LAB_HELPER" \
    FM_COCKPIT_LAB_SESSION="$SESSION" \
    HERDR_SESSION="$SESSION" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_cockpit_create_task "$1/state" "$1" "$2" "$1"' \
      "$ROOT" "$HOME_DIR" "$1"
}

FIRST=$(place_real fm-real-one) || fail "first real cockpit placement failed"
SECOND=$(place_real fm-real-two) || fail "second real cockpit placement failed"
read -r FIRST_TAB FIRST_PANE <<EOF
$FIRST
EOF
read -r SECOND_TAB SECOND_PANE <<EOF
$SECOND
EOF
[ "$FIRST_TAB" = "$TAB" ] && [ "$SECOND_TAB" = "$TAB" ] \
  || fail "real cockpit workers did not land in the pinned head tab"
[ "$FIRST_PANE" != "$HEAD" ] && [ "$SECOND_PANE" != "$HEAD" ] && [ "$FIRST_PANE" != "$SECOND_PANE" ] \
  || fail "real cockpit placement returned duplicate pane identities"

PANES_BEFORE=$("$LAB_HELPER" run "$SESSION" pane list --workspace "$WORKSPACE") \
  || fail "could not inspect the real cockpit panes"
printf '%s' "$PANES_BEFORE" | jq -e --arg tab "$TAB" --arg head "$HEAD" --arg one "$FIRST_PANE" --arg two "$SECOND_PANE" '
  [.result.panes[] | select(.tab_id == $tab) | .pane_id] as $ids
  | ($ids | index($head)) != null
    and ($ids | index($one)) != null
    and ($ids | index($two)) != null
' >/dev/null || fail "real cockpit frame did not contain the head and both worker panes"

COUNT_BEFORE=$(printf '%s' "$PANES_BEFORE" | jq '.result.panes | length')
RECORD_BEFORE=$(sha256sum "$HOME_DIR/state/.herdr-cockpit" | awk '{print $1}')
RESTART_OUT=$(cockpit_env "$ROOT/bin/fm-cockpit.sh" adopt) \
  || fail "real cockpit restart re-adoption failed"
PANES_AFTER=$("$LAB_HELPER" run "$SESSION" pane list --workspace "$WORKSPACE") \
  || fail "could not inspect the re-adopted real cockpit"
COUNT_AFTER=$(printf '%s' "$PANES_AFTER" | jq '.result.panes | length')
RECORD_AFTER=$(sha256sum "$HOME_DIR/state/.herdr-cockpit" | awk '{print $1}')
[ "$COUNT_BEFORE" = "$COUNT_AFTER" ] || fail "real re-adoption changed the frame pane count"
[ "$RECORD_BEFORE" = "$RECORD_AFTER" ] || fail "real re-adoption rewrote the frame record"
assert_contains "$RESTART_OUT" "re-adopted Herdr frame" "real restart did not report re-adoption"
pass "real Herdr cockpit keeps one pinned head tab, places workers inside it, and re-adopts without rebuild"
