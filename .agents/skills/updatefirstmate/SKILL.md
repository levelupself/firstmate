---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin while observing an optional upstream template remote.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), reports upstream template commits that still need a separate merge catch-up, then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work, and checks whether a configured `upstream` template remote has moved.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

The upstream template check is observation, not an update source.
A fork catch-up is always a separate reviewed merge commit because fork-only commits make a fast-forward from upstream impossible.
Never reset or rebase the fork, force-push, discard fork commits, or use a blanket prefer-theirs conflict pass.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It separately fetches an optional remote named `upstream` and compares its default branch with the fork's local default branch without moving either checkout.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), an `upstream-template:` observation, and three action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `nudge-secondmates: fm-<id>...|none`
   - `review-upstream: yes|no`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live secondmate.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Review pending upstream template work.**
   When `review-upstream: yes`, inspect every pending upstream commit subject and the affected paths before reporting the update outcome.
   `changed-since-last-fetch: yes` proves that the local upstream remote-tracking ref moved since its previous fetch; `pending` counts commits not contained in the fork; the changed-file count describes the upstream side since the merge base and is not a conflict count.
   `upstream-catchup-last:` gives the date of the latest first-parent merge whose non-first parent belongs to current upstream history, or says `unknown` when no such merge can be established.
   Treat a catch-up as due roughly monthly, earlier when the review exposes a fix or capability the fleet needs, when a prior resolution session materially exceeded 28 conflicted files, or immediately before preparing work to offer upstream.
   The updater does not perform or schedule the catch-up.
   Commission that work separately through the normal delivery path as one merge commit on a branch from the fork's default branch.
   Upstream-bound offers remain opportunistic; do not schedule outbound pull requests.

   The observation has explicit limits.
   It runs only when `/updatefirstmate` is invoked, cannot infer semantic fleet need from a commit subject or path, cannot measure how many conflicts a future merge will produce, and cannot observe upstream at all when the remote is missing or the fetch fails.
   Report those limits rather than implying continuous monitoring or semantic coverage.

5. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest fork release, which were left as-is and why, and whether newer template work awaits a separate catch-up.
   For example: "Captain, firstmate and both second mates are now on the latest fork release; upstream has three newer commits awaiting review."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Upstream is observation only.**
  Pending template commits are reported for review but never merged, rebased, reset onto, or propagated to homes by this command.
  A catch-up remains a separate merge-commit change through the normal delivery path.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmates are never disrupted.**
  A local or remote secondmate gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
