# Effort store

The effort store is a derived, queryable record of how much work each task actually took.
It exists to build a reference class for agentic engineering, because current effort expectations are inherited from human effort data and measure a different thing.
It is not a cost tracker: spend is one column among structure, process, time, and outcome.

[`bin/fm-effort-store.sh`](../bin/fm-effort-store.sh) is the entry point and owns the command contract; run it with `--help`.
[`bin/fm-effort-store.mjs`](../bin/fm-effort-store.mjs) owns the schema, the join, and the missing-source contract.

## Lifecycle and two layers

The raw layer is `data/cost-attribution.tsv`.
It is append-only and irreplaceable because each lifecycle producer records its current durable facts while task metadata is available.
`fm-spawn.sh` stamps launch time, `fm-pr-check.sh` stamps the forge-created PR-open time, `fm-pr-merge.sh` stamps a sanctioned PR merge, and `fm-merge-local.sh` stamps a sanctioned local landing.
GitHub and GitLab creation timestamps and the GitHub merge timestamp come from structured forge responses; an unavailable or invalid provider timestamp remains NULL.
The PR outcome is stamped only after the same forge response confirms the merged state.
The sanctioned merge path also snapshots the matching no-mistakes run's structured process record while it is still available.
Merges performed outside `fm-pr-merge.sh` are not observed or inferred later.
Launch, PR-open, sanctioned merge, sanctioned local landing, and teardown producers incrementally capture their metadata or receipts and rebuild the store.
`fm-teardown.sh` additionally snapshots task usage, stamps teardown time and outcome, and captures the final revision before deleting task state.
No agent or operator command is part of that lifecycle.

The derived layer is one SQLite file, `data/effort-store.sqlite`, under this home's gitignored `data/`.
It is recomputed from its sources and is safe to delete; `fm-effort-store.sh rebuild` recreates it.
Nothing in the derived layer is ever written back to the raw layer.

## Sources, all keyed by task

| Source | Origin | Contributes |
|---|---|---|
| raw | `data/cost-attribution.tsv` | identity, dispatch axes, lifecycle timestamps, configured model, process counts, and outcome stamps |
| codeburn | `data/<task>/usage.json` | tokens, notional cost, calls, sessions, and actual-model split |
| git | the project clone named in the raw row | structure, commit link, and the durability relation |
| annotation | `data/effort-annotations.jsonl` | the posterior that no artifact records |

Records are keyed by task, so any later source that can name a task contributes with no schema change.
The codeburn input is the durable task-bounded snapshot written while the task still owns its worktree and baseline.
Rebuild never re-queries mutable account-wide history.
The task-usage producer owns project-key matching and baseline subtraction, as documented in [`task-usage.md`](task-usage.md).

## Process cost

The four process columns come from the durable no-mistakes run record matched by project, branch, and pull request at the sanctioned merge edge.
`findings` is the total number of structured findings reported across every recorded pipeline round.
`review_rounds` is the number of review rounds, including the final clean re-review.
`ask_user_count` counts reported findings whose recorded action is `ask-user`.
`gate_failures` counts non-review validation rounds in rebase, test, documentation, lint, or CI that reported one or more findings.
The counts are stamped into the append-only raw layer, so rebuilding never depends on the no-mistakes database still retaining the run.
If the matching run or its structured round record is unavailable, all four fields remain NULL rather than becoming zero.

## Reading the headline numbers

Run `bin/fm-effort-store.sh report` to list every task and aggregate totals.
Run `bin/fm-effort-store.sh report <task-id>` for one task.
The report shows launch-to-PR duration, cost, input and output tokens, actual models, and outcome.
The cross-task report also groups cost by the lifecycle row's project path and shows measured tasks over total tasks for each project.
A pooled worktree is only the codeburn correlation key and never becomes the project bucket.
A dash means the durable source is missing.
It never prints a plausible zero for an absent source.

## Historical codeburn recovery

Run `bin/fm-effort-store.sh backfill-codeburn <export.json>` with one `codeburn export --format json` result to recover completed task windows explicitly.
An existing byte-equivalent snapshot makes the command an idempotent no-op, while a different snapshot is refused unless `--replace-existing` is passed.
Explicit replacement preserves the previous bytes beside `usage.json` under their SHA-256 before atomically installing the recovered snapshot.
The entire target batch and every existing preservation artifact are preflighted before any task snapshot is written.
The command joins each export record to the one lifecycle row whose normalized worktree matches and whose launch-through-end window contains the record timestamp.
It writes a durable task snapshot only when at least one record has exactly one owner.
No-record windows remain missing because an empty export window cannot prove that every worker runtime was observable.
Overlapping windows remain unassigned instead of choosing one.

