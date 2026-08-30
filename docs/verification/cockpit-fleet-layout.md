# Cockpit fleet layout verification

Audience: maintainer verification.

This record holds the reusable Herdr evidence the cockpit fleet region's geometry depends on.
`bin/backends/herdr.sh` owns the implementation, [`docs/herdr-backend.md`](../herdr-backend.md) "Watching and task containers" owns the product behavior, and `tests/fm-cockpit.test.sh` owns automated coverage.

Verified on 2026-08-06 against herdr 0.8.0 on Linux, in an isolated `fm-lab-` session provisioned through `bin/fm-herdr-lab.sh` with the default-session tripwire.
Every call below carried the helper's trailing `--session <lab>`, elided here for readability.

## Split direction is limited to right and down

```sh
$ herdr pane split --help | grep -A1 -- --direction
--direction <DIRECTION>
[possible values: right, down]
```

A banner above or left of the supervisor is therefore unreachable by splitting alone.

## The split ratio sizes the first child, not the new pane

The supervisor pane `w1:p1` was split downward at ratio 0.28 in a 23-row area.

```sh
$ herdr pane split w1:p1 --direction down --ratio 0.28 --no-focus
$ herdr pane layout --pane w1:p1
{"split":{"direction":"down","id":"split_0_root","ratio":0.28,...},
 "panes":[{"pane":"w1:p1","h":6,"w":54},{"pane":"w1:p2","h":17,"w":54}]}
```

The original pane received 6 of 23 rows and the new pane 17, so `--ratio` names the first child's share.
A fleet-last order can pass `1 - <fleet share>` directly; a fleet-first order passes the fleet share and then reorders.

## Splitting the newest child repeatedly divides the band into equal panes

Each split's rect is the previous split's remainder, so the share that leaves the pane being split with one N-th of the whole band is `1 / (panes still to place)`.
For three panes that is 1/3 and then 1/2.
The 28% band above was divided across its own axis with those two ratios.

```sh
$ herdr pane split w1:p3 --direction right --ratio 0.3333 --no-focus
"w1:p4"
$ herdr pane split w1:p4 --direction right --ratio 0.5000 --no-focus
"w1:p5"
$ herdr pane layout --pane w1:p2
{"panes":[{"pane_id":"w1:p3","rect":{"height":6,"width":18,"x":26,"y":1}},
          {"pane_id":"w1:p4","rect":{"height":6,"width":18,"x":44,"y":1}},
          {"pane_id":"w1:p5","rect":{"height":6,"width":18,"x":62,"y":1}},
          {"pane_id":"w1:p2","rect":{"height":17,"width":54,"x":26,"y":7}}],
 "splits":[{"direction":"down","id":"split_0_root","ratio":0.28},
           {"direction":"right","id":"split_1_0","ratio":0.3333},
           {"direction":"right","id":"split_2_01","ratio":0.5}]}
```

The three fleet panes took 18 columns each of the 54-column band and kept the band's 6 rows, while the supervisor `w1:p2` kept its own 17 rows at full width.
Creation order is also screen order left to right, and the later splits are nested inside the band rather than against the supervisor, so dividing the band never resizes or rebuilds the pane holding the supervisor.
At the supported maximum of six panes, the smallest share is 1/6 = 0.1667, still above the 0.1 floor Herdr silently clamps to.

## Drawn geometry remains authoritative when the pty diverges

Verified on 2026-08-15 against Herdr 0.7.3 in a guarded lab session.
`pane layout` returned each pane's current drawn rectangle, including an 18-column by 6-line fleet pane, while the process pty could independently retain a larger winsize.
The cockpit passes `bin/fm-herdr-pane-geometry.sh` to every fleet painter, and the painter invokes it before every redraw rather than caching creation-time geometry.

The portable visual-path counterfactual is executable without relying on `herdr pane read`, whose logical-line output masks physical wrapping:

```sh
bash tests/fm-fleet-view-pane-fit-smoke.test.sh
```

It places the public fleet-view interface in a real terminal rectangle, deliberately changes that pane's pty to 54 columns by 17 lines while retaining an 18-column by 6-line drawn budget, and verifies that no rendered physical row or frame exceeds the drawn geometry.
The same suite verifies that the overflow-summary row is width-clipped and cannot wrap and scroll a correctly height-budgeted frame.
The Herdr integration path remains covered by `tests/fm-cockpit.test.sh`; the other supported runtime backends do not create or paint a native cockpit fleet region and retain their existing plain-panel fallback.

## Geometry failure has a bounded terminal path

Verified on 2026-08-30 against Herdr 0.8.0 in a guarded lab session and with the focused watch-mode fixtures.
The geometry probe treats a missing exact pane or missing authoritative foreground cwd as permanent, while a failed layout read for a still-live pane remains transient.
The fleet painter evicts a permanently unavailable pane after the first classified read, retries a transient failure at most three consecutive times, resets the counter after recovery, and evicts once when that boundary is exhausted.
Every terminal path names the exact pane loudly before issuing its single close.

