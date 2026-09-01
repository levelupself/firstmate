Common wake-handling procedure.

At the start of every wake-handling turn, drain the durable wake queue before peeking, reading beyond the reason line, steering, or starting work.
Session start is the only exception because its one-shot digest already presented the queue while locked or deliberately left it untouched in lock-refused read-only mode.
Treat every `OPEN DECISIONS` entry as actionable reconciliation input even when no wake record was queued.
Treat every `UNREAD STATUS` entry as newly surfaced status that must be read this turn; those lines are not re-printed after this presentation.
After handling every emitted wake and reconciling those two sections, run the exact generation-bound `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
Interruption before that acknowledgement leaves the work durable for idempotent re-handling.

A status line is a wake event, not current-state truth.
Use `bin/fm-crew-state.sh` when current state matters, especially before re-escalating an old decision, blocker, or pause.
A declared `paused:` event means a bounded external wait expected to clear on its own, `captain-held:` means an escalated decision is parked awaiting firstmate or captain action, and `blocked:` means firstmate action is needed to unblock the worker.

Handle actionable wakes as follows:

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker; a deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result, including merges, Relay events, and process-to-event source results.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, and never report an unchanged fleet as progress.

When a wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up so the link clears even if earlier follow-ups were spent.
A secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than treating a quiet pane as stale.
Waiting on a healthy supervision cycle is silent; empty polls, elapsed time, and no-change updates are not captain-facing progress.
Use `bin/fm-task-usage.sh <id>` for live or snapshotted codeburn usage for one crewmate or scout cycle.
