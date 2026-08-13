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

Never PRINT a secret, never ROTATE a shared one.
Bare `infisical secrets` prints VALUES - it leaked two test keys once, then the live `ANTHROPIC_API_KEY`.
`--plain` and `--silent` do NOT mean names-only; `--plain` is what dumps `NAME=VALUE`.
There is no safe browse: the only safe read is `secrets get <NAME> --env=<env> --plain` piped straight to its destination.
Get expected names from the task record or the app's config validation.
`secrets set NAME=@/path/to/file` moves a value without it entering argv.

## Verification and rotation

A read from the WRONG DIRECTORY returns nothing, and hashing nothing looks real.
`infisical` resolves its project from `.infisical.json` in the CWD; elsewhere it yields empty, and sha256 of empty is `e3b0c44298fc...`, which compares as "different from the old value" and reads as PROOF OF ROTATION.
VERIFY BY BYTE COUNT FIRST, then fingerprint.
Caught one step before pushing an empty key to production.

Never rotate the `dnd` database password - every lane hard-codes it.

## Boundaries and side effects

Credentials do not cross a WSL distribution boundary, and a worker's worktree has no `.env` BY DESIGN - split the work at that line rather than moving the secret.

## Creation and grants

Creating a credential is almost always an authenticated-session action the captain must perform: there is no Linear CLI for it, and minting a key through an API requires already having one.
Establish what tooling can actually do before asking him for something a CLI could have done - on 2026-08-13 firstmate asked him for three values when only one genuinely needed him.

A tool that links or downloads may write a live credential to disk as a side effect (`vercel link` and `vercel blob create-store` both drop `.env.local`).
Shred it afterwards rather than deleting it.

Every captain grant is per-request, never standing.
Lay out which values move, from where to where, and use a mechanism that moves a value without it entering a transcript.
