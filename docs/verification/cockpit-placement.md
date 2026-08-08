# Cockpit placement verification

Audience: maintainer verification.

This record holds the reusable Herdr evidence the cockpit's worker placement depends on.
`bin/backends/herdr.sh` owns the implementation, [`docs/herdr-backend.md`](../herdr-backend.md) "Watching and task containers" owns the product behavior, and `tests/fm-cockpit-herdr-e2e.test.sh` owns real-server coverage.
[`docs/verification/cockpit-fleet-layout.md`](cockpit-fleet-layout.md) holds the separate geometry evidence.

Verified on 2026-08-07 against herdr 0.8.0 on Linux, in the isolated `fm-lab-115-exact-3443340-18331` session provisioned through `bin/fm-herdr-lab.sh` with the default-session tripwire.
Every Herdr call below was made through the lab helper's `run` subcommand, which appends a trailing `--session <lab>` to each call.
The `scroll` objects were removed from the `pane_info` and `root_pane` bodies because they are terminal geometry noise unrelated to this guarantee; everything else is verbatim.

A `probe` workspace was created first as scaffolding, giving the ids `w1`, `w1:t1`, and `w1:p1`; the transcript starts at the operation under test.

## Creating a labelled tab leaves that tab's root pane unlabelled

```sh
$ herdr --version
herdr 0.8.0

$ herdr tab create --workspace w1 --cwd /tmp --label fm-peer-one --no-focus
{
  "id": "cli:tab:create",
  "result": {
    "root_pane": {
      "agent_status": "unknown",
      "cwd": "/tmp",
      "focused": false,
      "foreground_cwd": "/tmp",
      "pane_id": "w1:p2",
      "revision": 0,
      "tab_id": "w1:t2",
      "terminal_id": "term_65873835bebf92",
      "workspace_id": "w1"
    },
    "tab": {
      "agent_status": "unknown",
      "focused": false,
      "label": "fm-peer-one",
      "number": 2,
      "pane_count": 1,
      "tab_id": "w1:t2",
      "workspace_id": "w1"
    },
    "type": "tab_created"
  }
}

$ herdr pane get w1:p2
{
  "id": "cli:pane:get",
  "result": {
    "pane": {
      "agent_status": "unknown",
      "cwd": "/tmp",
      "focused": false,
      "foreground_cwd": "/tmp",
      "pane_id": "w1:p2",
      "revision": 1,
      "tab_id": "w1:t2",
      "terminal_id": "term_65873835bebf92",
      "terminal_title": "fungiman@appa: /tmp",
      "terminal_title_stripped": "fungiman@appa: /tmp",
      "workspace_id": "w1"
    },
    "type": "pane_info"
  }
}

$ herdr pane rename w1:p2 fm-peer-one
{
  "id": "cli:pane:rename",
  "result": {
    "pane": {
      "agent_status": "unknown",
      "cwd": "/tmp",
      "focused": false,
      "foreground_cwd": "/tmp",
      "label": "fm-peer-one",
      "pane_id": "w1:p2",
      "revision": 1,
      "tab_id": "w1:t2",
      "terminal_id": "term_65873835bebf92",
      "terminal_title": "fungiman@appa: /tmp",
      "terminal_title_stripped": "fungiman@appa: /tmp",
      "workspace_id": "w1"
    },
    "type": "pane_info"
  }
}

$ herdr pane get w1:p2
{
  "id": "cli:pane:get",
  "result": {
    "pane": {
      "agent_status": "unknown",
      "cwd": "/tmp",
      "focused": false,
      "foreground_cwd": "/tmp",
      "label": "fm-peer-one",
      "pane_id": "w1:p2",
      "revision": 1,
      "tab_id": "w1:t2",
      "terminal_id": "term_65873835bebf92",
      "terminal_title": "fungiman@appa: /tmp",
      "terminal_title_stripped": "fungiman@appa: /tmp",
      "workspace_id": "w1"
    },
    "type": "pane_info"
  }
}
```

Before the rename, the pane object has no `label` key at all; the field is absent rather than an empty string.
`--label` names the tab only, and an explicit rename gives the pane its own label.
That distinction is load-bearing, because a tab label and a pane label are read by different callers.
`fm_backend_herdr_cockpit_focus_place` resolves a sidebar selection by reading the focused pane's own label and refuses a pane that has none, and `bin/fm-cockpit.sh`'s panel lists parked workers by the same pane label.
`fm_backend_herdr_list_live` is the exception: it finds a worker by pane label *or* by tab label, so it alone survives an unlabelled pane.
The peer-tab spawn path therefore renames the root pane after creating the tab, exactly as the viewport path renames the pane it splits.

A fake that fills the root pane's label in on `tab create` hides all of this, so `tests/fm-cockpit.test.sh`'s fake reproduces the real shape: labelled tab, unlabelled root pane, and a `tab list` derived from the tabs that exist rather than a fixed stub.
