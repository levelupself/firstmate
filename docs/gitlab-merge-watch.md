# GitLab merge request watch verification

The shared landing-evidence contract is owned by [`bin/fm-pr-landed-lib.sh`](../bin/fm-pr-landed-lib.sh).
The watcher authenticates the per-task poll bytes and provider-tagged sidecar before invoking the canonical [`bin/fm-pr-poll.sh`](../bin/fm-pr-poll.sh).
Its existing check timeout bounds the complete evidence read, and errors produce no output.

## Current verification entry point

Run `bash tests/fm-pr-check-security.test.sh` for provider, destination, ancestry, timeout, registration, migration, and retirement regressions.
The executable fixtures cover GitHub and GitLab, including a nested namespace on a non-default GitLab host.
Run `bash tests/fm-pr-merge.test.sh` for the shared GitHub evidence reader and the merge path's confirmation, retry, and receipt behavior.
These are deterministic fixture tests; they do not claim a live forge or installed GitLab CLI observation.

## GitLab evidence surface

The poll uses `glab mr view <number> -R <project-url> --output json` so resolution does not depend on a current Git repository.
Passing a full merge request URL in place of the number can make `glab` resolve the current repository instead.
Python decodes the JSON and validates the state, target branch, and merge commit using the shared schema reader.
Repository and merge-base API reads use the validated host explicitly, with the nested project path URL-encoded.
The [GitLab repositories API](https://docs.gitlab.com/api/repositories/#get-merge-base) defines the common-ancestor endpoint used by the helper.
A changed or unreadable response is insufficient evidence of landing.

The stored provider, URL, host, namespace, and number must reconstruct the canonical URL exactly.
`bin/fm-pr-lib.sh` owns the sidecar and registration formats, and `bin/fm-pr-check-migrate.sh` owns non-executing migration of old poll bytes.
The watcher runs the trusted canonical source with validated arguments; the copied state file is an authenticated identity artifact, not a standalone installed program with its own dependencies.

## Supported boundary

`bin/fm-pr-check.sh` requires `glab` for GitLab registration and verifies the target branch before publishing registration.
`bin/fm-pr-merge.sh` still addresses GitHub only and refuses GitLab URLs; GitLab merge mutation parity remains outside this watch feature.
A GitLab task still records no `pr_head`; `bin/fm-teardown.sh` and `bin/fm-review-diff.sh` own their existing provider-specific fallback behavior.
