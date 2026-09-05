# Linear mirror

firstmate can mirror `data/backlog.md` into Linear as a browsable view, link each task's pull request to its mirrored issue, and refresh that view in place.

`data/backlog.md` stays authoritative for execution.
Linear is a view: reordering or reprioritising there does not reach the backlog.
That split is the captain's decision of 2026-08-02.

**Linear is never a gate.**
Every code path here degrades quietly.
If Linear is unconfigured, unreachable, unauthenticated, or slow, firstmate's
lifecycle continues untouched and the operator is told what did not happen.
Nothing in this feature can prevent a PR from being checked, reported, or merged.

## Configuration

[`configuration.md`](configuration.md#linear-mirror-env) owns the opt-in, supported settings, and defaults.
The key is sent as the bare `Authorization` header value expected by Linear personal API keys; OAuth access tokens use the `Bearer` scheme.

## The join

For ongoing mirror lookups, nothing about firstmate's branch naming is
load-bearing, and it cannot be:
Linear's own branch convention is `<user>/<issue-key>-<slug>`, and firstmate's
branches are `fm/<task-id>`, which can never match.

The join is the **first line of the Linear issue description**, written by the
original mirror as a markdown code span:

```
`firstmate: <task-id>`
```

It is queryable from Linear directly, so the mapping is recoverable with no local
file. Matching is exact on that first line after backticks and whitespace are
stripped: an issue that merely mentions a task id further down its description is
not a join, and the id `004` never matches `004-engine-surface-testers`.

## How Linear links a pull request

Verified against Linear's own GitHub documentation, <https://linear.app/docs/github>,
fetched 2026-08-02. The supported ways to link a PR to an issue are:

1. The branch name, using Linear's generated convention.
2. The issue ID in the **PR title**.
3. A magic word plus the issue ID in the **PR description**.

Also verified on that page, and load-bearing for this design:

- "To link a PR that is already open, modify the PR title or description to link
  an issue." So editing the body of an already-open PR is a supported linking
  path, not a workaround.
- "Magic words in PR comments won't create links." A comment would not have
  worked, so the reference must go in the body.
- The **closing** magic words are `close, closes, closed, closing, fix, fixes,
  fixed, fixing, resolve, resolves, resolved, resolving, complete, completes,
  completed, completing, implement, implements, implemented, implementing,
  linear issue`.
- The **non-closing** magic words are `ref, refs, references, part of, related
  to, relates to, contributes to, toward, towards`. A non-closing word still
  links, but does not apply the "On PR or commit merge" status when the PR merges.

firstmate writes a **non-closing** word, `Part of <IDENT>`, by default.
A closing word would make GitHub a second writer of the issue's status on merge,
competing with firstmate, which owns the Done transition because the backlog is
authoritative. Set `LINEAR_MAGIC_WORD=Fixes` to opt into Linear's merge
automation instead.

## Linking a PR: `bin/fm-linear-pr-link.sh`

`bin/fm-pr-check.sh` calls it last and non-fatally, the moment a task's PR is
reported, so a slow or broken Linear can neither delay arming the merge poll nor
fail the check.

It looks up the mirrored issue for the task id and appends to the PR body:

```
<!-- firstmate:linear -->
Part of PSY-42
```

- **Strictly additive.** The existing body is copied byte-for-byte and the block
  appended after it; the result is then checked to still start with the original
  bytes before it is pushed. The validation pipeline's evidence record in the PR
  body is never rewritten, truncated, or reordered. If that check ever fails,
  nothing is pushed.
- **Idempotent.** A body already carrying the marker comment, or a documented
  magic word followed by the identifier, is left alone. Running the PR check
  twice links exactly once.
- **A bare mention is not a link.** Linear only links from a PR body when a
  magic word precedes the ID, so an "already linked" check must look for a magic
  word (or firstmate's marker), never for the identifier alone.
- **A missing issue is non-fatal.** It can occur before the first refresh or for
  work added since the latest refresh. That is reported, not treated as an
  error.
- **Lookup is bounded and complete-or-unknown.** The filtered lookup follows
  every advertised page, with a 50-page safety bound and one total deadline
  shared by all filtered and fallback requests. Only an exhaustive response can
  report a missing issue; timeout, request failure, GraphQL failure, or the page
  bound reports the lookup as unavailable so firstmate never infers absence or
  creates a duplicate from an incomplete search.

After valid arguments are supplied, every operational outcome prints one `linear: ...` line and exits 0.

> **Prerequisite on the GitHub side.** Linear only links pull requests in repositories covered by its GitHub integration.
> If firstmate's PRs are opened against a repository outside the connected organisation, the reference is written correctly and Linear ignores it.
> Refresh's PR link attachment goes through the Linear API directly and is unaffected.

## Recording the merge: `bin/fm-linear-merge-write.sh`

`bin/fm-pr-merge.sh` calls it last and non-fatally, after the forge merge is confirmed, any configured local origin mirror is safely propagated, and the local merge outcome is recorded: the issue moves to the team's Done status and the pull request is attached.

The merge is the one moment where the task id, the pull request, and a live
backlog entry all exist together, so it is the only place the shipped outcome can
be recorded without depending on the backlog still remembering the item.
`data/backlog.md` prunes Done to the configured recent few, so waiting for the
next refresh loses the link for anything pruned in between.

- **Never on the merge's path.** Same degradation contract as the PR linker:
  unconfigured, unreachable, unauthenticated, slow, no mirrored issue, no
  completed status, or a rejected mutation all print one line and exit 0.
- **Never before a recorded merge outcome.** It runs only after forge confirmation, required local mirror propagation, and local outcome recording succeed, so an earlier refusal writes nothing.
- **Idempotent.** An issue already in a completed status is not transitioned
  again, and a pull request already attached is not attached again.

`fm-linear-refresh.sh` writes the same two facts when it reconciles the whole
backlog. Both go through `fml_set_state` and `fml_attach_url` in
`bin/fm-linear-lib.sh`, so the Done transition and the attachment have one owner.

## Importing merged pull requests: `bin/fm-linear-import-prs.sh`

```sh
bin/fm-linear-import-prs.sh --repo <owner>/<name> --dry-run   # show the plan
bin/fm-linear-import-prs.sh --repo <owner>/<name>             # apply it
```

Backfills work that shipped before the merge started writing to Linear itself.
GitHub is the only complete record of what shipped, so the merged pull request
list is the input.

**The mapping is the branch name**, `fm/<task-id>`, which firstmate wrote when it
dispatched the work. That is an exact mechanical join. Current task ids use a
numeric prefix. `data/done-archive.md`
is **not** used to recover ids because proximity matching can cross-assign tasks
and pull requests. The archive is read only to give a created issue a better
title than the pull request subject, never to derive the id.

A branch outside the numbered `fm/<task-id>` convention is **reported as
unmapped and nothing is written for it**. An unmapped pull request listed
honestly is a fine outcome; a wrongly attached one is the failure this shape
exists to avoid.

Every run prints one audit line per pull request carrying the verdict, the issue,
the derived task id, the pull request number, and the branch the id came from. A
created issue repeats that provenance in its description, so the mapping stays
checkable in Linear long after the run.

**`--dry-run` prints the plan, not just a verdict**, so it can be reviewed before
anything reaches a real board. Under each audit line it shows what would actually
be written: the title it would use and whether that came from the backlog and its
archive or from the pull request subject, the exact description including the
join line and the provenance, the attachment URL, and whether it would move the
issue to Done or leave an already-completed one alone. A pull request whose issue
is already Done and already carries the link plans nothing and is reported as
`unchanged`. No mutation is issued.

```
  create    (new)        010-basic-combat-damage   PR #51  branch fm/010-basic-combat-damage
      would create with title: Add non-targeted area effects
      title taken from the backlog or its archive
      description it would write:
        | `firstmate: 010-basic-combat-damage`
        | **Delivered:** https://github.com/o/r/pull/51
        | **Imported from** merged pull request #51 in o/r, branch `fm/010-basic-combat-damage`, ...
      would move it to the team's Done status
      would attach https://github.com/o/r/pull/51 as "Pull request"
```

That dry run is the reviewable half of a split the credential boundary forces:
the live import runs from the main firstmate home, which holds `LINEAR_API_KEY`,
while an isolated task worktree can only plan it. [`linear-verification.md`](linear-verification.md) records which parts have been confirmed live and which have not.

Exit codes: `0` imported (or inert because Linear is not configured), `2` usage,
`3` Linear or GitHub unreachable, `4` some operations failed (including a team
that cannot be resolved when an issue must be created).

## Refreshing in place: `bin/fm-linear-refresh.sh`

```sh
bin/fm-linear-refresh.sh --dry-run      # show the plan, change nothing
bin/fm-linear-refresh.sh                # apply it
```

Reconciled on the `firstmate: <task-id>` join, for every id:

| Situation | Action |
| --- | --- |
| In the backlog and in Linear | **Update that issue** - never create a second one |
| In the backlog only | Create it |
| In Linear only | **Report it as retired**, and change nothing |

Deleting or archiving the captain's issues is never this tool's decision, so a
retired id is output, not an action.

Completed work moves to the team's Done status and carries its PR as a Linear
link attachment (or its scout report path in the description), so the board can
answer "what has been built and confirmed" - which `data/backlog.md` cannot,
because it prunes Done to the configured recent few. That is also why
`data/done-archive.md` is read by default alongside the backlog: the pruned Done
entries live there.

What refresh **never** writes: priority, labels, project, cycle, estimate,
assignee, or the status of anything that is not newly done. Those are the
captain's, and reprioritising in Linear must survive a refresh.

An issue whose title and description already match the backlog is left untouched
and counted as `unchanged`, so a converged refresh is a genuine no-op.

Exit codes: `0` refreshed (or inert because Linear is not configured), `2` usage
or unresolvable team, `3` Linear unreachable, `4` some operations failed. Nothing
here is on a PR's path.

## Verification

Hermetic behavior tests: `tests/fm-linear.test.sh`. They stub the network with a
fakebin `curl` answering per GraphQL operation, and pin the degradation contract,
the additive and idempotent body edit, the exact first-line join, and the
in-place reconciliation.

Live verification against the real Linear API and the non-gating PR-check path is recorded in [`linear-verification.md`](linear-verification.md).
