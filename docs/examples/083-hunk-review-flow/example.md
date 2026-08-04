# Worked sidecar example for task 083

This example was generated from task 083's staged implementation diff on 2026-08-04.
The changeset contained 229 added or changed lines across six files at generation time, but the sidecar contains only three annotations.
Those three stops are the places where the delivering crewmate was least sure, rather than a mechanical note for every hunk.

The generator was run with the following shape, using literal tab-separated input:

```sh
printf '%s\t%s\t%s\t%s\t%s\n' \
  'bin/fm-review.sh' 32 39 'Check the bare-review readiness ordering against real fleet snapshots.' '<rationale>' \
  'bin/fm-review.sh' 51 61 'Check the direct GitHub .diff transport for every repository visibility we support.' '<rationale>' \
  'bin/fm-review-notes.sh' 40 54 'Check that the compact TSV-to-JSON transform stays understandable and rejects malformed ranges.' '<rationale>' \
  | FM_HOME="$PWD" bin/fm-review-notes.sh 083-hunk-review-flow \
      --summary 'Three deliberately curated uncertainty stops for the standalone Hunk review flow.'
```

The resulting [`review-notes.json`](review-notes.json) has `confidence: "low"` on every annotation and anchors each note to its real new-side line range.
The notes call out readiness ordering, authenticated diff transport, and the generator's deliberately compact transformation as the three review risks.
Hunk's live session inspection reported `reviewNoteCount: 3`, `showAgentNotes: true`, and all three expected file/range anchors when this staged patch was opened through the real TUI.

After adding the shell startup line once, a fresh Bash shell opens a specific task with one word plus its id:

```sh
. /absolute/path/to/firstmate/bin/fm-review-shell.sh
review 083-hunk-review-flow
```

Bare `review` selects only a checks-green task with no open captain decision, prioritizing the task that directly unblocks the most distinct non-done backlog records rather than counting repeated blocker occurrences.
Green is not itself readiness, because a captain decision can remain the real blocker after checks pass.
The command reads ordinary task metadata and fleet state directly, so this flow needs neither cockpit integration nor Herdr placement changes.

Hunk remains a reading aid in this stage.
Nothing the captain writes inside Hunk reaches the pull request, and GitHub remains the review system of record until a later comment-harvest bridge exists.

The plain-diff fallback was also exercised end to end with task `061-linear-refresh-path` in the primary home's real metadata.
That merged pull request opened as a 12-file Hunk patch with no sidecar present, proving that the viewer does not depend on notes or an open pull request.
