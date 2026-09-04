# Fleet panel repaint verification

Audience: maintainer verification.

This record holds reusable evidence for the fleet panel projection and watch-mode repaint guarantees.
The implementation is shared by `bin/fm-fleet-view.sh` and `bin/fm-cockpit.sh`, while `tests/fm-fleet-snapshot-view.test.sh` owns automated readiness agreement, section ordering, height truncation, independent section rendering, and residual-line coverage.
`tests/fm-fleet-view-project-groups.test.sh` owns project grouping, fair per-project truncation, distinguishing id tails, and the stable no-repository group.
`tests/fm-fleet-view-pane-fit-smoke.test.sh` owns the real-pane fit that a `LINES`-driven fixture cannot reach, because supplying `LINES` takes the explicit-override branch and never measures anything.
`tests/fm-cockpit.test.sh` owns the generated Herdr pane-command guarantee that every section watcher resolves through the tracked code root while receiving the operational home separately through `FM_HOME`.

The read-only snapshot calls `tasks-axi list` and `tasks-axi ready` once each for the primary home and once each for every readable registered secondmate home during a redraw.
The two primary-home calls measured about 92 ms together locally, so the redraw cost scales as `2 * (1 + readable secondmate homes)` tasks-axi invocations.
The focused regression compares both the snapshot and rendered READY identities directly with `tasks-axi ready`, checks that only open queued dependency blockers enter BLOCKED, and verifies that the displayed counts describe the complete represented lists even when pane-height truncation hides rows.
That identity agreement holds for a queue no worker has taken yet.
It also covers the narrower dispatch question READY answers on top of that set: a queued row recording no body and a queued row still naming a `blocked-by` id the backlog no longer carries each render with a reason and stay out of the confirmed-clear count, while both remain present in the rendered READY set and retain the snapshot's `dispatchable` value.
The one row the rendered queue sections withhold from that set is a queued row whose id already has a live task record, which the same regression covers for READY and BLOCKED alongside its appearance under IN FLIGHT.

## Watch-mode repaint leaves no residual rows

Verified on 2026-08-05 in an isolated tmux 3.4 pane on Linux.

The pane ran the production watch command against a fixture that alternated between three-line and one-line frames every 0.05 seconds.
Twenty consecutive pane captures sampled every 0.01 seconds remained nonblank, showed only a complete long or short frame, and showed no residual long-frame lines beneath a short frame.

```sh
tmux -L fm-fleet-visual new-session -d -s fleet-visual -x 45 -y 12 \
  "FM_HOME=\"$VERIFY_HOME\" PATH=\"$VERIFY_HOME/bin:$PATH\" \
  \"$VERIFY_HOME/bin/fm-fleet-view.sh\" --watch 0.05"

for sample in $(seq 1 20); do
  tmux -L fm-fleet-visual capture-pane -p -t fleet-visual:0.0 \
    | sed '/^[[:space:]]*$/d' \
    | awk -v sample="$sample" '
        NR == 1 { first = $0 }
        { count++ }
        END {
          if (count != 1 && count != 3) exit 1
          if (first != "short" && first != "long one") exit 1
          printf "%02d valid\n", sample
        }'
  sleep 0.01
done
```

```text
01 valid
02 valid
03 valid
04 valid
05 valid
06 valid
07 valid
08 valid
09 valid
10 valid
11 valid
12 valid
13 valid
14 valid
15 valid
16 valid
17 valid
18 valid
19 valid
20 valid
```

The observed pane changed directly between complete frames without a visible blank refresh.

## Dispatch records In flight before worker release

Verified on 2026-09-03 against Herdr 0.8.0 in a guarded lab session.

Dispatch publishes `state/<id>.meta`, records the queued backlog row as In flight through `bin/fm-backlog-integrity.sh`, and only then releases the worker by sending its launch command.
The renderer still withholds any queued row whose id appears in the snapshot's live task rows, preserving a safe projection if a legacy or interrupted transition temporarily exposes that combination.

`tests/fm-cockpit-herdr-e2e.test.sh` proves the lifecycle from a real transition rather than a fixture: it writes a dispatchable queued row, waits for the recorded ready pane to display it, dispatches it with `bin/fm-spawn.sh` into the guarded lab, and requires tasks-axi to report the row In flight after the pane drops it.
`tests/fm-fleet-snapshot-view.test.sh` pins the same rule portably for READY and BLOCKED, together with the row's continued appearance under IN FLIGHT.

```sh
bash tests/fm-fleet-snapshot-view.test.sh
HERDR_LAB_HELPER=/absolute/path/to/bin/fm-herdr-lab.sh \
  bash tests/fm-cockpit-herdr-e2e.test.sh
```

```text
ok - ready membership follows the live task records, not the later backlog edit
ok - the blocked queue drops rows a worker already holds
ok - a real dispatch records its in-flight transition and clears the ready pane on its own redraw
```

