# Model gut-check verification

Repeatable evidence for the harness-dependent facts `bin/fm-model-bench.sh` relies on.
Current behavior and rationale are owned by [`../model-bench.md`](../model-bench.md); this page records evidence only.

Date: 2026-09-09.
Harnesses: codex-cli 0.153.4, Claude Code 2.1.267.
Platform: Linux 6.18 (WSL2), GNU bash 5.

## What is harness-dependent

Three facts per harness come from what the vendor emits and can change with a release:

1. Where the trust store is and what shape an entry takes: codex `[projects."<abs path>"] trust_level = "trusted"` in `config.toml`; claude `projects.<abs path>.hasTrustDialogAccepted = true` in `.claude.json`.
2. That trust keyed on the main repository root extends to a linked worktree, so the arm's clone root is the right key.
3. Where the session record is, that it names the working directory, and how it brackets turns and reports consumption: codex `session_meta.payload.cwd`, `turn_context.payload.model`, `event_msg` `task_started` / `task_complete` / `turn_aborted` with `duration_ms`, and `event_msg token_count info.total_token_usage`; claude the transcript under `projects/<encoded cwd>/`, `cwd` on every record, `assistant.message.model` and `message.usage` (one row per content block sharing a `requestId`), and `system/turn_duration` with `durationMs`.

## Portable regression

`tests/fm-model-bench.test.sh` pins the reader against `tests/fixtures/model-bench/` (recorded shapes from the versions above, sanitised to `/work/arm`), the independence check, and the dry-run refusals.

```console
$ bash tests/fm-model-bench.test.sh | tail -3
ok - run refuses a firstmate-owned environment variable, a missing feasibility statement, and a single arm
ok - report confirms each arm's model from its own record, measures from the record, and voids the copying arm
ok - report refuses to present numbers for an arm whose running model is not confirmed
```

## Live guard

`tests/fm-model-bench-live-e2e.test.sh` (family `live-harness-optin`) runs the tool for real on a private tmux server: a scratch project, one arm per installed harness, a task whose output cannot be identical across arms, then asserts every arm reached `done` (a consumed launch or a trust dialog would not), its running model was confirmed from its own record and equals the request, active time and tokens are positive, the independence verdict is `independent`, the branch landed in the arm's private source repository, and `bin/fm-teardown.sh` accepted every arm as landed work.
Refresh it after every codex or claude upgrade:

```console
$ FM_MODEL_BENCH_LIVE_E2E=1 bash tests/fm-model-bench-live-e2e.test.sh | tail -4
2026-09-10T03:36:49Z status: a1=done a2=done
2026-09-10T03:36:51Z waiting for the final turn of a1 a2 to close in the session record
...
ok - a1: codex ran gpt-6-astra, active 41171ms, 155061 tokens, independent, pushed fm/mb-live-3caa-a1
ok - a2: claude ran claude-haiku-4-5-20251001, active 28293ms, 339356 tokens, independent, pushed fm/mb-live-3caa-a2
ok - codex codex-cli 0.153.4 claude 2.1.267 (Claude Code) live guard: every installed harness launched pre-trusted, confirmed its model from its own record, and landed its branch
```

The rendered table from that run:

```
arm  harness  requested                  confirmed                  active  tokens (in/cached/out)           state  independence  branch
a1   codex    gpt-6-astra                gpt-6-astra                41s     155,061 (154,456/138,624/605)    done   independent   fm/mb-live-3caa-a1
a2   claude   claude-haiku-4-5-20251001  claude-haiku-4-5-20251001  28s     339,356 (337,388/318,554/1,968)  done   independent   fm/mb-live-3caa-a2
```

## Trust keyed on the main repository root (2026-09-09)

Established by hand before the tool existed, driving each harness in a tmux pane:

- A scratch repository `R` was trusted in the harness store; `codex --dangerously-bypass-approvals-and-sandbox '<prompt>'` launched in linked worktree `W2` of `R` started the prompt with no dialog, and `claude --dangerously-skip-permissions '<prompt>'` launched in linked worktree `W1` of `R` did the same, recording `lastSessionId` on `R`'s entry rather than creating one for `W1`.
- A fresh untrusted clone `C` of `R` produced codex's `Do you trust the contents of this directory?` dialog before any prompt ran, which is the first-run prompt requirement 2 in `../model-bench.md` exists for.

## Settle wait (2026-09-09)

The first live run reported claude's arm as `0s (+22s open)`: the report ran immediately after the terminal status line, and claude writes its `turn_duration` record only once the turn that appended that line ends.
`run` now waits (bounded by `--settle`) for each arm's session record to close the turn containing the milestone before reporting; the second run above shows the closed bracket.
