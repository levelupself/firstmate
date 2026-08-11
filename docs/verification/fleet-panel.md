# Fleet panel repaint verification

Audience: maintainer verification.

This record holds reusable evidence for the fleet panel projection and watch-mode repaint guarantees.
The implementation is shared by `bin/fm-fleet-view.sh` and `bin/fm-cockpit.sh`, while `tests/fm-fleet-snapshot-view.test.sh` owns automated readiness agreement, section ordering, height truncation, independent section rendering, and residual-line coverage.
`tests/fm-fleet-view-pane-fit-smoke.test.sh` owns the real-pane fit that a `LINES`-driven fixture cannot reach, because supplying `LINES` takes the explicit-override branch and never measures anything.
`tests/fm-cockpit.test.sh` owns the generated Herdr pane-command guarantee that every section watcher resolves through the durable Firstmate home rather than the launcher's checkout.

The read-only snapshot calls `tasks-axi list` and `tasks-axi ready` once each for the primary home and once each for every readable registered secondmate home during a redraw.
The two primary-home calls measured about 92 ms together locally, so the redraw cost scales as `2 * (1 + readable secondmate homes)` tasks-axi invocations.
The focused regression compares both the snapshot and rendered READY identities directly with `tasks-axi ready`, checks that only open queued dependency blockers enter BLOCKED, and verifies that the displayed counts describe the complete represented lists even when pane-height truncation hides rows.
It also covers the narrower dispatch question READY answers on top of that set: a queued row recording no body and a queued row still naming a `blocked-by` id the backlog no longer carries each render with a reason and stay out of the confirmed-clear count, while both remain present in the rendered READY set and retain the snapshot's `dispatchable` value.

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

## Stable generated watcher command

Verified on 2026-08-13 through both the isolated Herdr cockpit command path and the affected real Herdr frame.

```sh
bash tests/fm-cockpit.test.sh
```

The executable regression created the default three-pane region from a launcher checkout distinct from the durable home, captured the commands accepted by the fake Herdr CLI, and observed a home-relative watcher for every configured section with no launcher-checkout path.
The result repeated on every isolated run with the same home and launcher inputs.
In the real frame, panes `w5:p3B` (`waiting`), `w5:p3C` (`ready`), and `w5:p3D` (`in-flight,blocked`) reached bash prompts after restart because `/home/fungiman/.treehouse/firstmate-5ccb57/4/firstmate/.lab/tools/uvbin/env` no longer existed.
That retained lab still contained `uvcache` but no `uvbin`, tying the failure to the captured disposable-checkout executable path rather than loss of the entire lab.
From the durable home, running `hash -r` followed by `bin/fm-fleet-view.sh --watch --section <names>` in those same panes restored all three immediately without changing layout or focus.
Replacing only the unavailable captured path with the durable home-relative command supplied the counterfactual, while clearing the shell command cache before the restoration disconfirmed cached resolution as the cause.

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
