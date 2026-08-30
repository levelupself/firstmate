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
The bound fleet painter evicts a permanently unavailable pane after the first classified read, retries a transient failure at most three consecutive times, resets the counter after recovery, and evicts once when that boundary is exhausted.
Each bound terminal path names the exact pane loudly before issuing its single close, while standalone watch mode stops without pane mutation.

```sh
bash tests/fm-herdr-pane-geometry.test.sh
bash tests/fm-fleet-snapshot-view.test.sh
HERDR_LAB_HELPER=/absolute/path/to/bin/fm-herdr-lab.sh \
  bash tests/fm-public-followup-herdr-isolation-e2e.test.sh
```

The focused probe distinguished a deleted cwd from a transient layout failure, the watch suite observed recovery on the third read with no close and one exact-pane close for both terminal cases, and two full public-followup runs left the guarded lab's pane inventory byte-identical to its baseline.

## Deleted fixture directories caused the repeated redraw failure

Verified on 2026-08-30 from the public-followup startup reproduction and its guarded Herdr and non-Herdr counterfactuals.
Inherited `HERDR_ENV` together with pane, session, workspace, and tab context triggered session-start cockpit adoption during public-followup startup.
Adoption remained masked unless the inherited workspace was the unique firstmate workspace and its authoritative supervisor was live.
Deleting the fixture directory while its cockpit pane processes remained live left those processes in deleted foreground working directories.
The fleet painters then repeated geometry-unavailable redraws because the panes remained live while authoritative cwd lookup could no longer succeed.
The healthy comparison supplied explicit non-Herdr tmux fixture context and left the guarded lab pane inventory unchanged.
A workspace-label mismatch created no panes, which disconfirmed unguarded adoption from inherited Herdr context alone.
A dead supervisor also made adoption refuse, which independently confirmed the live-authority gate.

### Red-first provenance

The public-followup reproduction ran against code under test at exact full SHA `6b6c5059d901537f5926ea1ce28f06630e04ba7b` and produced this exact pre-fix failure:

```text
not ok - public-followup run 1 leaked live cockpit panes or deleted-cwd processes
```

Its proof-file list is `tests/fm-public-followup-herdr-isolation-e2e.test.sh`, `tests/fm-public-followup.test.sh`, `bin/fm-session-start.sh`, `bin/fm-cockpit.sh`, and `bin/backends/herdr.sh`.
The two test files contained then-new uncommitted fixture and assertion content, so the observation binds the code under test to the stated SHA but does not overclaim clean-commit provenance for those test bytes.

The focused geometry reproduction ran against code under test at exact full SHA `6b6c5059d901537f5926ea1ce28f06630e04ba7b` and produced this exact pre-fix failure:

```text
not ok - a missing authoritative foreground cwd must be permanent: expected exit 64, got 0
```

Its proof-file list is `tests/fm-herdr-pane-geometry.test.sh` and `bin/fm-herdr-pane-geometry.sh`.
The test file contained then-new uncommitted fixture and assertion content, so this observation also binds the code under test to the stated SHA without claiming clean-commit provenance for the test bytes.

The first broad `tests/fm-fleet-snapshot-view.test.sh` watch attempt failed before reaching the new behavior because the custom geometry fixture basename violated the existing strict painter-ownership contract in `bin/backends/herdr.sh`.
Changing that basename to `fm-herdr-pane-geometry.sh` was a non-behavioral fixture correction.
No meaningful broad-watch red result existed before the first post-implementation run.
The repository context for that attempt was exact full SHA `3c71d0589eedbfef57e6748a94ccf9c40f9110af`, and its proof-file list is `tests/fm-fleet-snapshot-view.test.sh`, `bin/fm-fleet-view.sh`, and `bin/backends/herdr.sh`.
The test file was modified in the active review round, so the attempt is chronology rather than clean-commit verification.

### Accepted authoritative pre-closure inventory

The authoritative external pre-closure record was captured in repository context exact full SHA `6b6c5059d901537f5926ea1ce28f06630e04ba7b` and supplied after the affected panes had been closed.
Its proof-file list is this durable record, `docs/verification/cockpit-fleet-layout.md`; the underlying live state was external and is not reconstructible repository evidence.
No live pane may be queried or closed to recreate it.

The 18 deleted-cwd panes were all in tab `w5:t3`: `w5:p9F`, `w5:p9G`, `w5:p9H`, `w5:p9J`, `w5:p9K`, `w5:p9M`, `w5:p9N`, `w5:p9P`, `w5:p9Q`, `w5:p9R`, `w5:p9S`, `w5:p9T`, `w5:p9V`, `w5:p9W`, `w5:p9X`, `w5:p9Y`, `w5:p9Z`, and `w5:p90`.
They came from three fixture runs and six deleted cwd paths: `/tmp/fm-public-followup.gx6nBn/startup-off`, `/tmp/fm-public-followup.gx6nBn/startup-on`, `/tmp/fm-public-followup.PcXNA9/startup-off`, `/tmp/fm-public-followup.PcXNA9/startup-on`, `/tmp/fm-public-followup.iW1qXN/startup-off`, and `/tmp/fm-public-followup.iW1qXN/startup-on`.
Each run created six panes, each cwd held three panes, and every listed cwd was deleted.

The 26 non-deleted orphaned fleet panes were `w5:p1W` in `w5:t93`; `w5:p60`, `w5:p71`, `w5:p72`, `w5:p73`, `w5:p74`, and `w5:p75` in `w5:tBN`; `w5:p8C`, `w5:p8D`, `w5:p8E`, `w5:p8F`, `w5:p8G`, and `w5:p8H` in `w5:tCB`; `w5:p8J`, `w5:p8K`, `w5:p8M`, `w5:p8N`, `w5:p8P`, and `w5:p8Q` in `w5:tCC`; `w5:p8W`, `w5:p8X`, `w5:p8Y`, `w5:p8Z`, `w5:p80`, and `w5:p91` in `w5:tCF`; and `w7:p3` in `w7:t4`.
Their cwd was `/home/fungiman` or `/home/fungiman/firstmate`, no agent was registered, and their labels were only `waiting`, `ready`, and `in-flight,blocked` repeating in threes.
Each six-pane tab was a doubled three-pane fleet-region rebuild.

The legitimate retained cockpit panes were `w5:p3B`, `w5:p3C`, and `w5:p3D` in `w5:t3`.
The 18 deleted-cwd panes and 26 non-deleted orphaned fleet panes were closed externally before independent implementation inspection.
No identity was reconstructed from pane age, naming, or any later state.
The implementation issued zero default-session pane closures.
This section is the single durable owner for the accepted inventory and supplies the same role-neutral provenance and inventory for PR evidence without duplicating the record.

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
