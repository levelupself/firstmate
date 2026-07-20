# Task usage

Firstmate records codeburn usage automatically for each crewmate and scout cycle.
`bin/fm-spawn.sh` records `spawned_at=` and saves the worktree's pre-launch codeburn totals in `data/<id>/usage-baseline.json`.
`bin/fm-task-usage.sh <id>` queries the same worktree and UTC date window, then subtracts that baseline to exclude previous occupants of a pooled worktree slot.
`bin/fm-teardown.sh` saves the final delta as `data/<id>/usage.json` before deleting volatile task metadata.
The durable snapshot lets `bin/fm-fleet-view.sh` show completed-task usage after worktree return and pool reuse.

The JSON contract is owned by `bin/fm-task-usage.sh` and identified by `fm-task-usage.v1`.
It reports the dispatched harness and configured model from task metadata, actual model names and totals from codeburn, tokens, cost, and call count.
Old metadata without `spawned_at=` or a baseline degrades to a worktree-and-date-scoped total instead of failing.
That fallback can include an earlier same-day occupant, while all newly spawned tasks use baseline subtraction.

Usage collection is best effort.
A missing or unreadable codeburn result never blocks spawn or teardown, and the fleet view marks live usage unavailable.
