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
A merge `fm-pr-merge.sh` authorizes from the backlog's Done history after the task's metadata is gone is not stamped either, because it has no launch identity to bind a lifecycle record to; [`bin/fm-pr-merge.sh`](../bin/fm-pr-merge.sh)'s header owns that path.
Launch, PR-open, sanctioned merge, sanctioned local landing, and teardown producers synchronously append their metadata or receipts and enqueue derived ingestion.
`fm-teardown.sh` additionally snapshots task usage, stamps teardown time and outcome, and captures the final revision before deleting task state.
Only durable evidence capture runs on the lifecycle critical path; launch, relaunch, PR checking, merge, and cleanup never wait for derived ingestion.
The enqueuer starts a background job automatically, with a single runner and coalesced pending requests rather than a separately managed daemon.
Requests arriving during ingestion remain queued for a subsequent pass.
A failed job leaves its requests pending; the next enqueue or explicit synchronous report retries them.

The derived layer is one SQLite file, `data/effort-store.sqlite`, under this home's gitignored `data/`.
It is recomputed from its sources and is safe to delete; `fm-effort-store.sh rebuild` recreates it.
A completed database replaces the previous database atomically, allowing reports to read while ingestion is running.
Nothing in the derived layer is ever written back to the raw layer.

## Sources, all keyed by task

| Source | Origin | Contributes |
|---|---|---|
| raw | `data/cost-attribution.tsv` | identity, dispatch axes, lifecycle timestamps, configured model, process counts, and outcome stamps |
| codeburn | `data/<task>/usage.json` | tokens, notional cost, calls, sessions, and actual-model split |
| tool-usage | `data/<task>/tool-usage.json` | where the tokens went: turns, tool calls, result sizes by tool and class, the largest results, and the per-turn timeline |
| ci | `data/pr-ci/<task>.json` | the forge's run ledger for the PR: runs and their jobs, how the PR landed, the train shape, and the card claim |
| git | the project clone named in the raw row | structure, commit link, and the durability relation |
| annotation | `data/effort-annotations.jsonl` | the posterior that no artifact records |

Records are keyed by task, so any later source that can name a task contributes with no schema change.
The codeburn input is the durable task-bounded usage snapshot.
Rebuild never re-queries mutable account-wide history.
[`task-usage.md`](task-usage.md) owns automatic attribution and its coverage limits.

## Process cost

The four process columns come from the durable no-mistakes run record matched by project, branch, and pull request at the sanctioned merge edge.
`findings` is the total number of structured findings reported across every recorded pipeline round.
`review_rounds` is the number of review rounds, including the final clean re-review.
`ask_user_count` counts reported findings whose recorded action is `ask-user`.
`gate_failures` counts non-review validation rounds in rebase, test, documentation, lint, or CI that reported one or more findings.
The counts are stamped into the append-only raw layer, so rebuilding never depends on the no-mistakes database still retaining the run.
If the matching run or its structured round record is unavailable, all four fields remain NULL rather than becoming zero.

## Context signal

Three more process columns are captured from the task's own stamped session records at lifecycle capture, beside `outcome`, `review_rounds`, `gate_failures`, and `reverted`, so rework and failure can be correlated with how large the task grew.
`peak_context_tokens` is the largest prompt any request carried across every launch, `compactions` counts context compactions across every launch, and `restarts` counts launch receipts beyond the first.
`bin/fm-context-watch.mjs` reads the bound records using the shared fold owned by `bin/fm-model-bench-analyze.mjs`.
If a capture cannot read the signal, it preserves any previously captured values; without prior values, the fields remain NULL rather than zero.
The values are stamped into the append-only raw layer at capture and are forward-only: rebuild never backfills historical rows, though a later lifecycle capture can record an available signal.
The cross-task report adds one `COMPACTIONS` line grouping outcome by compaction bucket (`0`, `1`, `2+`, and `unknown` for rows without the count).

## Where the tokens went

