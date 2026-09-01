# Task usage

Firstmate records codeburn usage automatically for each crewmate and scout cycle.
`bin/fm-spawn.sh` records `spawned_at=` and saves the worktree's pre-launch codeburn totals in `data/<id>/usage-baseline.json`.
Codeburn does not publish a new worktree key until that directory records its first call.
When the key is absent at launch, the baseline producer records an explicit zero only if the declared durable lifecycle ledger is present, completely parseable, and shows no earlier owner whose lifecycle overlaps the report period.
A missing or incomplete ledger and a reused worktree with an overlapping owner remain unavailable until a real bounded baseline exists.
`bin/fm-task-usage.sh <id>` first lists codeburn's reported project inventory and matches the worktree against those reported paths.
It uses the uniquely matched reported project name as codeburn's filter key, then subtracts the same filtered baseline to exclude previous occupants of a pooled worktree slot.
Codeburn can leave the top-level `overview` account-wide even when `--project` filters the project and model rows.
Task totals therefore come from the exact filtered project row and its model rows, and capture refuses a disagreement between them.
An absent, ambiguous, or ineffective project match is an attribution error and never becomes a zero-usage report.
`bin/fm-teardown.sh` saves the final delta as `data/<id>/usage.json` before deleting volatile task metadata.
The durable snapshot keeps completed-task usage in `fm-fleet-snapshot.v1` after worktree return and pool reuse.
Writing a v2 snapshot also refreshes the derived effort-store row immediately, so a live task exposes its attributed cost, tokens, calls, sessions, and actual models before teardown.

The JSON contract is owned by `bin/fm-task-usage.sh` and identified by `fm-task-usage.v2`.
It reports the task id, title, kind, project, delivery mode, dispatched harness, configured model, actual model names and per-model totals, tokens, cost, calls, sessions, spawn and capture timestamps, and wall-clock duration.
The compact text form also surfaces the harness, actual models, tokens, cost, calls, sessions, and elapsed wall-clock time.
Existing `fm-task-usage.v1` snapshots remain readable and accepted by the fleet snapshot, but they are not rewritten or silently treated as v2 records.
Usage capture without `spawned_at=`, a uniquely matched reported project, or either a saved reported-project baseline or a proven fresh-worktree zero baseline fails instead of emitting an unbounded or plausible-zero total.
The effort store treats legacy v1 snapshots and failed or mismatched v2 attribution as missing rather than inventing a backfill.

Usage collection is best effort.
A missing or unreadable codeburn result never blocks spawn or teardown, and the fleet snapshot marks live usage unavailable.
Each codeburn call is bounded by a timeout (`FM_TASK_USAGE_TIMEOUT`, default 15s) so a hung report never stalls spawn, teardown, or fleet-snapshot generation.
`bin/fm-fleet-snapshot.sh` queries every live task's usage in parallel, each bounded by the shorter `FM_FLEET_USAGE_TIMEOUT` (default 5s), so total wait stays bounded by the slowest single call instead of the sum across the whole fleet.
The snapshot read never writes persistent data.
When `state/usage-cache/<id>.json` already exists, a timed-out or failed live query may serve that reading with `stale:true` instead of blanking to unavailable.
`bin/fm-teardown.sh` deletes that task's `state/usage-cache/<id>.json` entry alongside its other volatile state, so a torn-down task never leaves an orphaned live-usage cache behind; the durable `data/<id>/usage.json` snapshot is unaffected.
