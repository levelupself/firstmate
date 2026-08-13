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

Verified on 2026-08-13 through the isolated Herdr cockpit command path.

```sh
tests/fm-cockpit.test.sh
```

The executable regression created the default three-pane region from a launcher checkout distinct from the durable home, captured the commands accepted by the fake Herdr CLI, and observed a home-relative watcher for every configured section with no launcher-checkout path.

```text
ok - the default region is three equal decisions-first panes announced once before they are applied
ok - config/cockpit-sections chooses how many fleet panes there are and what each one holds
```

The command exited with status 0.

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
