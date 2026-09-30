# Connection startup and merge review

[Documentation index](../README.md) · [User guide](../../README.md)

> **Historical record.** This page describes the code and measurements at the time it was written. It is kept for reference and is not updated; for current behaviour start at the [documentation index](../README.md).

Historical review of PR #1's format 2 / schema 2 implementation, which superseded
PR #2's schema-12 migration. Versions and results below belong to the named commits.
See [repository format](../repository-format.md) for current compatibility and
[development](../development.md) for validation requirements.

## Connection ownership

SchedulerDatabase, StateDatabase and ProcessTelemetryStore took ownership of native
connections until opening and configuration succeeded. Failure or cancellation before
return disposed the connection; a caller's `await using` could not cover that boundary.

`ConnectionOwnershipTests` verified cancellation, failure and successful transfer
through exclusive file access while the managed connection remained reachable.

## Windows mapped-file contention before application SQL

Repeated kill/reopen tests exposed SQLite 3.53.3 result 1546 (IOERR_TRUNCATE), with
Windows error 1224 (ERROR_USER_MAPPED_FILE) at SQLite's native error callback.
This establishes mapped-file contention, not which process held the mapping.

The fix added a read-only schema probe before ownership transfer, acquiring the WAL
shared-memory connection before application transactions. Existing-repository identity
checks moved inside initialization, while format checks still preceded configuration
PRAGMAs.

Retry eligibility was limited to Windows, SQLite primary 10 / extended 1546 and
native error 1224. At most five fresh-handle attempts used delays of 50, 100, 200 and
400 ms, plus I/O time. Failed handles were disposed before cancellable waits and
retried attempts emitted a Trace warning. Other or persistent errors propagated.

Only connection initialization was retried; application writes, capture, restore,
DDL, commit and VACUUM were outside that boundary. The fix did not delete WAL/SHM files.

## Verification boundaries

`RepositoryConnectionInitializationTests` covered retry filtering and handle lifetime,
including a memory-mapped WAL-index fixture. `CrashRecoveryStressTests` used fresh
repositories at six process-termination boundaries and stopped at the first failure.

Two lifecycle tests switched to observable completion with ten-second deadlines.
They checked independent projection-loop progress and shutdown, and instance rejection
before and after lock reacquisition. Application mutex semantics were unchanged.

Targeted results did not cover the full shutdown, recovery and published-worker
workflow. Exact commit, TRX and workflow results were recorded in the PR review.

## Final review follow-up (2026-09-25)

At `693b60d`, the normal suite passed 722 cases; the published suite passed 735 and
failed one because a scheduled-runner fixture loaded an uninitialized global worker
configuration. `58c8126` supplied temporary worker/runner configurations and added
restore-content verification while retaining the scheduled-time assertion.

The review also found a NULL-identity bug after deletion: StreamingFullScanner cast
DBNull to byte[], and tombstone registration rejected the internal empty sentinel
under the 24-byte identity constraint. The fix carried the sentinel through planning
and converted it to SQL NULL only for tombstones, preserving live-entry constraints.

Workflow `36132614219` reproduced four InvalidCastException failures (file/parent
identity crossed with ordinary/always-include deletion). After product fix
`d2a1fbca0ec84c8df01df37757f37ce8b3fe2de3`, all 55 selected storage cases passed.
The regression verified identities, restored contents, compaction, GC and integrity;
artifacts included `before.trx` and `after.trx`.

PR #2 was closed as superseded. Final merge-head validation and merge SHA belong to
the PR #1 review; the selected results above do not establish them.

References: SQLite result-code and configuration/error-log documentation;
Microsoft SetEndOfFile and UnmapViewOfFile documentation.
