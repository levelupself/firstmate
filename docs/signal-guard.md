# Crew signal guard

This document is the authoritative contract for the crew signal guard.
`bin/fm-signal-command-policy.mjs` is the single decision owner.
`bin/fm-signal-pretool-check.sh` is the stable harness transport and output renderer.
`bin/fm-spawn.sh` installs the guard into every crew and scout launch on the harnesses listed under [Harness coverage](#harness-coverage) and sets the process-scope marker the guard verifies against.

## Why this exists

A crew session runs in a pane of the shared terminal server, so it can signal any process its user owns, including the processes every other worker depends on.
One crew signalled the parent of every process whose command line matched a pattern (`ps ... | grep ... | awk '{print $1, $2}' | while read p pp; do kill $pp $p; done`), and that single signal reached the per-user systemd manager.

The mechanism is ordinary process bookkeeping:

- A background job that outlives the tool call that started it is orphaned when that call's shell exits, and the kernel reparents it to its nearest ancestor that set `PR_SET_CHILD_SUBREAPER`.
- The Herdr server, Treehouse, and the agent do not set that attribute, while a systemd user manager does.
  When the Herdr server runs as a user unit, every orphan from every pane becomes a direct child of the user manager.
  [`verification/signal-guard.md`](verification/signal-guard.md) records a live probe of that adoption.
- The matched orphan was the crew's own earlier background job, so its "parent" was the user manager.
  On `SIGTERM` a systemd user manager starts `exit.target` (systemd(1)), which stops every user unit, including the Herdr server's unit, and then exits.
  Every pane died with the server, and the manager stayed down until it was started again.

Nothing in Herdr or the user manager refuses such a signal, so the refusal has to happen before the command runs.

## Rule: prove the target is the session's own

The guard is an allow rule, not a deny list.
Every signal target must resolve, before the command runs, to a process inside this session's own process tree:

- a live descendant of the agent process, or
- a process whose environment carries this session's process-scope marker, which is how an orphaned background job is still recognized after reparenting.

The agent process itself and every ancestor of the checking hook - the pane shell, the terminal server, the service manager, init - are always denied.

An allow rule is used because the set of processes a crew must not touch is open-ended: the service manager, the terminal server, other panes, other crews, the operator's own terminal, and unrelated user processes.
A deny list of known-dangerous targets or command shapes would keep leaking, while a target that is provably the session's own is safe however it was found.

Ancestry alone cannot carry the rule, because the most common legitimate case breaks it: a job started in one tool call is orphaned when that call's shell exits and is no longer a descendant of the agent.
Session and process-group ids do not help either, because Claude runs each Bash call in its own session, so an orphan's session id names a shell that no longer exists.
The environment marker is inherited across `fork` and `exec` and survives reparenting.

### Process-scope marker

`bin/fm-spawn.sh` mints a fresh token `<task-id>.<random>` for every crew or scout incarnation and places `FM_PROC_SCOPE=<token>` as an assignment on the agent command of the verified launch templates.
The agent and everything it starts inherit it; the pane shell above the agent never carries it.
The same token is written into the per-task hook wiring as `--scope <token>`.

The policy reads its own ancestry from the process table and takes the session root to be the topmost process of the contiguous run of ancestors whose `/proc/<pid>/environ` carries the token.
When no ancestor carries it, the guard cannot verify a literal or PID-file target and denies it with `signal-no-scope`.
A raw escape-hatch launch command and a secondmate launch carry no marker.

### Target forms

| Form | Treatment |
| --- | --- |
| Literal PID, such as `kill 4242` or `kill -TERM 4242` | Verified against the live process table. |
| Literal process group, such as `kill -- -4242` | Allowed only when the group exists and every member passes the PID check. |
| `$!`, a variable assigned only from `$!` in the same command, a job spec such as `%1`, or `$(jobs -p)` | Allowed without lookup, because each names a child of the command's own shell. |
| `"$(cat /abs/job.pid)"` or `$(< /abs/job.pid)` with a literal absolute path | The file is read at check time; every PID in it is verified. An unquoted leading `~/` expands to the home directory; relative paths and quoted tilde paths are denied as unprovable. |
| Any other run-time value: `$PPID`, a `read`, `for`, or other loop variable, `$(pgrep ...)`, `$(pidof ...)`, a `ps` column, a name operand, or `xargs kill` and `find -exec kill` | Denied as unprovable. |
| `kill -1` or `kill 0` | Denied: every process of the user, or the caller's whole process group. |
| `pkill`, `killall`, `skill`, `killall5`, and `fuser -k` | Denied: they choose targets by name, pattern, user, or resource. |
| Signal `0` (`kill -0`, `kill -s 0`) and signal listings (`kill -l`) | Allowed: no signal is delivered, except that any `--timeout` disables the signal-zero exemption and requires target verification. |

A signal send is found at every executed command position: pipeline stages, lists, loop and conditional bodies, subshells and brace groups, command substitutions, `sh`/`bash -c` payloads, shell heredocs and here-strings, `eval` and `trap` payloads, and behind the wrappers `env`, `sudo`, `doas`, `exec`, `command`, `builtin`, `nohup`, `timeout`, `nice`, `setsid`, `stdbuf`, `ionice`, `time`, `unbuffer`, and `xargs`.
Expanded executable payloads in shell `-c`, here-strings, `eval`, `trap`, and `env -S` are denied as unprovable when their text or substitutions mention a signal tool; literal payloads are analyzed recursively.
All `find -exec/-execdir/-ok/-okdir` commands are inspected recursively, and command substitutions in unquoted-delimiter heredocs are inspected for every consumer.
Quoted-delimiter heredocs remain literal data unless consumed as shell programs.
Shell lexing and command positions come from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification; this guard never evaluates or runs any byte of the command.

## Deny codes

Every deny carries one stable code in square brackets, then why the command was refused and how to signal safely.

| Code | Meaning |
| --- | --- |
| `signal-unprovable-target` | A target is computed at run time, so it cannot be proven to be the session's own. |
| `signal-by-name` | The tool selects targets by name or pattern. |
| `signal-broadcast` | The target is `-1` or `0`. |
| `signal-outside-session` | A literal, group, or PID-file target resolved outside the session's own tree; the detail names the PID and why. |
| `signal-no-scope` | No ancestor carries the session's marker, so a literal or PID-file target cannot be verified. |
| `signal-unclassifiable` | The command mentions a signal tool in syntax the shared lexer cannot tokenize. |
| `signal-unverifiable` | The process table, Node, or the policy owner was unavailable. |

The safe path every deny teaches is: record the PID when the job starts (`cmd & echo $! > /abs/job.pid`), then signal only that PID (`kill "$(cat /abs/job.pid)"`), or use `$!` within the same command.

## Fail-closed scope

The transport fast-allows any command whose quote-stripped text contains neither `kill` nor `fuser` and no ANSI-C or locale quoting marker, so ordinary commands never start Node and a broken runtime never blocks them.
Once that prefilter matches, the guard fails closed: unparseable syntax, a missing or failing policy runtime, and an unreadable process table all deny.
This is the opposite of the cd-guard's fail-open choice (`docs/cd-guard.md`), because a missed signal here can take down every worker, while a false deny only costs rewriting one command.
An empty or unparseable hook payload carries no command and allows.

## Accepted boundaries

- The guard sees shell command text only.
  A signal sent from a program or script the command runs, such as Python's `os.kill` or a shell script file, is not inspected.
- A process that drops its environment (`env -i`, a systemd service started on its behalf) loses the marker and is allowed only while it is still a live descendant of the agent.
- The marker is read from `/proc/<pid>/environ`; on a host without procfs only the descendant rule applies.
- A PID file is trusted as the session's own record of what it launched; the guard verifies the PIDs inside it, not who wrote it.
- The check runs before the command, so PID reuse between the check and the signal is not covered.
- Service-manager operations such as `systemctl --user stop`, `systemctl --user exit`, and `loginctl terminate-user` are not process signals and are outside this guard.

## Harness coverage

| Harness | Per-task wiring written by `bin/fm-spawn.sh` | Behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.local.json` PreToolUse `Bash` hook running the transport with `--claude --scope <token>` | Blocks the tool call; stdout stays empty. |
| OpenCode | `tool.execute.before` in `.opencode/plugins/fm-busy-state.js`, passing `--command`, `--scope`, and `--cwd` | Throws, which fails the bash tool call. |
| Pi, pi-signed | `tool_call` handler in `state/<id>.pi-ext.ts`, passing `--command`, `--scope`, and `--cwd` | Returns `{block: true}` with the deny reason. |
| Codex | None: firstmate-launched Codex workers did not fire per-task lifecycle hooks, so a per-task pre-tool hook has no verified delivery path. | Not guarded. |
| Grok, Kimi | None: Grok loads a project hook only after a hook-trust grant firstmate cannot make without editing Grok's managed trust store, and Kimi hooks are global configuration, so a crew hook for either would change the user's global harness settings. | Not guarded. |
| Cursor | None: its project hooks live in `<worktree>/.cursor/hooks.json`, a path a project may track. | Not guarded. |
| Muse | None: its hook engine is disabled in the default build. | Not guarded. |

Every templated crew and scout launch carries the marker, including on unguarded harnesses, so a later hook for those harnesses needs only its wiring.
On an unguarded harness the standing signal rule in every ship and scout brief (`bin/fm-brief.sh`) is the only defense.

## Containment boundary

The guard removes the trigger on guarded harnesses: when the terminal server runs under the user manager, both are ancestors of every crew, and ancestors are always denied whatever the command looks like.
It cannot remove the blast radius, which is a host-level property: while the Herdr server is a user unit and nothing below the user manager reaps orphans, any process in any pane that signals an orphan's parent through a path this guard does not see still reaches the user manager.
Placing each crew pane in its own transient scope would not help, because a scope changes the cgroup, not the ancestry the kernel uses for reparenting, and a scope under the user manager is stopped together with it.
Two changes would contain it, and both are outside firstmate's tracked code:

- Run the Herdr server's unit under a small orphan-reaping subreaper, so orphans from panes are adopted by that reaper instead of the user manager.
  This is a change to the host's Herdr service unit.
- Launch every crew agent under its own orphan-reaping subreaper, so "the parent" of a crew's orphan is that crew's own reaper.
  This changes the foreground process of every pane, which terminal-server agent detection and harness readers depend on, so it needs live verification across every harness and runtime backend before it could ship.

## Validation

`tests/fm-signal-pretool-check.test.sh` owns the acceptance matrix: the exact incident command denied through both transports, a recorded own-PID stop allowed in every supported form, an orphaned own job allowed only through its marker, a marker-stripped live descendant allowed through ancestry, ancestors and strangers denied, process groups, every by-name and run-time-derived form, broadcast targets, harmless forms, unparseable syntax, a missing marker, the transport output contract, a missing runtime, and the Claude, OpenCode, and Pi wiring that `bin/fm-spawn.sh` generates.
It uses only real processes the suite starts itself and touches no Herdr session.

```sh
node --check bin/fm-signal-command-policy.mjs
bin/fm-lint.sh
tests/fm-signal-pretool-check.test.sh
```

Dated live evidence - the user-manager orphan probe and the live Claude run - is recorded in [`verification/signal-guard.md`](verification/signal-guard.md).
