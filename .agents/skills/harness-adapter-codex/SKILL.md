---
name: harness-adapter-codex
description: >-
  Use after harness-adapters when the resolved harness is codex.
user-invocable: false
metadata:
  internal: true
---

# harness-adapter-codex

Load this skill after `harness-adapters` when the resolved harness is `codex`.
## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy state | The rollout pull source and open-bracket owner binding are owned by [bin/fm-busy-lib.sh](../../../bin/fm-busy-lib.sh); manual-interrupt and owner-binding evidence, plus unusable push-source probes, are in [supervision verification](../../../docs/verification/supervision.md#codex-rollout-turn-bracket-2026-08-29). |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; the shared submit path used by `fm-control` handles it) |
| Interrupt | single Escape (recorded 2026-06-11 on 0.139.0; on 0.145.0 a single Escape was observed NOT to reach a running turn while `Ctrl+C` did - see docs/verification/supervision.md "Codex rollout turn bracket") |
| Skill invocation | `$<skill>` (e.g. `$no-mistakes`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

A `$<skill>` invocation opens a `$`-autocomplete (skill) popup, the same hazard as the `/` slash popup: submitting too fast lets the popup swallow the Enter, so the invocation never lands.
`fm-send` handles it the same way it handles `/` - it gives the popup a longer settle (1.2s) between typing and the first Enter, with the target backend's submit retry as the safety net - but the `$` settle is scoped to `harness=codex`, read from the target metadata for exact task ids or legacy `fm-<id>` labels.
That scope matters because, unlike `/`, a leading `$` commonly starts ordinary text (`$5/month`, `$HOME`), so a universal `$` rule would needlessly slow plain steers to claude/opencode/pi; only a codex target receiving a `$...` message gets the popup-settle.
An explicit `session:window` target has no meta, so its harness is unknown and treated as non-codex (the safe fast-path default).
This is why the validation trigger (`$no-mistakes`) to a codex crew now lands on the first Enter instead of biting the popup.

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?"
Accept with Enter.
The decision persists for the repo, so later worktrees of the same project skip it.

Resume after exit with `codex resume <session-id>`.
The session id is printed on quit.

## Model switches and near-limit dialogs

Treat `state/<id>.meta` model and effort as dispatch provenance, not a live guarantee after a long Codex run.
Historical observation on 2026-09-07: a pane dispatched as `gpt-5.3-codex-spark high` displayed that pair for about two hours, then displayed `gpt-5.6-luna medium`, while the dispatch record retained the original values and no explanation was visible in the pane.
The initiating event, any earlier dialog or acknowledgement, actual backend model consumption, and later restoration were not captured; neither window exhaustion nor a Spark-specific cap is established by that observation.

The following expectations are scoped to installed `codex-cli 0.160.0`, not a retrospective explanation of that incident.
[Supervision verification](../../../docs/verification/supervision.md#codex-near-limit-model-selection) separates the controlled live-TUI observations from matching upstream-source evidence.

- An ordinary `codex` usage bucket at 90% or more used in either primary or secondary window can queue the `Approaching rate limits` dialog.
  It offers `Switch to gpt-6-luna`, `Keep current model`, and `Keep current model (never show again)`; the subtitle asks about lower credit usage.
  The first option is initially selected, so a routine Enter can accept a model switch instead of submitting a message.
  This is an interactive selection, not evidence of an automatic quota-exhaustion reroute or a hung worker.
- Source conditions also require no usable workspace credits, an available visible cheaper-model preset, no hidden reminder preference, and an eligible current model; a backend banner can defer the dialog, and the Luna or Luna-reserve model suppresses it.
  Model-specific usage buckets alone do not trigger this ordinary-bucket nudge.
  A warning can precede the dialog, which was observed after a simulated turn completion rather than immediately at startup.
- Accepting the switch selects the cheaper preset's default effort as well as its model.
  The controlled observation changed `gpt-6.1-sol high` to `gpt-6-luna medium`; retaining `high` is not part of this path.
  The footer and `thread/settings/updated` notifications expose the new selection even when no explanatory chat message appears.
  Sending a subsequent zero-used usage snapshot did not restore the original pair during the bounded observation; do not assume an automatic return after a real allowance reset.

When this dialog or a changed footer appears, inspect the choices and current selection before sending another routine Enter.
Keep the accepted model and effort unless firstmate authorizes a change under the existing effort and decision-authority rules; an effort downgrade is a decision, not routine dialog dismissal.
Collect the CLI version, visible dialog, footer or `/status`, and session-bound settings or rollout evidence before classifying the worker as stuck.
Codex's `thread/settings/updated` supplies selected `model` and `effort`; where legacy rollout `turn_context` records are available, inspect their model and effort for each relevant turn rather than just the last record.
The existing [model-bench analyzer](../../../bin/fm-model-bench-analyze.mjs) reads rollout model changes, but does not reconcile live dispatch metadata.
Preserve the original dispatch values and report an evidenced mismatch separately; no automatic metadata reconciliation is provided by this adapter.
These client settings establish selection, not proof of which backend model consumed a particular quota window, and missing evidence leaves that attribution unknown.
The September switch's trigger and restoration remain unknown; reproducing a synthetic UI path must never be presented as reproducing that historical service event.
Do not deliberately exhaust a quota window to investigate it.

## Primary-session guard (verified 2026-07-08, codex-cli 0.142.1)
The firstmate PRIMARY's own `.codex/hooks.json` registers a Stop hook that pipes Codex's Stop payload to `bin/fm-turnend-guard.sh`.
Codex Stop hooks block on exit 2 and expose `stop_hook_active` for the same one-block loop safety Claude uses.
Codex's Stop payload includes `cwd`, but the tracked primary hook does not use it to choose the guard executable.
Verified on 2026-07-08: Codex runs the Stop hook command with process PWD set to the hook-loaded project root, and no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is firstmate-shaped and hook-bearing, and then invokes `bin/fm-turnend-guard.sh` with the original payload.
Codex's primary watcher protocol is `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `bin/fm-watch-arm.sh`.
The checkpoint is deliberately foreground and bounded so Codex regains control regularly to process user messages and queued wakes.