Task totals hide the split that explains context growth, so every lifecycle capture also folds the task's bound session records into a token attribution and persists it as `data/<task>/tool-usage.json`.
`bin/fm-context-watch.mjs usage` produces that object from the same bound records as the context signal, using the shared fold in `bin/fm-model-bench-analyze.mjs`; that reader's header owns the turn definition, the byte rule, and the tool class taxonomy.
The `task` row carries five summary columns beside `tokens_in`, `tokens_out`, and `peak_context_tokens`: `turns` (model requests), `tool_calls`, `tool_result_tokens_est` (what tool results put into the context), `assistant_output_tokens` (the model's own output), and `base_prompt_tokens_est` (the first request's prompt size, which estimates the fixed base of system prompt, instructions, and launch brief).
`task_tool_usage` holds one row per tool and class with calls, result bytes, estimated result tokens, and wall seconds spent waiting for results; `task_tool_class` rolls the same calls up by class.
`task_largest_results` ranks the five results that put the most into the context with the first 120 characters of what each call ran.
`task_turn_timeline` holds one row per model request with its timestamp, prompt size, output tokens, first tool and class, and the estimated tokens that turn's results put into the next prompt, so context growth is queryable turn by turn.

Every token figure derived from bytes is an estimate under one rule, `ceil(bytes / 4)`, and carries the `_est` suffix in column names and the `tok est` label in reports; `assistant_output_tokens`, `context_tokens`, and `output_tokens` are read from the record's own usage and are exact.
Tool calls are classified into a fixed taxonomy of `read`, `search`, `edit`, `build`, `test`, `differential`, `git`, and `other`, from the tool name first and from the command text for command-running tools; the rule table lives in the `bin/fm-model-bench-analyze.mjs` header.

The breakdown is forward-only: capture is the only writer, and it replaces the snapshot on every capture that can still read the records while leaving the prior snapshot untouched when it cannot, so the last successful fold survives cleanup.
Rebuild reads the snapshot and never a session record, so a task captured before the fold existed keeps every attribution column NULL and its `tool-usage` source `missing`.
A bound record that yields no model request is persisted as `unavailable` and surfaces as a `tool-usage-unavailable` ingest issue, the same way an unusable cost snapshot does; a request that called no tool is a real zero.
The snapshot is bound to its launch by `spawned_at`, and a snapshot from another launch is rejected as `tool-usage-launch-identity`.

Every cross-task report row adds a `USAGE` column (`turns / calls / result tok est / out tok / peak ctx`) and a `CLASSES (tok est)` column with the estimated result tokens per class in taxonomy order.
`report <task-id>` adds the base prompt estimate, the class roll-up, the per-tool table, the five largest results, a `TIMELINE` line sampling the prompt size at turn 1 and at 25, 50, 75, and 100 percent of the turns, and the five largest single-turn jumps with the tool and class of the turn whose results landed.

## CI ledger per landed PR

Every sanctioned PR merge also reads the PR's workflow-run ledger from GitHub, read-only, once the merge receipt, the backlog outcome, and the Linear write are recorded, and stores it as `data/pr-ci/<task>.json`.
The ledger is the forge's own record of that landing: the PR, every workflow run on its head branch created before it closed, and each run's jobs across all attempts; nothing in it is reconstructed.
Runs on the default branch after the merge belong to the branch, not to the PR, and are not counted.
`bin/fm-effort-store.sh backfill-ci` pulls the same record once for every merged receipt under `data/pr-merges/` that has no ledger yet, which is the capture-forward rule's one allowance for forge facts the forge recorded at the time.
An existing ledger is kept unless `--replace-existing` is passed, which replaces the receipt's own ledger and never a train member's, a receipt whose PR the forge can no longer serve is named and counted rather than invented, and `--limit` bounds one pass so a large backlog can be pulled in batches under the API rate limit.
A merge whose forge read fails still lands; the merge reports that the ledger was not captured and the backfill recovers it.

