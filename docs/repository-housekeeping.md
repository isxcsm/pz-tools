# Repository housekeeping

[Documentation index](README.md) · [User guide](../README.md)

Housekeeping removes deleted history and reclaims unreferenced storage. Logical
deletion and physical space recovery are separate steps.

## Retention and orphan backups

The automatic count limit applies only to automatic backups. Manual backups remain
until explicit deletion or source cleanup; they are not permanently pinned.

The orphan lane removes a save's backup history when its original folder is confirmed
missing under the configured saves root. It defers inaccessible roots, uncertain paths,
reparse points and pending restore/edit operations instead of interpreting them as deletion.
It also yields during gameplay or competing work, so cleanup is not immediate.
Export important history before deleting or moving the original save.

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

For an isolated SQL check:

```text
python scripts/check-housekeeping-sql.py
```

Use `RepositoryHousekeepingTests` and the orphan-cleanup integration tests for the
production code path. SQL fixtures alone do not establish app-level behavior.