```sh
bash tests/fm-herdr-pane-geometry.test.sh
bash tests/fm-fleet-snapshot-view.test.sh
HERDR_LAB_HELPER=/absolute/path/to/bin/fm-herdr-lab.sh \
  bash tests/fm-public-followup-herdr-isolation-e2e.test.sh
```

The focused probe distinguished a deleted cwd from a transient layout failure, the watch suite observed recovery on the third read with no close and one exact-pane close for both terminal cases, and two full public-followup runs left the guarded lab's pane inventory byte-identical to its baseline.

## The drawn rectangle and the pty diverge in BOTH directions

Verified on 2026-08-29 against herdr 0.8.0 on Linux, in an isolated `fm-lab-` session provisioned through `bin/fm-herdr-lab.sh` with the default-session tripwire.
A supervisor pane was split into a band of three fleet panes, then each pane was asked for its own `stty size` while `pane layout` reported the same panes' drawn rectangles.

```
pane=w1:p1 rect={"height":17,"width":54,"x":26,"y":1}   stty (rows cols) = 23 53
pane=w1:p2 rect={"height":6,"width":18,"x":26,"y":18}   stty (rows cols) = 23 54
pane=w1:p3 rect={"height":6,"width":18,"x":44,"y":18}   stty (rows cols) = 17 54
pane=w1:p4 rect={"height":6,"width":18,"x":62,"y":18}   stty (rows cols) = 17 54
```

The band panes show the already-recorded direction: a stale pty three times wider than the rectangle Herdr actually draws.
`w1:p1` shows the opposite one, which was not previously recorded: a drawn rectangle of 54 columns over a pty that wraps at 53.
A painter that trusts the drawn rectangle alone therefore emits rows one column too wide for the terminal that renders them, and the wrap multiplies the frame's height until it scrolls.
`bin/fm-fleet-view.sh` takes the smaller of the two on every redraw for that reason, and `tests/fm-fleet-view-pane-fit-smoke.test.sh` covers both directions in a real terminal.

## A fleet painter outlives the code that launched it

Observed on 2026-08-29 on the same host, outside the lab, against a cockpit that had been running since 2026-08-13.

```sh
$ ps -eo pid,etimes,args | grep fm-fleet-view
3599816 1374489 bash bin/fm-fleet-view.sh --watch --section waiting
3600904 1374485 bash bin/fm-fleet-view.sh --watch --section ready
3603856 1374481 bash bin/fm-fleet-view.sh --watch --section in-flight,blocked
$ for t in 0 1 2; do stty -F /dev/pts/$t size; done
10 23
10 67
10 59
```

Each painter owned its own pty, so the repeated and interleaved rows the operator saw were not concurrent painters sharing a pane.
They were launched before `--geometry-command` existed, so each sized its frame to those pty numbers rather than to its drawn rectangle, and the panes had never been rebuilt because every other liveness check still passed.
`fm_backend_herdr_cockpit_fleet_state` now requires the drawn-size binding for exactly this reason, so such a painter is reported as its own named failure instead of as a live region.

## Swapping preserves pane identity and a registered agent

`w1:p1` held a registered agent before the swap.

```sh
$ herdr pane swap --source-pane w1:p1 --target-pane w1:p2
{"changed":true,"source_pane_id":"w1:p1","target_pane_id":"w1:p2"}
$ herdr pane layout --pane w1:p1
{"split":{"direction":"down","ratio":0.28,...},
 "panes":[{"pane":"w1:p2","h":6,"w":54},{"pane":"w1:p1","h":17,"w":54}]}
$ herdr agent get w1:p1
{"pane_id":"w1:p1","agent":"firstmate","agent_status":"idle","tab_id":"w1:t1","workspace_id":"w1"}
```

The two panes exchanged slots while both pane ids, the tab, the workspace, and the registered agent survived unchanged.
A swap is therefore a reposition, never a close, replacement, or re-split of the pane holding the supervisor, and it keeps the recorded `head_pane_id` valid.

## Herdr does not reject an out-of-range ratio

```sh
$ herdr pane split w1:p1 --direction right --ratio 0.02 --no-focus
"w1:p3"
$ herdr pane layout --pane w1:p1
[{"direction":"down","ratio":0.28},{"direction":"right","ratio":0.1}]

$ herdr pane split w1:p1 --direction right --ratio 1.5 --no-focus
"w1:p4"
```

A 0.02 request was silently clamped to 0.1 and a 1.5 request produced a pane rather than an error, so the adapter validates the configured ratio itself and refuses anything outside 0.10-0.90.

## Zoom exists; hover, floating panes, and overlays do not

```sh
$ herdr pane --help | grep -ciE "hover|float|overlay"
0
$ herdr --help | grep -ciE "hover|float|overlay"
0
$ herdr pane zoom --help | head -3
Toggle or set pane zoom

Usage: herdr pane zoom [OPTIONS] [PANE_ID]
```

The full pane command list is `list, current, get, layout, process-info, neighbor, edges, focus, resize, zoom, read, rename, split, swap, move, close, send-text, send-keys, wait-output, run, report-agent, report-agent-session, release-agent, report-metadata`.
No hover, floating-pane, or overlay primitive exists at 0.8.0, so a hover-to-expand fleet view is unavailable and is not emulated.