This dispatch-driven redraw verification was recorded at full SHA `fbeb6d6002924df20a2ef15ad3620409ca2f0100`.
Its proof-file list is `bin/fm-fleet-view.sh`, `bin/fm-fleet-snapshot.sh`, `bin/fm-spawn.sh`, `tests/fm-fleet-snapshot-view.test.sh`, and `tests/fm-cockpit-herdr-e2e.test.sh`.

## Project groups and fair row limits

Verified on 2026-08-29 with the production fleet renderer against a three-project snapshot fixture.

```sh
bash tests/fm-fleet-view-project-groups.test.sh
```

The eleven-row decision pane showed Firstmate, mtg, and psychogenesis headers together.
The noisy psychogenesis group received the same two-row cap as its peers, reported four hidden rows on its own header, and preserved the `alt-cost-rule` and `communal-zone-lifecycle` tails from ids with a long shared prefix.
The quiet mtg group retained its only row.
The same executable check covered READY, IN FLIGHT, and BLOCKED grouping and assigned a record with no repository value to the stable `No repository` group.

```text
ok - narrow fleet decisions group three projects, preserve id tails, and truncate fairly
```

## Stable generated watcher command

Verified on 2026-08-13 through both the isolated Herdr cockpit command path and the affected real Herdr frame.

```sh
bash tests/fm-cockpit.test.sh
```

The executable regression created the default three-pane region with a tracked code root distinct from an isolated operational home, captured the commands accepted by the fake Herdr CLI, and observed a tracked-root watcher and geometry helper for every configured section with no operational-home code path.
The result repeated on every isolated run with the same home and launcher inputs.
In the real frame, panes `w5:p3B` (`waiting`), `w5:p3C` (`ready`), and `w5:p3D` (`in-flight,blocked`) reached bash prompts after restart because `/home/fungiman/.treehouse/firstmate-5ccb57/4/firstmate/.lab/tools/uvbin/env` no longer existed.
That retained lab still contained `uvcache` but no `uvbin`, tying the failure to the captured disposable-checkout executable path rather than loss of the entire lab.
Running `hash -r` followed by the stable tracked root's `bin/fm-fleet-view.sh --watch --section <names>` in those same panes restored all three immediately without changing layout or focus.
Replacing only the unavailable captured path with the stable tracked-root command supplied the counterfactual, while clearing the shell command cache before the restoration disconfirmed cached resolution as the cause.

```text
ok - the default region is three equal decisions-first panes announced once before they are applied
ok - config/cockpit-sections chooses how many fleet panes there are and what each one holds
```

Observed on 2026-08-13: both assertions printed exactly as shown and the command exited with status 0.

## Pane measurement and the head-preserving fit

Verified on 2026-08-06 in an isolated tmux 3.4 pane on Linux, sized to twelve rows to match a cockpit fleet banner.

Both callers measure the pane inside a command substitution, where stdout is a pipe.
A probe gated on `[ -t 1 ]` therefore never runs, and the panel silently rendered against its built-in forty-row fallback: twenty lines were emitted into twelve rows, the terminal scrolled, and the title, `YOUR DECISIONS`, and `READY` were pushed off the top while only the tail remained visible.
`stty size < /dev/tty` and `tput lines` both report the pane's own size regardless of that redirection, which is what the shared probe now uses.

```sh
$ tmux -L fmev new-session -d -s e -x 60 -y 12 "FM_HOME=$H bin/fm-fleet-view.sh --watch 1"
$ tmux -L fmev capture-pane -p -t e:0.0
============================================================
FLEET STATUS
============================================================

YOUR DECISIONS (0)
  None.

READY (0)
  None.

IN FLIGHT (6)
… 9 more rows not shown
```

The frame now fills exactly twelve rows, keeps the head the section ordering exists to protect, and discloses the dropped tail.

A frame sized to exactly fill the pane also requires that painting not terminate the final row with a newline, which would walk the cursor past the bottom, scroll by one, and eat the frame's own first line.
Newlines therefore separate rows rather than terminating them.
`ESC[J` erases from the cursor to the end of the display, so text preceding the cursor on the final row survives and the closing erase still clears every row below.
Twenty consecutive captures of a fixture alternating three-line and one-line frames every 0.05 seconds each showed exactly one complete frame with no residual rows from the longer one.

## Watched-banner ownership inside a cockpit fleet region

Verified on 2026-08-10 against the real herdr 0.8.0 executable, in a guarded non-`default` lab session provisioned by `bin/fm-herdr-lab.sh`.

The accepted verification uses this exact lifecycle scaffold from the repository root.
The trap is installed before provisioning, every inspection goes through `run`, and the deliberate restart uses only `stop` followed by `provision`.

