# Connection startup and merge review

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

> Historical review: versions, commit IDs and test counts below describe the named review, not the current release state.

PR #2's legacy schema-12 fingerprint migration is superseded by PR #1's format 2 /
schema 2 implementation. Do not reintroduce old-format readers or migrations. A new
empty backup repository is required; the game save directory is never reset by
these changes.

## Connection ownership

SchedulerDatabase, StateDatabase and ProcessTelemetryStore now own each native
connection until opening and configuration both succeed. Cancellation or an
exception before returning the connection disposes it immediately. A caller's
`await using` cannot clean up a connection that the factory failed to return.

ConnectionOwnershipTests cover native-open cancellation, an injected exception
after native acquisition, and successful ownership transfer for all three stores.
They check exclusive file access while the managed connection remains reachable,
not after forcing garbage collection. The exception fixture does not assume a
read-only journal-mode PRAGMA must throw: SQLite may retain the current mode.

## Windows mapped-file contention before application SQL

Repeated kill/reopen tests exposed SQLite 3.53.3 result 1546 (IOERR_TRUNCATE), with
Windows error 1224 (ERROR_USER_MAPPED_FILE) at SQLite's native error callback.
This establishes mapped-file contention, not which process held the mapping.

Repository connections now force a read-only schema probe before ownership is
transferred to application code. This acquires the WAL shared-memory connection
before a later application transaction. Opening an existing repository similarly
validates its identity inside the connection-initialization boundary. Incompatible
format checks still precede configuration PRAGMAs; there is no automatic migration
or deletion.

Only Windows, SQLite primary 10 / extended 1546, and native error 1224 are eligible
for a fresh-handle retry. There are at most five attempts, with delays of 50, 100,
200 and 400 milliseconds; I/O execution time is additional. A failed connection is
disposed before the delay. Cancellation interrupts the delay. Persistent errors,
permission errors, corruption, other I/O errors and unrecognized native errors
propagate. A diagnostic Trace warning identifies a retried startup attempt.

No application transaction, capture, restore, DDL or commit is replayed. Never
move caller writes into RepositoryConnectionInitialization's initializer. WAL and
SHM files are not deleted manually as a recovery workaround. VACUUM and ordinary
application transaction errors retain their existing failure semantics.

## Verification boundaries

RepositoryConnectionInitializationTests verify the narrow error filter, fresh
handle disposal, retry exhaustion, cancellation and an actual memory-mapped
WAL-index fixture. CrashRecoveryStressTests use a fresh repository for every
iteration at all six process-termination boundaries. They fail on the first
failure; they are not test retries until green.

Two lifecycle tests now synchronize on observable completion rather than a fixed
scheduling assumption. The projection test requires multiple healthy iterations,
a reported fault in the independent loop, and both loops reaching Stopped after
RequestStop. The instance test requires a second process to be rejected while the
owner lives, bounded reacquisition after the owner exits, and duplicate rejection
again after reacquisition. Both use a ten-second failure deadline; neither forces
GC, skips checks, or repeats a failed test case. Application mutex semantics are
unchanged.

The full Windows workflow still includes shutdown, recovery and published-worker
integration tests. Targeted test success alone is not release evidence. Exact
commit IDs, TRX counts and workflow results are recorded in the PR review. Tests
using real game samples, a live game or elevated USN remain explicit opt-ins.

## Final review follow-up (2026-09-25)

At head `693b60d`, the normal suite passed 722 cases, but the published distribution
suite passed 735 and failed one: the scheduled-runner fixture attempted to load
an uninitialized user's global backup-worker configuration. Commit `58c8126`
creates an explicit temporary worker configuration with phase telemetry and a
runner configuration, just as the adjacent unscheduled fixture does. The test
still requires successful completion no earlier than the scheduled time and now
also restores the produced backup and verifies its exact contents. The product's
missing-configuration error is not suppressed, and the test is not skipped.

The review also found a supported NULL-identity boundary: entry_versions permits
an unknown file or parent identity, and full-scan fallback can encounter such an
entry after the file is deleted. StreamingFullScanner cast DBNull directly to
byte[], while the pending tombstone's empty sentinel was incompatible with the
new 24-byte identity constraint. The scanner now carries the internal empty
sentinel through planning, and only a tombstone converts that sentinel back to
SQL NULL at registration. Live-entry identity constraints remain unchanged.
This is not legacy-format compatibility or a schema migration.

Windows workflow `36132614219` first reproduced four InvalidCastException failures
with unchanged product code (file/parent identity crossed with ordinary/always-
include deletion). After the guarded two-file fix, all 55 selected storage cases
passed, including the four new cases. The regression verifies the NULL and the
other identity's 24 bytes, retained-file restore, deleted-file absence, revision
compaction, object GC and repository integrity. Artifacts include both before.trx
and after.trx. Product fix: `d2a1fbca0ec84c8df01df37757f37ce8b3fe2de3`.
The one-shot reproduction workflow removed itself before this final validation.

Only PR #1 is the merge candidate; PR #2 remains closed as superseded. The exact
final head must pass the ordinary Windows suite and the freshly published payload
suite, as well as the separate storage, crash and JVM checks. Final counts and
merge SHA belong in the PR review rather than a claim based on targeted results.
No real user repository, save folder or local installation was accessed.

References: SQLite result-code and configuration/error-log documentation;
Microsoft SetEndOfFile and UnmapViewOfFile documentation.