The `task_ci` row joined to `task` carries the run count, the runs cancelled, failed, and succeeded, total runner seconds (the sum of job durations), total queue seconds (run creation to the first job start, per run), the first run's creation and the last run's completion, and how the PR landed.
`task_ci_run` keeps one row per run with its attempt number so restarts stay queryable.
A run is cancelled on a `cancelled` conclusion, failed on `failure`, `timed_out`, or `startup_failure`, and succeeded on `success`; other conclusions count as runs and nothing else.

`landing` is `direct` for a PR merged on its own, `train:<n>` for a PR that landed through merge train PR `<n>`, and `closed` for a closed PR with no train evidence.
A train is a PR whose title starts with `train:` or whose body carries a `## Manifest` section; the ledger records its member count from the manifest's `- #<pr> fm/<task-id> ...` lines, its ejected count from the same shape under `## Ejected`, and its fix-round count from the body's `## Fix round` headings.
When a merged train's receipt is captured, every manifest member whose branch names a task is captured beside it as landed through that train, and a member ledger that already records the member's PR is never replaced by the manifest path, even under `--replace-existing`.
A train that closed without merging landed nothing, so its capture records only its own ledger and reports each member as not captured.
A task's existing ledger, primary or member, is kept only when it records the same task and the same PR being captured; a ledger left by an earlier PR of a relaunched card is rebuilt from the PR that landed.
A run listed twice by the forge is recorded once, and a ledger that repeats a run id is an invalid ledger whose CI source is missing rather than a rebuild failure.
A member PR captured on its own after it was closed names its train from a `train ... #<n>` mention in its closing comment or from its Done row in `data/backlog.md` or `data/done-archive.md`, skipping any mention of its own number.
The `**N moved**` figure in a PR body is stored as `task.cards_moved_claimed`; it is the body's claim, not a measurement.

The cross-task report adds a `CI` column per task (runner minutes, queue minutes, runs with the cancelled and failed counts, landing, and runner minutes per claimed card), one `CI direct` line and one `CI train` line totaling runner minutes, queue minutes, and claimed cards per landing method, and one `TRAIN` line per train with its members' minutes and card claims.
`report <task-id>` adds the ledger's counts, timestamps, landing, and card claim, plus the train shape for a train.
Rebuild derives every figure from the recorded ledger and never consults the forge, so the ledger is the single durable input and `rebuild` reproduces the tables exactly.

## Reading the headline numbers

