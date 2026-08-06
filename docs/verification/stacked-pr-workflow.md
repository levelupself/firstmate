# Stacked pull request workflow feasibility

This record tests whether the current validation and task lifecycle support dependent pull request bases and evaluates the review process that is practical today.

## Recommendation

Use semantic review increments that land on `main` promptly, and do not adopt chained pull request bases with the current tooling.
Split policy-heavy work to reduce review load, but do not split work merely because a diff is large.
Each increment should have one review question, one task branch, and one validation run, and the next dependent branch should start from `main` after the prior increment lands.
This preserves the review benefit sought from a stack while avoiding contingent checks, cumulative rereviews, and descendant restacks.

True chained bases should be reconsidered only after validation accepts an explicit base branch throughout the pipeline and the task lifecycle records and supervises stack relationships.

## Live compatibility probe

The probe ran on 2026-08-05 with `no-mistakes v1.41.2`.
It created an unmerged parent branch at `bc69109f` and a dependent child at `2e05c73a`.
Pull request 17 targeted `main`, while pull request 18 used the parent branch as its base.

```text
$ gh-axi api /repos/<owner>/<repository>/pulls/18 --jq '{number,base:.base.ref,head:.head.ref,mergeable_state}'
base: fm/055-stacked-pr-parent-probe
head: fm/055-stacked-pr-child-probe
mergeable_state: clean
number: 18
```

A full no-mistakes run then started from the dependent branch while pull request 18 remained open.
The deterministic rebase phase reported the following default-branch comparison.

```text
fetching latest upstream state...
already up-to-date with refs/remotes/no-mistakes-push/fm/055-stacked-pr-child-probe
already ahead of origin/main
```

The pull request phase did not attach to pull request 18.
It opened pull request 19 for the same head branch against `main`.

```text
checking for existing pull request on branch fm/055-stacked-pr-child-probe...
creating pull request...
created pull request: https://github.com/<owner>/<repository>/pull/19
```

```text
$ gh-axi api /repos/<owner>/<repository>/pulls/19 --jq '{number,base_ref:.base.ref,head_ref:.head.ref}'
base_ref: main
head_ref: fm/055-stacked-pr-child-probe
number: 19
```

Pull request 18 received no checks because both repository workflows select pull requests whose base is `main`.
One unrelated timing-sensitive test failed on the first CI pass, and the pipeline added a test-harness correction before pull request 19 completed the full cumulative validation against `main`.
That correction changed neither pull request base nor the base-selection evidence.
The three probe pull requests were closed without merging after the result was captured.

The tested conclusion is that no-mistakes does not currently validate a child delta against an unmerged parent branch.
It validates the complete child head against the default branch and creates a default-branch pull request even when a dependent pull request already exists for that head.

## What green means

The dependent pull request in the probe had no green state because no check suite ran on its non-`main` base.
The green no-mistakes result belonged to the duplicate `main`-based pull request and covered the cumulative parent-plus-child tree plus the pipeline-owned test-harness correction.
That signal proves that the combined head passed against the reviewed default branch at the recorded commit, but it does not isolate the child change or establish that the unmerged parent is acceptable.

Even with broader workflow triggers, a child check would remain contingent on the exact unmerged parent SHA.
A parent update would invalidate that signal and require the child check to run again.
Any future stacked workflow should label such a result as `contingent on <parent>@<sha>`, never as independently green.

## Restack cost

For a stack of depth `n`, a finding in layer `i` requires `n - i` descendant branch rebases, the same number of rewritten branch pushes, and the same number of dependent CI reruns.
A three-layer `A -> B -> C` stack therefore turns one finding in `A` into two descendant rebases, two rewritten pushes, and two additional CI cycles.
A second revision to `A` repeats all six operations, while a finding in `B` adds one rebase, one rewritten push, and one CI cycle for `C`.
Any conflict must be resolved separately at each affected descendant boundary.

The current default-branch validation also duplicates review load.
For three equally sized layers, the pipeline reviews `A`, then `A + B`, then `A + B + C`, which is six layer-equivalents of review for three layer-equivalents of change.
A genuinely base-aware stack would review each layer once.

## Supervision shape

One task producing multiple branches is incompatible with the current one-task, one-branch, one-worktree, one-pull-request lifecycle.
Task metadata, validation custody, merge polling, and teardown each identify one branch and one pull request.

Multiple dependent tasks are the only shape that preserves those identities, with one worktree and one worker per layer.
That shape is not first-class today because `fm-spawn.sh` allocates a clean default-branch worktree and exposes no parent-base option.
Every dependent task would need custom parent setup, and every low-stack revision would require ordered steering and revalidation through all live descendants.
The no-mistakes result above leaves that shape without a supported validation path.

The recommended main-as-stack process uses multiple serial tasks instead.
Each task lands one semantic increment on `main`, and the next dependent task starts from that landed commit.
No descendant restack exists, and ordinary task supervision remains unchanged.

## Interaction inspector replay

The real interaction inspector changed 27 files, including 13 production-source files, and produced 13 findings over four review rounds.
Its difficulty came from policy boundaries rather than size.
A review-oriented decomposition would have used three increments.

1. The trace-transport increment would carry structured engine derivations, classifier exchanges, agent context, and model exchanges through `ActionResult`, `GameSession`, the narrator pipeline, and the API, with a conservative server-derived role gate and no new play surface.
2. The read-surface increment would add `InteractionInspector`, retained feed entries, readable calculation and prompt rendering, memoized closed bodies, and the explicit policy for feed-visible arithmetic versus psychogeneticist-only detail.
3. The judgment increment would reuse `feedback.submit` for verdicts, add the judgment rate-limit migration, record `scenarioId`, make one turn produce one replaceable verdict, and fit reconstructable cases by explicitly truncating scalable entity projections before rejecting the judgment.

This split would have isolated the actual review decisions.
The `derivations-ungated` decision would have been settled in the transport increment before any play-feed exposure and would not have survived unchanged into a later review round.
Escaped prompt rendering and transcript rerender cost would have stayed in the read-surface review.
Duplicate submissions, the misleading `seed` field, case-size accounting, rollout compatibility, and explicit truncation would have stayed in the judgment review.

That decomposition would genuinely have improved reviewability under a base-aware stack.
Under the tested tooling it would instead cause cumulative rereviews and restacks, so the same three increments should land promptly on `main` in order.

## Reconsideration gates

Chained pull request bases become a supported option only when all of the following are true.

- No-mistakes accepts one explicit base and uses it for rebase, diff construction, review, test selection, pull request creation, and CI monitoring.
- CI runs on dependent pull requests and reports the exact parent SHA that bounds each contingent result.
- Task metadata records the parent relationship, spawn starts from that parent, and restack, merge-watch, and teardown behavior preserve the whole chain until every increment lands on `main`.
