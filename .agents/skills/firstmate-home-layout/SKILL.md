---
name: firstmate-home-layout
description: >-
  Agent-only inventory of firstmate's private `data/`, `state/`, and `config/` children.
  Use before reading, writing, or deleting any file under those directories, before relying on an inherited-material list, and when identifying which script owns a private record.
user-invocable: false
metadata:
  internal: true
---

# firstmate-home-layout

`AGENTS.md` section 2 keeps the always-loaded boundary: the top-level map, `FM_HOME` isolation, the trusted-check rule, the wake-queue durability rule, the away-mode transfer, and the status-line-is-not-truth rule.
This skill owns the full child inventory those lines point to.
`docs/configuration.md` remains the single owner of the top-level operational-home layout and configuration schemas; each producing script's header and help own exact child fields and mutation mechanics.

## Tracked root and gitignored material

The tracked root contains the shared instructions, documentation, workflows, skills, and helper scripts; read a helper's header before first use.
`.env`, `config/`, `data/`, `state/`, `projects/`, and `.no-mistakes/` are local and gitignored, and the first four hold captain-private operational material.
`projects/` remains read-only to firstmate except under hard rule 1's narrow exceptions.

## Inherited local material

`secondmate-provisioning` owns inherited local material.
The primary-authoritative inherited set is `config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`, `config/backend`, `config/herdr-presentation-spaces`, `config/startup-memory-budget`, `config/agents-md-budget`, `config/session-start-budget`, `config/trace-context`, and `data/captain-shared.md`.
Inheritance copies the literal `config/crew-harness` file, and `data/captain-shared.md` remains main-authoritative in the primary and read-only in secondmate homes.
`config/secondmate-harness`, `config/calm`, `config/cockpit-layout`, and `config/cockpit-sections` are not inherited.
`config/secondmate-harness` is the primary's own launch setting because secondmates do not spawn secondmates.
Read local `config/cmux-socket-password` fresh on every cmux CLI call without overriding an operator's ambient `CMUX_SOCKET_PASSWORD` when the file is absent, and source local generated `config/x-mode.env` before arming a watcher when it is present.
`docs/configuration.md` owns every config item's purpose, schema, default, and operator-facing behavior.

## `data/` children

`data/` holds durable private fleet records.
`data/captain.md` is the canonical domain-local preference record even when harness memory mirrors it, and both it and home-local `data/learnings.md` use inspect-then-update curation rather than append-only growth.
`data/captain-shared.md` carries primary-authoritative shared preferences under the read-only inheritance contract above.
`data/effort-annotations.jsonl` is firstmate-private, hand-recorded, append-only ingestion data that outlives the derived store; `data/cost-attribution.tsv` is append-only lifecycle capture written before volatile metadata disappears; and `data/effort-store.sqlite` is firstmate-private, fully rebuildable, and safe to delete.
`data/learnings.md` remains dated, evidence-backed, and lazily created, and it is rewritten and pruned rather than appended forever.
`data/projects.md` is parsed for mechanical sync and seeding by `bin/fm-project-mode.sh`, and `data/secondmates.md` is maintained by the secondmate seed helpers; both registries are firstmate-private.
The named data producers and `docs/effort-store.md` and `docs/task-usage.md` own child paths, formats, and lifecycle mechanics.

## `state/` children

`state/` holds private runtime records and append-only status events, not durable project knowledge.
Each producer script's header owns the exact fields, trust binding, and cleanup contract for the state it creates.
Task turn-end tokens and harness session bindings are firstmate-owned volatile state removed by teardown.
A task's Herdr presentation journal is quarantinable attempt and restart-binding state, never task or endpoint authority.
The watcher executes only byte-identified trusted poll shims, validated private PR data, or registered custom checks bound to hash-validated private snapshots; it rejects every other state check without execution.
PR-poll sidecars, registrations, retirement receipts, migration logs, and quarantine are private provenance, and quarantined checks are non-runnable.
Registered process-event sources and condition-to-action watches are private, are written only by `bin/fm-procevent.sh` and `bin/fm-procevent-when.sh`, and keep supervision required until their owner retires them; captured source output stays in the private inbox and never in a wake line.
Generated Relay, pending-reply, public-followup, usage-cache, and startup-network children remain private and are owned by their named scripts, section 14, or `docs/task-usage.md`.
Effort ingestion queues, worker logs, capture locks, and the disposable git cache are owned by [`bin/fm-effort-store.sh`](../../../bin/fm-effort-store.sh)'s header.
`state/<id>.context-watch` is the watcher's derived context-signal cache and `state/.context-surfaced-<id>` its surfaced-level marker, both owned by [`bin/fm-context-watch.mjs`](../../../bin/fm-context-watch.mjs)'s header, removed by teardown, and safe to delete only to refold or re-surface from the start.

Never touch `state/.watcher-down`, `state/.claude-autoarm*`, `state/.turnend-claude-blocks*`, `state/.turnend-claude-rewake`, `state/.cursor-park-owner*`, `state/.turnend-cursor-blocks`, `state/.hash-*`, `state/.count-*`, `state/.stale-*`, `state/.stale-since-*`, `state/.paused-*`, `state/.wedge-escalations-*`, `state/.seen-*`, `state/.hb-surfaced-*`, `state/.last-*`, `state/.heartbeat-streak`, `state/.subsuper-*`, or `state/.supervise-daemon.*`.
`state/.<id>.open-decisions-cursor` is owned by `bin/fm-classify-lib.sh`, removed by teardown, and safe to delete only to force a full re-fold; the same library owns the status-presentation cursor and lock and teardown retires each task's row.
`state/.watch-triage.log` is a size-capped debug log that is never authoritative and is safe to delete, while only the watcher may update `state/.last-watcher-beat`, the liveness beacon that guard scripts read.
`state/teardown.log` is append-only footprint-override evidence owned by `bin/fm-teardown.sh`, and `state/pool-footprint.over-budget`, `state/pool-footprint.check.sh`, its trust record, and `state/.pool-footprint-surfaced` are owned by `bin/fm-pool-footprint.sh`, whose header owns the one-wake-per-total contract.
`state/.herdr-cockpit`, `state/.cockpit-focus.lock`, `state/.watch.lock`, and `state/.wake-queue.lock` are private coordination state owned by their named docs and scripts.