Run `bin/fm-effort-store.sh report` to list every task and aggregate totals.
Run `bin/fm-effort-store.sh report <task-id>` for one task.
The report shows launch-to-PR duration, cost, input and output tokens, actual models, outcome, the context signal, and the token attribution columns described under [Where the tokens went](#where-the-tokens-went).
When the published database has an older schema, or the append log or queued evidence is ahead of it, the report identifies pending ingestion and lists raw task identities with unavailable measurements rather than a plausible zero or an incomplete aggregate.
Use `report --sync` to wait for pending ingestion before reading measurements; ordinary reports never acquire the ingestion lock.
The cross-task report groups tasks by the lifecycle row's project path, but project dollar totals remain unavailable because the store has no durable bound for the reporting period's complete historical task population.
Each project shows cost-evidence coverage for its known lifecycle rows and explicitly states that historical population completeness is unproven instead of presenting the known subtotal as a total.
A future project-total capability requires a durable reporting-period population bound; this store does not infer that bound from the rows it already contains.
A pooled worktree never becomes the project bucket.
A dash means the durable source is missing or ingestion is pending, as identified by the report.
It never prints a plausible zero for an absent source.

## Historical codeburn recovery

Run `bin/fm-effort-store.sh backfill-codeburn <export.json>` with one `codeburn export --format json` result to recover completed task windows explicitly.
An existing byte-equivalent snapshot makes the command an idempotent no-op, while a different snapshot is refused unless `--replace-existing` is passed.
Explicit replacement preserves the previous bytes beside `usage.json` under their SHA-256 before atomically installing the recovered snapshot.
The entire target batch and every existing preservation artifact are preflighted before any task snapshot is written.
The command joins each export record to the one lifecycle row whose normalized worktree matches and whose launch-through-end window contains the record timestamp.
Codeburn records the directory where work ran as its project key, so pooled worktree paths in an export are correlation identities rather than product-project identities; the lifecycle row supplies the actual project bucket after the record has one task owner.
It writes a durable task snapshot only when at least one record has exactly one owner and the export covers that owner's complete lifecycle.
No-record windows remain missing because an empty export window cannot prove that every worker runtime was observable.
Overlapping windows remain unassigned instead of choosing one.
Lifecycle windows that cross an export boundary retain their worktree mapping, but their matching records and dollars are classified as `incomplete-export-window`, their missing coverage bounds are printed, and task cost remains absent.

Every recovered snapshot records the task window, record count, worktree key, and SHA-256 of the export.
The command reports the attributed subtotal and classifies every remaining record and dollar as `unmapped-worktree`, `outside-task-window`, `ambiguous-worktree-key`, `ambiguous-task-window`, or `incomplete-export-window`.
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
- A CI ledger that names a different PR from the one the task recorded is recorded as `ci-pr-identity`, and a malformed ledger as `ci-ledger-invalid`; either leaves the `ci` source `missing` rather than counting runs from the wrong PR.

The same rule applies inside a source.
Binary diff additions and deletions stay NULL at both file and task levels because git cannot measure them.
Import degrees are computed from the project's current checkout, so a path a task once touched that no longer exists there has no degree at all rather than a degree of zero.
Tasks from before tracking that left no durable raw row, usage artifact, baseline, or annotation cannot be enumerated honestly and remain unrecoverable rather than being invented.

## The durability relation

`durability` links a task to the tasks that later modified the code it introduced.
It is the ultimate posterior: a task needing three later fixes was harder than either its structure or its round count said, and only time reveals that.

The walk is anchored at the later task's own commit and runs backwards with `git log --follow`, so a rename between the two tasks is followed rather than breaking the link.
The row keeps both names: `introduced_path` is the name the earlier task knew, and `modified_path` is the name at the later change.

Per-commit file inventories and anchored rename walks are cached by project and commit, so unchanged evidence does not repeat file-history walks during incremental ingestion.
The cache is disposable: a missing or unreadable entry is regenerated, and explicit `rebuild` refreshes the full cache.
The task-to-commit link remains durable raw evidence rather than cache-only knowledge.

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

Launch time, PR-open time, sanctioned merge or local landing time, teardown time, outcome, process counts, cost, tokens, calls, sessions, configured model, actual models, and the token attribution snapshot are deterministic lifecycle or snapshot facts.
A task discovered from any durable raw row, usage snapshot, CI ledger, or annotation remains visible when another source is absent, with that source's measurements NULL and its `task_source` row marked `missing`.
Legacy `fm-task-usage.v1` snapshots are discovered but treated as missing because they predate deterministic reported-project attribution and may contain the broken plausible-zero result.
Baseline-only task directories from before lifecycle capture remain `usage-pre-deterministic-attribution` because they have no trustworthy task window or project mapping for a history join.
No value is reconstructed from a guess.
The separate discovery-versus-churn and loud-versus-quiet research annotations remain manual because no durable artifact contains those judgments.

## Verification

The suites drive public lifecycle and store entry points and verify SQL results, report output, and instrumented ingestion and git calls.
They cover nonblocking lifecycle capture during stalled ingestion, request coalescing, cached history reuse, pending reports, launch-to-PR duration, durable usage and actual models, missing-versus-zero behavior, both recorded-by-hand fields, the durability link across a file rename, one-command reporting, token attribution capture and reporting for both session record formats, the CI ledger against a stubbed forge (capture at the merge edge, train members, closed-member train resolution, the one-time backfill, and rebuild without the forge), and delete-and-rebuild identity.
The context-watch suite proves the per-harness tool fold and class taxonomy through the `usage` reader.

```sh
tests/fm-effort-async.test.sh
tests/fm-effort-lifecycle.test.sh
tests/fm-effort-store.test.sh
tests/fm-context-watch.test.sh
```
