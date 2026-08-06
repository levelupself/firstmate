# Cockpit placement verification

Audience: maintainer verification.

This record holds the reusable Herdr evidence the cockpit's worker placement depends on.
`bin/backends/herdr.sh` owns the implementation, [`docs/herdr-backend.md`](../herdr-backend.md) "Watching and task containers" owns the product behavior, and `tests/fm-cockpit-herdr-e2e.test.sh` owns real-server coverage.
[`docs/verification/cockpit-fleet-layout.md`](cockpit-fleet-layout.md) holds the separate geometry evidence.

Verified on 2026-08-06 against herdr 0.8.0 on Linux, in an isolated `fm-lab-` session provisioned through `bin/fm-herdr-lab.sh` with the default-session tripwire.
Every call below carried the helper's trailing `--session <lab>`, elided here for readability.

## Creating a labelled tab leaves that tab's root pane unlabelled

A spawn that lands on its own peer tab creates the tab with `--label fm-<id>`.

```sh
$ herdr tab create --workspace w1 --cwd . --label fm-peer-one --no-focus
  tab.label       = fm-peer-one
  root_pane.label = []

$ herdr pane get w1:p2
{"pane_id":"w1:p2","label":"","tab_id":"w1:t2"}

$ herdr pane list --workspace w1     # same pane, list view
{"pane_id":"w1:p2","label":"","tab_id":"w1:t2"}
```

`--label` names the tab only.
An explicit rename is the only thing that gives the pane its own label:

```sh
$ herdr pane rename w1:p2 fm-peer-one
$ herdr pane get w1:p2
{"pane_id":"w1:p2","label":"fm-peer-one"}
```

That distinction is load-bearing, because a tab label and a pane label are read by different callers.
`fm_backend_herdr_cockpit_focus_place` resolves a sidebar selection by reading the focused pane's own label and refuses a pane that has none, and `bin/fm-cockpit.sh`'s panel lists parked workers by the same pane label.
`fm_backend_herdr_list_live` is the exception: it finds a worker by pane label *or* by tab label, so it alone survives an unlabelled pane.
The peer-tab spawn path therefore renames the root pane after creating the tab, exactly as the viewport path renames the pane it splits.

A fake that fills the root pane's label in on `tab create` hides all of this, so `tests/fm-cockpit.test.sh`'s fake reproduces the real shape: labelled tab, unlabelled root pane, and a `tab list` derived from the tabs that exist rather than a fixed stub.
