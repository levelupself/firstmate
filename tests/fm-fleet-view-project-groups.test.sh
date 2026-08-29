#!/usr/bin/env bash
# Behavior tests for project grouping and fair truncation in the fleet view.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-view-project-groups)
VIEW_BIN="$TMP_ROOT/bin"
mkdir -p "$VIEW_BIN"
ln -s "$ROOT/bin/fm-fleet-view.sh" "$VIEW_BIN/fm-fleet-view.sh"
ln -s "$ROOT/bin/fm-terminal-frame-lib.sh" "$VIEW_BIN/fm-terminal-frame-lib.sh"

cat > "$VIEW_BIN/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
jq -n '{
  tasks: [
    {id:"psychogenesis-active",project:"/tmp/projects/psychogenesis",
     current_state:{state:"working"},backlog:{repo:"psychogenesis",title:"Active migration",order:1},
     hints:{open_decisions:[]},paths:{report:{present:false}},pr:{url:null}},
    {id:"psychogenesis-active-2",project:"/tmp/projects/psychogenesis",
     current_state:{state:"working"},backlog:{repo:"psychogenesis",title:"Second migration",order:2},
     hints:{open_decisions:[]},paths:{report:{present:false}},pr:{url:null}},
    {id:"psychogenesis-active-3",project:"/tmp/projects/psychogenesis",
     current_state:{state:"working"},backlog:{repo:"psychogenesis",title:"Third migration",order:3},
     hints:{open_decisions:[]},paths:{report:{present:false}},pr:{url:null}}
  ],
  secondmate_landed: {records: []},
  backlog: {records: [
    {id:"firstmate-release-gate",title:"Release gate",repo:"firstmate",state:"queued",structured:true,captain_actionable:true,hold:"approve release"},
    {id:"mtg-quiet-project-only-decision",title:"MTG choice",repo:"mtg",state:"queued",structured:true,captain_actionable:true,hold:"choose the card source"},
    {id:"define-the-type-4-mtg-format-precisely-f-69-decision-alt-cost-rule",title:"Alt cost",repo:"psychogenesis",state:"queued",structured:true,captain_actionable:true,hold:"choose alt costs"},
    {id:"define-the-type-4-mtg-format-precisely-f-69-decision-communal-zone-lifecycle",title:"Zone lifecycle",repo:"psychogenesis",state:"queued",structured:true,captain_actionable:true,hold:"choose zone lifecycle"},
    {id:"define-the-type-4-mtg-format-precisely-f-69-decision-hand-size-and-mulligan",title:"Mulligan",repo:"psychogenesis",state:"queued",structured:true,captain_actionable:true,hold:"choose mulligan"},
    {id:"define-the-type-4-mtg-format-precisely-f-69-decision-infinite-loop-arbitration",title:"Loops",repo:"psychogenesis",state:"queued",structured:true,captain_actionable:true,hold:"choose loop handling"},
    {id:"define-the-type-4-mtg-format-precisely-f-69-decision-optional-house-variants",title:"Variants",repo:"psychogenesis",state:"queued",structured:true,captain_actionable:true,hold:"choose variants"},
    {id:"define-the-type-4-mtg-format-precisely-f-69-decision-planeswalker-conventions",title:"Planeswalkers",repo:"psychogenesis",state:"queued",structured:true,captain_actionable:true,hold:"choose planeswalker rules"},
    {id:"record-without-repository",title:"Route this record",repo:null,state:"queued",structured:true,dispatchable:true,dispatch_clear:true,order:20},
    {id:"mtg-blocked",title:"Blocked import",repo:"mtg",state:"queued",structured:true,blocked:true,unresolved_blocker_ids:["source-data"],blocked_reason:"waiting for source data",order:21}
  ]}
}'
SH
chmod +x "$VIEW_BIN/fm-fleet-snapshot.sh"

view=$(COLUMNS=48 LINES=11 "$VIEW_BIN/fm-fleet-view.sh" --section waiting)
assert_contains "$view" "[Firstmate]" "Firstmate work lacks a compact project group"
assert_contains "$view" "[mtg]" "the quiet project lacks a compact project group"
assert_contains "$view" "[psychogenesis]" "the noisy project lacks a compact project group"
assert_contains "$view" "mtg-quiet-project-only-decision" \
  "a noisy project pushed the quiet project's only decision off the pane"
assert_contains "$view" "alt-cost-rule" \
  "right clipping hid the distinguishing tail of a long shared-prefix id"
assert_contains "$view" "communal-zone-lifecycle" \
  "project-local ordering or clipping hid the second distinguishing id tail"
assert_contains "$view" "+4 hidden" \
  "the noisy project did not report its own hidden-row count"
assert_not_contains "$view" "more rows not shown" \
  "global truncation replaced the required per-project hidden count"

live_view=$(COLUMNS=60 LINES=30 "$VIEW_BIN/fm-fleet-view.sh" --section ready,in-flight,blocked)
assert_contains "$live_view" "[No repository]" \
  "a record with no repository value lacks its stable project group"
assert_contains "$live_view" "[psychogenesis]" \
  "in-flight work lacks the same project grouping as decisions"
assert_contains "$live_view" "[mtg]" \
  "blocked work lacks the same project grouping as decisions"

combined_view=$(COLUMNS=60 LINES=8 "$VIEW_BIN/fm-fleet-view.sh" --section in-flight,blocked)
assert_contains "$combined_view" "psychogenesis-active" \
  "combined-section budgeting hid the in-flight project row"
assert_contains "$combined_view" "mtg-blocked" \
  "combined-section budgeting let in-flight work hide the blocked project row"
pass "narrow fleet decisions group three projects, preserve id tails, and truncate fairly"
