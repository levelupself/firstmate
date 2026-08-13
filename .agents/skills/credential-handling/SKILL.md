---
name: credential-handling
description: >-
  Agent-only credential safety procedure.
  Use before reading, writing, moving, rotating, or creating any credential, and before running any command against a secret store.
user-invocable: false
metadata:
  internal: true
---

# credential-handling

Load this skill before reading, writing, moving, rotating, or creating any credential, and before running any command against a secret store.
This skill is the single owner of Firstmate's credential-handling procedure.

## Secret-store access

Never print a secret or rotate a shared one.
Bare `infisical secrets` prints secret values.
`--plain` and `--silent` do not mean names-only, and `--plain` emits `NAME=VALUE` when used with a listing command.
There is no safe browse: the only safe read is a named `secrets get <NAME> --env=<env> --plain` piped straight to its destination.
Get expected names from the task record or the app's config validation.
`secrets set NAME=@/path/to/file` moves a value without it entering argv.

## Verification and rotation

`infisical` resolves `.infisical.json` from the working directory, so a read from the wrong directory can return an empty value.
The SHA-256 fingerprint of an empty value starts with `e3b0c44298fc`, which can look like proof that a value changed.
Verify a nonzero byte count before fingerprinting.

Never rotate the `dnd` database password - every lane hard-codes it.

## Boundaries and side effects

Do not move credentials across WSL distribution boundaries or into worker worktrees that intentionally lack `.env`; split the work at that boundary instead.

## Creation and grants

Establish the actual tooling capability before asking for credential creation, including whether an existing authenticated session can perform the operation without exposing a value.

A tool that links or downloads may write a live credential to disk as a side effect (`vercel link` and `vercel blob create-store` both drop `.env.local`).
Shred it afterwards rather than deleting it.

Treat every grant as request-specific rather than standing authority.
Name which values move from where to where, and use a transcript-safe mechanism that keeps each value out of command arguments and output.