```sh
HERDR_LAB_HELPER=/home/fungiman/.treehouse/firstmate-5ccb57/5/firstmate/bin/fm-herdr-lab.sh
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fleet-watch-owner-reaping)
export HERDR_LAB_HELPER HERDR_LAB_SESSION

cleanup_fleet_watch_lab() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
}
trap cleanup_fleet_watch_lab EXIT

HERDR_LAB_HELPER="$HERDR_LAB_HELPER" \
  HERDR_LAB_SESSION="$HERDR_LAB_SESSION" \
  bash tests/fm-cockpit-herdr-e2e.test.sh

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json

"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
trap - EXIT
```

The executable test installs its own teardown trap before its internal provision, creates the cockpit only through the named lab, routes its Herdr adapter through the helper, and checks that teardown leaves the default fleet byte-identical.
For the record-loss counterfactual, `bash tests/fm-fleet-snapshot-view.test.sh` executes a generation-one watcher, removes its serialized frame record, observes that the watcher exits and releases its lock, then verifies that the replacement generation owns each recorded pane alone.

Two facts about herdr 0.8.0 bound this design and are recorded because the fix depends on them.
Closing a fleet pane already retires its banner, so process reaping is not the gap; and `pane run` types into the pane's shell, so it cannot start a second banner in a pane whose banner is still in the foreground.

```
=== E2: close a fleet pane; is its watcher reaped? ===
  second fleet pane=w1:p3 pids=1686877 1687586
  close: {"type":"ok"}
  pid=1686877 reaped by pane close
  pid=1687586 reaped by pane close
```

The gap is a region rebuild.
Adoption that finds no readable record builds a fresh region and leaves the previous generation's panes untouched, so before this rule every rebuild added a live banner rather than replacing one.

```
=== E4: record lost -> re-adopt builds a SECOND region; old watchers? ===
  new record fleet ids: w1:p5,w1:p6,w1:p7
  old first-pane watchers:
    pid=1686794 STILL PAINTING (unbound)
```

The same rebuild after the rule strands nothing, and the newly recorded panes keep painting.

```
generation 1 fleet panes: w1:p2,w1:p3,w1:p4
generation 1 painter pids: 888733 888983 889036
--- rebuild the region exactly as E4 did (record lost -> re-adopt) ---
generation 2 fleet panes: w1:p5,w1:p6,w1:p7
--- generation 1 painters after the rebuild ---
  pid=888733 retired itself
  pid=888983 retired itself
  pid=889036 retired itself
--- generation 2 painters (must still be painting) ---
  pane=w1:p5 painting pid(s)=890456
  pane=w1:p6 painting pid(s)=890516
  pane=w1:p7 painting pid(s)=890593

RESULT stranded=0 live_bound_panes=3
```

Retirement stops the banner and nothing else: the emptied panes stay on the tab for the operator, which is why the tab still reports seven panes above.

Repaint contention was the first hypothesis and does not survive.
Two banners painting one pane's terminal at 1-second intervals, with different sections and with frames taller than the pane, left exactly one complete board in the pane across repeated captures, because each paint homes the cursor and erases to the end of the display.
Contention therefore costs authorship - the visible board silently alternates between owners - rather than accumulating rows, which is what makes single ownership the guarantee worth enforcing.

```
=== B2: add a SECOND painter with a DIFFERENT frame on the same tty ===
  sample1    rows=20   boards=1   decisions_headers=1
  sample2    rows=20   boards=1   decisions_headers=1
  verdict: STABLE
```

Counting banner processes with a bare process match overstates them roughly twofold: each redraw forks a command substitution that carries the same argv as its parent for the length of one render.
Only the loop process is a banner.

### Supported cleanup after merge

Legacy watchers already running old code cannot learn the new ownership rule.
Before cleanup, print a warning that the obsolete fleet panes will disappear and that focus may move, then close only the pane ids confirmed as absent from the current frame's `fleet_pane_ids`.
The supported interactive path is Herdr's pane close action, not a server or session lifecycle command.
Do not close the recorded head, viewport, or current fleet pane ids.

The guarded lab cleanup used while verifying candidate pane ids is exact and remains isolated from `default`.

```sh
printf '%s\n' \
  'WARNING: confirmed legacy fleet panes will disappear and terminal focus may move.'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane list --workspace "$LAB_WORKSPACE_ID"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane close "$CONFIRMED_LEGACY_PANE_ID"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane list --workspace "$LAB_WORKSPACE_ID"
"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
trap - EXIT
```

For a live post-merge frame, first run the updated `bin/fm-cockpit.sh status`, compare its recorded pane ids with Herdr's visible panes, issue the same warning, and use Herdr's interactive close action only for positively identified legacy fleet panes.
If identity is ambiguous, leave the pane in place rather than guessing.
