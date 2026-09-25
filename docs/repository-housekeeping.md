# Repository housekeeping

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

Housekeeping was introduced at commit `6f2023c` without changing the storage layout.
The subsequent pre-release [compact format 2](compact-repository-format.md) deliberately
breaks format-1 compatibility. The policies below apply to new format-2 repositories;
orphan-backup deletion and administrator requirements remain unchanged.

## Revision reclamation

`revision_batch_size` limits revisions compacted per source in a pass. A full batch
is eligible immediately; a smaller batch becomes eligible after
`revision_compaction_max_delay_minutes` (default 60). The next available maintenance
pass performs the work. This is not a wall-clock deadline while the app is stopped,
other work is busy, or maintenance is yielding.

The periodic orphan-maintenance worker also checks up to four eligible sources per
pass, oldest deletion first. Inactive saves therefore need neither another backup
nor another deletion to trigger reclamation. The latest revision remains a hidden
incremental baseline even when marked Deleted.

Closed entry versions are removed only when their visibility interval intersects
neither an Active revision nor the current baseline. Open versions and current
tombstones remain. GC follows reclamation and retains objects referenced by remaining
entries. Mutations are batched; selection may scan more rows than the mutation limit.

## Completed execution history

Defaults retain at least 90 days of completed history and the newest 1,000 IDs from
each of `runs` and `workflow_runs`. Only older unreferenced records are eligible.
Running or incompletely dated work, live/incompletely dated stages, revision owners
and pack creators are protected. Unparseable completion times are uncertain and kept.
Stages are deleted before workflow parents, with run deletion in the same transaction.

`repository_info.next_run_index`, source identities and current revision state are
not reset. Retained backup metadata is not history garbage. Component telemetry has
its own retention policy. `history_retention_days = 0` disables history trimming.

## Opportunistic DB file-space recovery

Maintenance may run SQLite `VACUUM` when at least 4 MiB and 25% of logical DB pages are
free. Automatic rebuilds are capped at 256 MiB by default; larger DBs retain reusable
pages rather than starting an unbounded automatic rebuild. `vacuum_enabled = false`
disables this step.

The worker holds the existing writer lease, checks active backup workflows/runs,
uses a private non-pooled connection and skips lock contention. Both database and
temporary-storage volumes must have twice the logical DB size plus 64 MiB available.
This is an admission check, not a guarantee against concurrent disk-space consumption.

SQLite's transactional `VACUUM` is used, never `VACUUM INTO` followed by swapping an
open repository file. Native `sqlite3_interrupt` is registered for maintenance
cancellation because Microsoft.Data.Sqlite async methods execute native SQLite work
synchronously. The maintenance yield watcher can request interruption.

After rebuilding, a WAL TRUNCATE checkpoint is attempted. Readers can defer physical
truncation. `BeforeBytes`/`AfterBytes` are logical page counts times page size, not total
directory usage; `CheckpointCompleted` distinguishes completed checkpointing.
Normal skip reasons include `below-threshold`, `active-work`, `busy`,
`insufficient-space`, `space-check-unavailable`, `database-size-limit` and `disabled`.
This is neither secure erasure nor compaction of partially live pack files.

## Configuration and verification

Options are in `config/defaults/maintenance-worker/default.toml`. Typed preflight and
worker entry points read the same values. Rebuild/publish app and workers together.
Do not mix new configuration keys with an older worker.

The isolated Python production-SQL checks pass all 14 cases:

```text
python scripts/check-housekeeping-sql.py
```

These cover retained/deleted revision combinations, hidden baselines, inactive-source
admission, bounded batches, uncertain timestamps, reference protection, rollback,
VACUUM preservation and deferred WAL truncation. Their reduced fixtures are not a
replacement for C# integration tests using the production schema.
Eight `RepositoryHousekeepingTests` cases are included in the 123 Windows storage
tests passing at `142b3af60a080de6f20ebf06c3bb4d43a7317833`.
See the compact-format document for evidence and remaining full-application CI scope.
