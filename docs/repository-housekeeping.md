# Repository housekeeping

This change targets database growth without changing the repository schema or
pack format. It does not truncate hashes, rewrite file IDs or timestamps, change
orphan-backup deletion policy, or change the app's administrator requirement.

## Deletion admission is separate from batch size

`revision_batch_size` still limits revisions compacted per source in a pass.
A full batch is immediately eligible. A smaller batch becomes eligible after
`revision_compaction_max_delay_minutes` (default 60). The next available
maintenance pass performs the work; this is not a wall-clock deadline while the
app is stopped, another operation is busy, or maintenance is yielding.

The periodic orphan-maintenance worker also checks up to four eligible sources
per pass, oldest deletion first. An inactive save therefore does not need a new
backup or another deletion to trigger reclamation. The latest revision remains
a hidden incremental baseline even when marked Deleted, as before.

Closed entry versions are removed only if their visibility interval intersects
neither an Active revision nor the source's current baseline. Open versions,
including current tombstones, are kept. Garbage collection follows reclamation
and still retains all objects referenced by remaining entries. Mutations are
batched; the selection query itself may scan more rows than the mutation limit.

## Completed execution history

The defaults retain at least 90 days of completed history and the newest 1,000
IDs from each of `runs` and `workflow_runs`. Only older, unreferenced rows are
eligible. Running or incompletely dated work, live/incompletely dated stages,
revision owners and pack creators are protected. Unparseable completion times
are treated as uncertain and retained. Stages are deleted before their workflow
parents in one transaction; run deletion is also in that transaction.

`repository_info.next_run_index`, source identity and current-revision state are
not reset. Retained backup metadata is not execution-history garbage. This is
separate from component telemetry retention. Set `history_retention_days = 0`
to disable history trimming.

## Opportunistic file-space recovery

Maintenance may run SQLite `VACUUM` when at least 4 MiB and 25% of the logical
database consist of free pages. Automatic full rebuilds are capped at 256 MiB by
default. Larger databases keep their reusable pages rather than starting an
unbounded automatic rebuild. `vacuum_enabled = false` disables this step.

The worker holds its existing writer lease. It checks for other active backup
workflows/runs, uses a private non-pooled SQLite connection, and skips lock
contention. Database and temporary-storage volumes must each have room for twice
the logical database size plus 64 MiB. This is an admission check, not a guarantee
against another process consuming disk space during the operation.

The implementation uses SQLite's transactional `VACUUM`, not `VACUUM INTO` followed
by replacing `repository.db`. Native `sqlite3_interrupt` is registered for the
maintenance cancellation token, because Microsoft.Data.Sqlite async methods
execute SQLite work synchronously. This lets the existing maintenance yield
watcher request cancellation of a running rebuild.

After a successful rebuild, a WAL TRUNCATE checkpoint is attempted. Readers may
defer physical truncation. `BeforeBytes` and `AfterBytes` report logical SQLite
page counts multiplied by page size, not total directory usage.
`CheckpointCompleted` distinguishes whether the checkpoint finished. Normal
skip reasons (`below-threshold`, `active-work`, `busy`, `insufficient-space`,
`space-check-unavailable`, `database-size-limit`, `disabled`) are not backup
failures. This is not secure erasure and does not shrink partially live pack files.

## Configuration

The new options are in `config/defaults/maintenance-worker/default.toml`; all are
optional for existing installations. The typed preflight validator and worker
entry point read the same values. Rebuild/publish the app and workers together.
Do not mix a new configuration with an older worker that rejects unknown keys.

## Verification

Implementation baseline: `dev` commit `7f666076f8d5243f8a0df65d40b1437736f90273`.
No user save, repository database or local Windows installation was accessed.

The Linux editing environment does not contain a .NET SDK or Windows/WinUI
runtime. It is therefore NOT evidence of a successful Windows build, game run,
or full .NET test suite.

Executed locally during implementation:

```text
python scripts/check-housekeeping-sql.py
14 tests passed
```

This supplemental standard-library Python test extracts the production SQL and
executes it against isolated SQLite fixtures with the relevant repository foreign
keys. Coverage includes all 16 combinations of four retained/deleted revisions,
the hidden latest baseline, global inactive-save admission, bounded batches,
uncertain timestamps, history-reference protection, rollback, VACUUM content
preservation, and a WAL reader deferring truncation. It is not a substitute for
the full production schema and C# integration tests.

Eight C# regression tests in `RepositoryHousekeepingTests.cs` use repositories
created by the real migration runner. They cover admission, the next revision
following hidden-baseline cleanup, history protection and cancellation, the
retention off switch, and VACUUM guards/content preservation. They are added to
the existing test project and require the repository's Windows build environment:

```powershell
dotnet test tests/PzTools.Backup.Tests -c Release --filter FullyQualifiedName~RepositoryHousekeepingTests
```

The existing Windows verification workflow runs for a pull request targeting
`dev` or `main`. Its actual result must be checked before merging this change;
no successful C# execution is claimed by the local SQLite results above.

Technical references: SQLite's VACUUM and sqlite3_interrupt documentation;
Microsoft.Data.Sqlite's asynchronous I/O limitations and interoperability guide.
