# Session-start briefing budget verification

Verified on 2026-08-31 from commit `eae2b921c6dbd875d296f4bf28e6d7935cf738ee`.

## Firstmate-supplied primary-home evidence

At 5 live task records the session-start digest measured 45,953 bytes = 15,317 estimated tokens, and its FLEET STATE section alone measured 18,252 bytes = 6,084 estimated tokens, about 40 percent of the digest at a small fleet.

The raw digest is deliberately not included because it contains private fleet content such as task identifiers, project names, worker status, and paths.

## Reproducible synthetic cap evidence

The realistic behavioral fixture exercised the session-start public interface with 12 synthetic task metadata files and 12 matching status logs, enough to exceed the six-record detail ceiling.

The uncapped control used `FM_SESSION_START_TASK_DETAIL_LIMIT=12` and measured 5,167 estimated tokens.

The capped run used `FM_SESSION_START_TASK_DETAIL_LIMIT=6` and measured 4,614 estimated tokens, a reduction of 553 estimated tokens while retaining an explicit record for all 12 tasks.

The capped digest printed six full task records and six records labelled `detail: trimmed`; every trimmed record retained its task id, endpoint state, full metadata path, and full status-log path.

The durable wake queue remained composed verbatim outside the fleet-detail cap.

Command:

```sh
tests/fm-session-start.test.sh
```

Relevant output:

```text
# session-start measurement populated-12 uncapped=5167 capped=4614
ok - fleet detail is capped while every task remains explicitly and recoverably accounted for
# fm-session-start.test.sh: all assertions passed
```
