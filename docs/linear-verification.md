# Linear mirror: live verification

Every command and output below was run against the real Linear API and the real `psychogenesis` workspace on the date shown, with personal fields redacted.
The behavior contract itself is pinned by `tests/fm-linear.test.sh`, which stubs the network; this file records what was checked against production.

Date: 2026-08-02.
Workspace: `psychogenesis` (organisation `levelupself` on the GitHub side).
Credential: an existing `LINEAR_API_KEY` passed through the environment and not written anywhere in this repo.

## 1. How Linear links a PR - established, not assumed

Source: Linear's own GitHub documentation, <https://linear.app/docs/github>,
fetched 2026-08-02. The relevant findings are quoted in `docs/linear.md`:
the three supported linking paths (branch name, PR title, magic word plus issue
ID in the PR description), that "To link a PR that is already open, modify the PR
title or description", that "Magic words in PR comments won't create links", and
the exact closing and non-closing magic-word lists.

[`linear.md`](linear.md#how-linear-links-a-pull-request) owns why firstmate writes the non-closing `Part of <IDENT>` into the PR body.

## 2. Authentication and the join, against live Linear

```
$ curl ... -H "Authorization: $LINEAR_API_KEY" --data '{"query":"query { viewer { name email } organization { name urlKey } }"}'
{"viewer":{"name":"[redacted]","email":"[redacted]"},"organization":{"name":"psychogenesis","urlKey":"psychogenesis"}}
```

`fml_find_issue` run against live Linear through the real library:

```
010-basic-combat-damage          -> PSY-7   0cf8fcdb-...  https://linear.app/psychogenesis/issue/PSY-7/...   Backlog  backlog
049-hostility-de-escalation      -> PSY-42  06796605-...  https://linear.app/psychogenesis/issue/PSY-42/...  Backlog  backlog
061-linear-refresh-path          -> rc=1 (1=no issue, 2=unavailable)
```

The third line is the case the brief calls normal: an in-flight task that was
never mirrored resolves to "no issue", distinctly from "could not ask".

## 3. A task without a mirrored issue

Covered above (`rc=1`) and end-to-end in `tests/fm-linear.test.sh`:

```
ok - no mirrored issue: reported, PR untouched, exit 0
```

The linker prints `linear: no mirrored issue for <id>; nothing linked` and
exits 0 without calling `gh pr edit` at all.

## 4. Linear unavailable never blocks the lifecycle

Real `curl`, real `fm-pr-check.sh`, an unroutable endpoint:

```
$ time FM_HOME=... LINEAR_API_KEY=lin_api_bogus LINEAR_API_URL=https://10.255.255.1/graphql \
    FM_LINEAR_PR_TIMEOUT=3 ./bin/fm-pr-check.sh vt https://github.com/levelupself/firstmate/pull/999
armed: state/vt.check.sh polls https://github.com/levelupself/firstmate/pull/999
linear: lookup unavailable (Linear did not answer within 3s or rejected the request); nothing linked, PR unaffected

real    0m3.560s
exit=0

$ cat state/vt.meta
window=fm-vt
worktree=...
pr=https://github.com/levelupself/firstmate/pull/999
```

The PR was still recorded, the merge poll was still armed, the wait was bounded
by the configured timeout, and the exit code was 0.

Against the real Linear endpoint with an invalid key:

```
$ FM_HOME=... LINEAR_API_KEY=lin_api_invalidkey ./bin/fm-linear-pr-link.sh vt https://github.com/.../pull/999
linear: lookup unavailable (Linear did not answer within 8s or rejected the request); nothing linked, PR unaffected
real    0m0.213s
exit=0

$ curl ... -H 'Authorization: lin_api_invalidkey' --data '{"query":"query { viewer { id } }"}'
http=401
{"errors":[{"message":"Authentication required, not authenticated", ...}]}
```

## 5. Refresh updates in place; the count does not double

Run against live Linear with a deliberately scoped backlog of two items: one id
already mirrored (`010-basic-combat-damage` = PSY-7), and one genuinely new
(`061-linear-refresh-path`). Scoping avoids creating the 53 issues a full
refresh would add to the captain's board unasked; the full-scale matching was
still measured, by dry run, below.

Before:

```
mirrored issues BEFORE: 45
```

Run 1:

```
  created   PSY-50       061-linear-refresh-path
  updated   PSY-7        010-basic-combat-damage

linear refresh: 2 backlog items, 45 mirrored issues in team PSY
  created 1, updated 1, unchanged 0, moved to Done 0, PR links 0, failed 0

  no longer in the backlog (44) - REPORTED ONLY, nothing was deleted:
```

Run 2, identical input:

```
linear refresh: 2 backlog items, 46 mirrored issues in team PSY
  created 0, updated 0, unchanged 2, moved to Done 0, PR links 0, failed 0
```

After:

```
mirrored issues AFTER both runs: 46          # 45 + exactly one new id
issues joined to 010-basic-combat-damage: PSY-7
issues joined to 061-linear-refresh-path: PSY-50
```

Still exactly one issue per task id after three live runs. The 44 ids absent
from the scoped backlog were reported as retired and nothing was done to them.

Full-scale matching, measured by dry run against all 45 mirrored issues:

```
linear refresh (dry run): 98 backlog items, 45 mirrored issues in team PSY
  created 53, updated 45, unchanged 0, moved to Done 0, PR links 0, failed 0
```

All 45 mirrored issues matched their backlog id. Zero duplicates were planned
for them. The 53 creates are ids that never existed in Linear (in-flight items,
Done items, and queued items filed after the original mirror run).

## 6. Note-body rendering

Because the first mirror run had to repair a formatting corruption Linear's
Markdown parser introduced, the refresh emits the backlog note body verbatim
inside a fenced code block by default (`LINEAR_BODY_STYLE=preserve`). Whitespace,
ASCII diagrams, and aligned tables therefore cannot be reflowed or mangled.
`LINEAR_BODY_STYLE=markdown` renders the body as Markdown instead.

The exact empty-column TSV split that protects this rendering is covered by the regression test in `tests/fm-linear.test.sh`.

## 7. Linking a real PR, end to end

Run against this change's own pull request, whose task has a mirrored issue
(PSY-50), using the shipped `bin/fm-linear-pr-link.sh`.

```
$ ./bin/fm-linear-pr-link.sh 061-linear-refresh-path https://github.com/<owner>/firstmate/pull/1539
linear: linked PSY-50 (https://linear.app/psychogenesis/issue/PSY-50/...) - appended "Part of PSY-50" to the PR body

bytes BEFORE=12212  AFTER=12256
--- appended tail ---
<!-- firstmate:linear -->
Part of PSY-50

--- strictly additive? ---
YES: original body bytes identical and unmoved
```

Run again, unchanged input:

```
linear: PSY-50 already referenced in the PR body; left unchanged
occurrences of 'Part of PSY-50' after two runs: 1
body unchanged by run 2: YES
```

The reference is appended once, the pipeline's evidence record above it is
untouched byte for byte, and a second run is a no-op.

### The bare-mention trap this run exposed

The first attempt did nothing, because the PR body already contained the string
`PSY-50` in prose - this feature's own documentation quotes its issue id. The
original "already linked" check treated any occurrence of the identifier as an
existing link and skipped.

That was wrong: Linear only links from a PR body when a **magic word** precedes
the ID. A bare mention links nothing, so skipping on one silently produces the
exact failure this change exists to prevent. `fml_body_links` now requires a
documented magic word (including the list form and any configured
`LINEAR_MAGIC_WORD`) or firstmate's own marker comment, and
`tests/fm-linear.test.sh` pins all three cases.

## 8. The two facts a merge writes, read back from the real board

Date: 2026-08-08.

Credential boundary, and why this section is split the way it is. `LINEAR_API_KEY`
is configured in the main firstmate home's private, gitignored `.env`. It is
deliberately not reachable from an isolated task worktree, and it is not copied
into one, so work validated in a worktree cannot execute the live API and the
live runs belong to the main home. That is the intended boundary, not a gap in
the setup.

What follows is therefore split: the write shape below was confirmed live by
reading a real board issue back, while the new scripts' own live execution was
not performed here and is recorded as outstanding at the end of this section.

`bin/fm-linear-merge-write.sh` writes exactly two things: a `stateId` pointing at
the team's completed "Done" status (`fml_set_state`) and an
`attachmentLinkURL` titled "Pull request" (`fml_attach_url`). Both are the
mutations `fm-linear-refresh.sh` has been using, so a live issue produced by
refresh is direct evidence of how they render.

PSY-121, read back live:

```
description first line   `firstmate: 063-migration-journal-repair`
status                   Done          statusType: completed
stateHistory             Backlog (ended 2026-08-04T09:03:07.412Z) -> Done
attachments              [{ title: "Pull request",
                            url: "https://github.com/levelupself/psychogenesis/pull/41" }]
```

The attachment is a real rendered link with the exact title `fml_attach_url`
sends, and the completed status is the one `fml_done_state_id` selects: the
status literally named "Done" whose type is `completed`. The description's first
line is the join, unchanged.

### Outstanding, and owned by the main home

Not performed here, and not claimed: a run of `fm-linear-merge-write.sh` or
`fm-linear-import-prs.sh` against the live API, and the read-back of an issue
those scripts themselves wrote. Both require the credential that stays in the
main home, so both are main-home work rather than something a task worktree can
close.

`fm-linear-import-prs.sh --dry-run` exists so the second one can be reviewed
before it is run: it prints, per pull request, the title it would use and where
that title came from, the exact description including the join line and the
pull-request provenance, the attachment URL, and whether it would move the issue
to Done or leave an already-completed one alone, while issuing no mutations.

## 9. The import mapping, against the real merged pull requests

Date: 2026-08-08. Read-only; nothing was written.

`bin/fm-linear-import-prs.sh` derives the task id from the branch name
firstmate created, `fm/<numbered-task-id>`, and reports anything else. Applied to
the real merged pull requests of `levelupself/psychogenesis`:

```
$ gh pr list --repo levelupself/psychogenesis --state merged --limit 200 \
    --json number,headRefName
71 merged pull requests
45 current ids  fm/<NNN-slug>, e.g. #41 fm/063-migration-journal-repair -> 063-migration-journal-repair
26 legacy ids   fm/psychogen-*, e.g. #1 fm/psychogen-engine-k1 -> psychogen-engine-k1
```

The split is clean rather than ragged: all 26 pre-numbering branches are
`fm/psychogen-<word>-<code>` and belong to pull requests #1 to #27. Their exact
branch suffixes are stable legacy task ids, so all 71 pull requests map directly
from GitHub without a judgement call. Reading `data/done-archive.md` by
proximity remains forbidden because that produced cross-assignments on
2026-08-03.
