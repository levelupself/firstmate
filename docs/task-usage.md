# Task usage

New tasks record session identities at launch, and `bin/fm-task-usage.sh <id>` joins those identities to codeburn usage.
Ownership requires an exact stamp and directory containment; timestamps, parent chains, project slugs, and pooled-copy history do not decide ownership.
The immutable identity and launch-receipt format is owned by `bin/fm-task-session.mjs`.
Each activated launch retains its own receipt, including the original runtime store location, so relaunches and runtime switches keep earlier spend without sealing totals or replacing a boundary.
Registration happens in the launch shell after environment exports and activation, so a failed replacement staging does not create a receipt or mutate the previous launch's identity.
Tasks that began without a measured identity can still be relaunched, but their usage remains unavailable; no baseline or identity is inferred retrospectively.
Other supported worker runtimes can still launch, but their receipts report unsupported usage attribution until a stamping adapter exists.

Claude receives a generated UUID through `--session-id`.
Its main transcript carries that stamp, and transcripts structurally contained in its session's `subagents` directory carry the same parent stamp while joining to codeburn through their own transcript IDs.
Codex receives the launch stamp through `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`, and the reader obtains it from local rollout `session_meta.payload.originator` before joining by session ID.
This INTERNAL variable is an unsupported, version-dependent surface that can change or disappear without notice; it is not a stable Codex contract.
Codex descendant inheritance is unproven: descendants lacking a matching stamp are excluded, and complete descendant cost coverage is not claimed.
A runtime that stops recording the stamp produces an unavailable reading rather than an inferred attribution.

The reader uses codeburn's precise session totals, which do not expose the Codex originator; the local rollout join is required.
The session-report shape, session-ID correspondence, and cost fields are version-dependent integrations.
Codeburn's call export rounds costs to currency precision and is unsuitable for this attribution path.
For sessions containing multiple models, task totals remain exact but amounts for the affected models are unknown rather than split speculatively.
The portable attribution tests use fixtures; the real-CLI creation guard is linked from `docs/verification/runtime-backends.md`.
The query requests the full history; dates do not filter ownership.
Unreadable stores, missing launch sessions, missing usage rows, and missing or changed previously snapshotted session files produce errors identifying their paths, never zero totals.
A live read is read-only; a snapshot preserves measured source paths and counters so later capture refuses lost sources and decreasing totals.
Session files removed before any measurement cannot be reconstructed; launch receipts still require a matching main session, but previously unobserved descendants cannot be proven complete.

The JSON contract is owned by `bin/fm-task-usage.mjs` and identified by `fm-task-usage.v3`.
It reports task identity, configured runtime and model, actual model totals, tokens, cost, calls, sessions, and duration, with `correlation.attribution` set to `session-stamp` and the measured session sources retained.
Model names and model totals are emitted from the same ordered collection, including across runtime switches.
`bin/fm-teardown.sh` saves `data/<id>/usage.json` before deleting volatile task metadata, and snapshot capture appends lifecycle evidence and queues derived effort-store ingestion.
Snapshot persistence stays synchronous before volatile metadata removal; derived ingestion follows the asynchronous reporting and retry contract in [`effort-store.md`](effort-store.md).
Legacy snapshots remain readable without being rewritten or backfilled.

Usage queries are best effort and bounded by `FM_TASK_USAGE_TIMEOUT` (default 60 seconds).
Full-history session queries can exceed the former 15-second limit on large stores, so final capture allows a longer bounded wait.
The fleet snapshot uses its shorter `FM_FLEET_USAGE_TIMEOUT` and may serve an existing reading marked `stale:true` when a fresh reading is unavailable.
Cleanup removes the volatile usage cache while preserving the durable snapshot.
The live demonstration of two sequential dispatched tasks sharing a reused local copy has not yet been observed, nor has an improved live capture rate; both require dispatches after deployment.
