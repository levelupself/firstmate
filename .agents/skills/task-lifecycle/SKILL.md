---
name: task-lifecycle
description: >-
  Agent-only procedure for taking a Firstmate request from intake through project resolution, ship-or-scout classification, dispatch, validation, PR readiness, teardown, or scout promotion.
  Load at the intake of every new request before resolving its project, routing it, classifying its deliverable, writing its backlog item or brief, or starting work.
  Also load before resuming or promoting work whose task lifecycle was started in an earlier session.
user-invocable: false
metadata:
  internal: true
---

# task-lifecycle

Load this skill at task intake and keep it as the procedural owner through completion.
The always-loaded authority and judgment boundaries in `AGENTS.md` section 7 remain binding, including delivery-path rigor, approval ownership, green-only standing merge authority, teardown refusal, and the rule that a report never authorizes implementation.
Referenced scripts own their exact commands, flags, formats, and refusal mechanics.
Use `gh-axi` for GitHub, `chrome-devtools-axi` for browser work, and `lavish-axi` for structured decisions or reports; consult current help rather than memorizing flags.

## Intake and authority inputs

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list.
Keep `local-only` work in the main home.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it; do not read the secondmate's chat because marked routed replies return through its status or referenced document.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.

Before commissioning an investigation, consult existing reports and established evidence.
Classify the deliverable:

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.

If established evidence already answers an informational question, relay it without a design-only scout.
When implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.
Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.

Resolve every ship task's concrete delivery mode and `yolo` posture at intake, and pass both explicitly to the brief, the spawn, and any scout promotion, which all refuse to guess.
A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
An unregistered project or absent registry resolves to `no-mistakes` with `yolo` off, and the registration gap goes to the captain.
Record the resulting mode, `yolo`, and the one-line reason for any deviation in the backlog item note.

Write the task-specific brief under `AGENTS.md` section 11 before spawning.

## Backlog records

When a main-side thread such as a pending captain decision or Relay reminder is worth durable tracking, file it as its own work item.
Use `tasks-axi hold <id> --reason "<reason>" --kind captain` for a captain-gated thread.
Use compatible `tasks-axi` when the configured backend selects it and the documented manual path otherwise, and keep only the configured recent Done entries.
Update the backlog on every dispatch, completion, and decision for a work item.
Re-evaluate queued work after every teardown and heartbeat, dispatching items only when dependencies and time gates have cleared.

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge through the `stow` skill rather than scattering it through task notes.

## Dispatch and supervision handoff

Spawn only through `bin/fm-spawn.sh` after the profile and backend checks in `AGENTS.md` section 4.
The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assertion stops the task.
After spawning, confirm the worker is processing the brief, handle any trust dialog through `harness-adapters`, and record ship or scout work as under way.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

Steer a worker with short single-line messages through fail-closed `fm-send`; put long instructions in a file.
When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers; `bin/fm-send.sh`'s header owns the contract.
`fm-send` is the data plane for text the worker should read; never use its key or text paths for interrupt, exit, or other lifecycle control, because routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything.
[`docs/agent-control.md`](../../../docs/agent-control.md) owns the control-plane reference.
A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
`bin/fm-pending-reply-lib.sh` owns the parent-side correlation, recovery, and escalation contract for marked secondmate requests.
Supervise every live task under the emitted session-start protocol and the always-loaded boundary in `AGENTS.md` section 8.

## Selected delivery path mechanics

Use the one selected delivery path without adding a second validation path:

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.

Use `bin/fm-pr-merge.sh` for every task PR merge so merge metadata is recorded, and use `bin/fm-merge-local.sh` for approved local-only landing; never call a lower-level merge command around their guards.
After an autonomous merge, give the captain a one-line full-URL or local-main outcome.

## Validate

For a no-mistakes ship, the worker continues straight from its implementation commit into validation on its own.
Send the harness invocation owned by `harness-adapters` to that same worker only when it stopped without starting one.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.

Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task unless a new requirement completely invalidates the work being validated.
The smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake.
Corrections required to satisfy already accepted intent are not new requirements.

Every reported verification observation must carry the exact full commit SHA and proof-file list required by `bin/fm-brief.sh`; that generated rule is the single owner of the proof-file definition, and a ready report missing either field is incomplete.
At the merge decision for a no-mistakes PR, inspect pipeline fix rounds after the reported commit and re-verify an observation only when one of those rounds touched a file in that observation's proof-file list.
An overlap sends the same worker back to repeat only the affected observation against the current PR head and report updated provenance before merge; no overlap means no stale-proof re-verification.
For example, a pipeline fix to a reported `src/widget.ts` or `tests/widget.test.ts` proof file triggers, while a fix only to a worker-written `README.md` outside the proof list does not.
The boundary is file-granular: any hunk in the same proof file triggers, while a different file counts only when the observation actually exercised it as an indirect dependency and therefore reported it as proof.
Never broaden this to every file the worker wrote, every pipeline commit, or any movement of the PR head.
Direct-PR and local-only tasks still disclose provenance but have no pipeline-fix trigger.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision`; firstmate decides only when the configured authority permits, otherwise escalates to the captain.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the current-code-matched run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR at the generated brief's CI-ready return point, after satisfying any stricter local-suite gate, rather than waiting for merge monitoring to finish.

## PR ready, landing, and teardown

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` uses the repository-condition-specific terminal report selected by `bin/fm-brief.sh`, while `direct-PR` reports `done: PR <url>` after opening the PR.
Run `bin/fm-pr-check.sh <id> <PR url>`; it records `pr=` and the forge's `pr_head=` when available in the task's metadata and arms the watcher's merge poll.
When a `LINEAR_API_KEY` is configured it also appends the matching Linear issue reference to the PR body, best-effort and never able to fail the check; `docs/linear.md` owns that contract.
Tell the captain the PR's full URL, always the complete `https://...` link rather than a bare `#number`, a concise outcome summary, and the no-mistakes risk level when applicable.

For any custom `state/<id>.check.sh` written directly, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.

Keep a PR-based ship task live until its open PR lands whenever practical.
This is advisory because the sanctioned merge path also handles a safely delivered task that was torn down early.
When teardown refuses a legacy Herdr record that lacks `endpoint_task_id=`, use the explicit evidence migration in `bin/fm-endpoint-bind-migrate.sh` rather than editing task metadata by hand; `docs/configuration.md` owns the supported boundary.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.

## Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded.
Read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
Before treating the investigation or any visual review as complete, load `decision-hold-lifecycle`; teardown enforces that shared completion gate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
