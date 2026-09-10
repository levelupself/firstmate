# Model gut-check

`bin/fm-model-bench.sh` runs one task on several models at once, each in genuine isolation, and reports which arm finished fastest and cheapest.
It reports; the reader concludes.
It is one command that sets up, launches, watches, and reports, plus one broadcast command; it is not a scheduler, a queue, a policy layer, or an experiment framework.
The script header owns the exact flags and record layout, and `bin/fm-model-bench-analyze.mjs` owns the arithmetic; this page owns why each step exists.

## Running one

```sh
bin/fm-model-bench.sh run projects/<name> \
  --arm codex:<model> --arm claude:<model> \
  --task-file /path/to/task.md \
  --feasible 'One sentence asserting the task is achievable.' \
  --env MTG_ORACLE_ROOT=/data/oracle \
  --dry-run
```

Drop `--dry-run` to launch.
The command then watches every arm's status file until each reaches a terminal line (or `--timeout`), and prints the comparison.
`--no-wait` returns right after launch; `report <run-id>` renders the comparison at any later time, and `data/<run-id>/report.json` holds the same data.
`send <run-id> <text>` delivers one message to every arm identically; there is deliberately no way to steer a single arm.
Each arm is an ordinary ship task named `<run-id>-a<n>` on branch `fm/<run-id>-a<n>`, so firstmate's watcher, status protocol, and `bin/fm-teardown.sh` apply to it unchanged.

## Why each step exists

Every requirement below comes from a hand-run comparison on 2026-09-09 that got the mechanics wrong in a different way on each of three attempts.
Read them as a defect list.

1. **Isolate each arm completely.**
   Each arm gets its own clone and its own private bare source repository holding only the starting branch, and the tool verifies per arm that the arm's only remote holds exactly one ref.
   The hand-run arms were pooled worktrees of one repository, so the moment one arm committed, its branch was visible to the others, and one arm took another's implementation wholesale and committed it as its own.
2. **Pre-authorise every new copy before launch.**
   A brand-new repository root triggers a first-run directory trust prompt that can silently consume the launch instructions, leaving the worker at an idle prompt with no task.
   The tool writes the arm's clone root into the harness's own trust store before launch and reads the entry back, refusing a differing recorded trust decision: `[projects."<abs path>"] trust_level = "trusted"` in codex's `config.toml`, and `projects.<abs path>.hasTrustDialogAccepted = true` in claude's `.claude.json`.
   Both harnesses key trust on the main repository root and extend it to linked worktrees, which is why the clone root rather than the pooled worktree is the key; the live guard below is what proves that shape still holds.
3. **Carry required environment through explicitly.**
   Isolation strips the ambient variables an ordinary pooled copy happens to inherit; the hand-run arms stopped because `MTG_ORACLE_ROOT` was unset.
   Every `--env KEY=VALUE` is written once to `data/<run-id>/env` and exported into every arm's shell by `bin/fm-spawn.sh --env-file`, mechanically and identically, before the harness starts.
   Harness-home overrides are refused so setup and launch agree on the trust store and session records; the script header lists the reserved names.
4. **Prove the briefs are identical.**
   One task body is generated, and every arm's instructions must be byte-identical once the arm's own task id is replaced by `{ARM}`; any difference refuses the launch and names the differing arm and line.
5. **Verify each arm's actual model before trusting any number it produces.**
   The running model is read from the arm's own session record, matched on the arm's exact worktree path, never from the terminal display (which shows stale text and produced two false alarms) and never from the value requested at launch.
   An arm whose running model cannot be positively confirmed is printed as `UNCONFIRMED` with its numbers withheld; a record that names two models mid-run is unconfirmed too.
6. **Require a feasibility statement.**
   The tool cannot judge feasibility, so `--feasible` is mandatory and the statement is recorded verbatim in the output.
   A task that turns out to be impossible measures refusal, not capability.
7. **Any mid-run message goes to every arm identically and at once, or not at all.**
   `send` is the only steering command; it refuses to start unless every arm is still live, starts deliveries concurrently, records every outcome, and a partial delivery is reported by `report` as a warning that voids the like-for-like claim.
8. **Measure active working time, not wall clock.**
   Active time is the sum of the arm's own turn brackets from its session record (codex `task_started` to `task_complete` or `turn_aborted`; claude `turn_duration` records), so operator pauses, restarts, and machine outages between turns do not penalise an arm.
   The hand run had a two-hour machine outage in the middle.
9. **Measure consumption from the session record**, sliced at the completion milestone.
   The worker is never asked to self-report usage: one runtime exposes counters, another does not, and a worker asked for them wastes time hunting.
   Codex's cumulative `total_token_usage` is read at the close of the turn that produced the terminal status line; claude's per-request `usage` is summed once per `requestId` up to the same point.
   Parked states are recorded separately and never set the completion slice; only `done` and `failed` establish it.
   A claude subagent transcript stored beside the session counts as the arm's spend and its model is listed separately in a note; it never decides the running model.
10. **Run an independence check before reporting anything, and fail the arm if it trips.**
    Every file each arm added or modified is byte-compared against the same file from every other arm.
    Identical files across two arms means one copied the other: the later arm's result is void, printed as `VOID` in the table and again in a banner, and never merged into the comparison.
    Missing source or base evidence produces `UNCHECKED` with numbers withheld because independence cannot be established.
    This check caught the copying in the hand run, and it runs on every report even when isolation is believed sound.
    Choose a task whose correct output is not a single obvious line, because two independent arms that legitimately produce identical bytes are indistinguishable from a copy.

## Reading the table

One row per arm: arm, harness, requested model, confirmed running model (with `MISMATCH` when it differs from the request), active time, tokens as total with input, cached input, and output, completion state, independence verdict, and branch.
Token counts are normalised per harness: codex input already includes cached input; claude input is fresh input plus cache creation plus cache reads; total is input plus output for both.
Below the table each arm's branch, private source repository, worktree, completion time, and last status line are listed so the work itself can be inspected.
`docs/task-usage.md` describes the separate codeburn-based accounting firstmate keeps for every task; this tool does not use it, because a model comparison needs the arm's own record sliced at its own completion.

## Supported harnesses

`codex` and `claude`.
An arm on any other harness is refused at setup, because this tool has no verified trust-store shape or session-record reader for it and the running model could never be confirmed.
Adding a harness means verifying all three facts live and recording them in `docs/verification/model-bench.md`.

## Cleanup

Nothing here tears an arm down.
`bin/fm-teardown.sh <run-id>-a<n>` handles each arm with its ordinary rules: an arm that pushed its branch to its private origin has landed work and is torn down normally.
The private clones and source repositories under `data/<run-id>/arms/` keep every pushed branch after teardown and may be deleted once the comparison has been read, and each arm's treehouse pool (`treehouse status` from the arm's clone) can be destroyed with `treehouse destroy`.

## Verification

`tests/fm-model-bench.test.sh` pins the arithmetic against recorded session fixtures (including one with a two-hour gap), the independence check against fixtures that share a file and fixtures that do not, and the dry-run refusals.
`tests/fm-model-bench-live-e2e.test.sh` (opt-in, `FM_MODEL_BENCH_LIVE_E2E=1`) runs a real two-arm comparison on every installed harness; `docs/verification/model-bench.md` records its dated result.