Every recovered snapshot records the task window, record count, worktree key, and SHA-256 of the export.
The command reports the attributed subtotal and classifies every remaining record and dollar as `unmapped-worktree`, `outside-task-window`, `ambiguous-worktree-key`, or `ambiguous-task-window`.
It also prints codeburn's summary total, the sum of per-record costs used for task attribution, and their exact rounding delta.
This matters because codeburn exports task-addressable record costs at cent precision while its summary and interactive report retain aggregate pricing precision.
The raw export record is the bounded attribution evidence, so no difference is hidden or interpolated.

## The two fields that are not automatic

`round_reason` separates **discovery**, where the work revealed more than was visible, from **churn**, where the requirements moved under the work.
The symptom is the same extra round; the disease is not, and a store that conflates them learns that an unstable specification is a hard problem.

`failure_mode` is one bit per task: would a defect here have failed **loudly** or **quietly**.
Code that fails quietly is the most load-bearing and the most under-rated by any structural measure, because a defect in it produces no mechanical symptom at all.

Neither is inferred from anything.
Both are recorded with `fm-effort-store.sh annotate`, which refuses any other value rather than coercing one.
They live in the append-only annotations file rather than in the database because the database is deletable, and a field stored only there would not survive its own rebuild.
Later lines merge field by field over earlier ones, so a failure mode recorded a week after the round reasons does not erase them, and every superseded line stays readable.

## Missingness is data

An absent source and a zero must never look the same.

- A source that could not be consulted for a task is recorded in `task_source` as `missing`, and the columns it would have filled stay NULL.
- A source that was consulted and legitimately found nothing is recorded as `present`, and its columns hold real zeros.
- The original declared eight-column capture format contributes task and project identity but not lifecycle time, because its `captured` value was a migration observation rather than launch evidence.
- A line under that legacy header with the wrong column count is recorded as `legacy-column-count`, and an undeclared legacy region remains `unparsed-legacy-line`.
- A raw line whose schema section is unknown is recorded in `ingest_issue` rather than guessed into a task row, so nothing that arrives is dropped.
- A baseline-only task directory from before deterministic lifecycle capture creates a task row with NULL measurements and a `usage-pre-deterministic-attribution` issue.

The same rule applies inside a source.
Binary diff additions and deletions stay NULL at both file and task levels because git cannot measure them.
Import degrees are computed from the project's current checkout, so a path a task once touched that no longer exists there has no degree at all rather than a degree of zero.
Tasks from before tracking that left no durable raw row, usage artifact, baseline, or annotation cannot be enumerated honestly and remain unrecoverable rather than being invented.

## The durability relation

`durability` links a task to the tasks that later modified the code it introduced.
It is the ultimate posterior: a task needing three later fixes was harder than either its structure or its round count said, and only time reveals that.

The walk is anchored at the later task's own commit and runs backwards with `git log --follow`, so a rename between the two tasks is followed rather than breaking the link.
The row keeps both names: `introduced_path` is the name the earlier task knew, and `modified_path` is the name at the later change.

The relation is cheap to compute and impossible to backfill once the task-to-commit link is lost, which is the other reason the raw layer matters.

## Structure and its limits

Structure is the prior: cheap, available early, and known to be incomplete.
`prod_src_files` excludes tests, fixtures, docs, vendored code, and examples; `distinct_areas` counts monorepo package directories where they exist and top-level directories otherwise.
Import degree is parsed for the TypeScript and JavaScript family, Python, and shell `source` lines, and a project with no parseable source reports unsupported rather than a degree of zero.
`store_meta` records the classifier version so a later change to these definitions is visible in the data rather than silent.

## Determinism

Rebuild writes no current wall-clock value, so two rebuilds over the same inputs produce identical content.
Event times are written once by the lifecycle edge that observed them and become durable raw input before volatile metadata is removed.
`fm-effort-store.sh fingerprint` hashes a canonical dump of every table, which is what proves the rebuild contract; SQLite is free to lay out pages differently for identical logical content, so the file bytes are not the thing being compared.

## Deterministic limits

Launch time, PR-open time, sanctioned merge or local landing time, teardown time, outcome, process counts, cost, tokens, calls, sessions, configured model, and actual models are deterministic lifecycle or snapshot facts.
A task discovered from any durable raw row, usage snapshot, or annotation remains visible when another source is absent, with that source's measurements NULL and its `task_source` row marked `missing`.
Legacy `fm-task-usage.v1` snapshots are discovered but treated as missing because they predate deterministic reported-project attribution and may contain the broken plausible-zero result.
Baseline-only task directories from before lifecycle capture remain `usage-pre-deterministic-attribution` because they have no trustworthy task window or project mapping for a history join.
No value is reconstructed from a guess.
The separate discovery-versus-churn and loud-versus-quiet research annotations remain manual because no durable artifact contains those judgments.

## Verification

The suites drive public lifecycle and store entry points and read results back through SQL only.
They cover automatic lifecycle capture, launch-to-PR duration, durable usage and actual models, missing-versus-zero behavior, both recorded-by-hand fields, the durability link across a file rename, one-command reporting, and delete-and-rebuild identity.

```sh
tests/fm-effort-lifecycle.test.sh
tests/fm-effort-store.test.sh
```
