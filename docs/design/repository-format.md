# Repository format

[Documentation index](../README.md)

The backup [repository](glossary.md#repository) is the backup folder. `repository.db`, a SQLite database, is the authority on what exists: sources, revisions, file versions and where each stored object lives. The [packs](pack-format.md) hold the file contents. The code is in [`src/PzTools.Backup.Storage/Repository/`](../../src/PzTools.Backup.Storage/Repository/). What the player sees of backups, and which ones are deleted when, is on [Backups](../reference/backups.md).

## Versions

| Version | Value | Defined in |
| --- | --- | --- |
| Repository format | 2 | `RepositoryDatabase.CurrentFormatVersion` |
| Repository schema | 6 (schema 5 is upgraded when opened) | `RepositorySchema.CurrentVersion`, `UpgradableVersion` |
| Pack format | 1 | `PackFormat.Version`, see [pack format](pack-format.md) |

This page is the one place these numbers are recorded. Every process that opens the repository checks them, so the app and the workers must come from the same build.

## Files in the backup folder

| Item | What it is |
| --- | --- |
| `repository.db` (with `-wal` and `-shm` while open) | The catalog, in WAL mode |
| `packs/<pack id>.pzpack` | Committed packs; the name is the pack UUID as 32 hex digits |
| `staging/run-<run>-<pack id>.tmp` | A pack being written |
| `staging/run-<run>-<pack id>.idx.tmp`, `staging/capture-<guid>.tmp` | Index sidecar and staged file copies; both are delete-on-close, so the OS removes them even when the process is killed |
| `staging/quarantine/` | Temporary files a later backup found left over |
| `.writer.lock` | The [writer lock](#writer-lock) |
| `telemetry.db`, `.pztools/<component>/` | Diagnostics, see [telemetry](telemetry.md). Losing them loses no backup. |

Settings are not stored here; they live under `%LOCALAPPDATA%\PzTools\config\` (see [advanced settings](../reference/advanced-settings.md)).

## Tables

| Table | Holds |
| --- | --- |
| `repository_info` | One row: repository UUID, format and schema version, `next_run_index`, `repository_change_revision` |
| `schema_migrations` | The schema versions applied |
| `sources` | One row per save: `source_key` (`<mode>/<save>`, unique ignoring case) and `root_path` |
| `source_state` | Per source: `current_revision` and the [USN checkpoint](usn-journal.md#checkpoint), whose three columns are all set or all null |
| `revisions` | `(source_id, revision)`, the `run_index` that made it, `state` (`Active` or `Deleted`), deletion time and reason, `backup_kind`, display name, character summary, `file_count`, `logical_size`, `game_version` |
| `packs` | Pack UUID, relative path, byte length, `status` (`Committed` or `Superseded`), `created_run_index` |
| `stored_objects` | Object UUID, its pack and record offset, lengths, checksum and compression algorithm, checksum, change fingerprint |
| `paths`, `path_spellings` | The path dictionaries, see [path handling](path-normalization.md) |
| `entry_versions` | Every version of every path of every source, described below |
| `workflow_runs`, `workflow_stages` | Run history: one workflow per run index, one stage per producer process |
| `entry_gc_cursors`, `path_gc_cursor` | Where the bounded cleanup sweeps resume, see [housekeeping](repository-housekeeping.md) |

Views: `worker_runs` (the stage of the backup worker, or of the maintenance worker when no backup shares the run, with its status folded into the five telemetry values), `entry_catalog` (versions joined with their path strings) and `current_entry_catalog` (open, live versions only, forced onto the narrow current index). The column encodings are on [compact storage](compact-repository-format.md).

### File versions are intervals

A row of `entry_versions` is visible in revision R when `valid_from_revision <= R` and `valid_to_revision` is null or greater than R. A commit closes the open version of each changed path by setting its `valid_to_revision` to the new revision, then inserts the new version. A deletion is a version with `tombstone = 1`. Unchanged files add no rows, so a revision costs rows only for what changed.

Constraints that hold at all times:

- At most one open version per `(source_id, path_id)` (unique partial index `ix_entry_versions_current`).
- A live `File` version has an `object_id`; directories and tombstones may not.
- `valid_to_revision > valid_from_revision`.
- Every version's `(path_id, spelling_id)` exists, and its `valid_from_revision` names an existing revision row.

## Opening a repository

`RepositoryDatabase.CreateOrOpenAsync` creates `packs/` and `staging/`, switches the database to WAL, applies the schema 6 baseline in one transaction and writes a new identity (random UUID, `next_run_index = 1`). It does this only when `repository.db` is missing or empty.

A non-empty `repository.db` goes through `OpenExistingAsync`. The identity is read before any statement that could write:

| Found | Result |
| --- | --- |
| No `repository_info` row | Ordinary error "Repository identity is missing." |
| Format other than 2, or schema other than 6 or 5 | `repository-reset-required`, nothing written |
| `schema_migrations` disagrees with the recorded schema | `repository-reset-required`, nothing written |
| Schema 5 | [Upgraded](#upgrade-from-schema-5), then opened |
| `revisions.game_version` missing | Column added in place, schema number unchanged |

The app shows `repository-reset-required` as "This version cannot open this backup folder. Choose a new folder in the settings. Do not delete the old one." There is no converter and no reset command; the folder is left as it was.

Every connection runs `PRAGMA foreign_keys = ON` and `busy_timeout = 5000`, with a shared cache and no pooling. Opening is retried up to five times (50, 100, 200, 400 ms apart) for exactly one failure: SQLite's `SQLITE_IOERR_TRUNCATE` with Windows error 1224, which happens while Windows still maps the WAL index of a killed process. The retry opens a fresh handle and never deletes `-wal` or `-shm`. Only connection setup and read-only probes are replayed, never a caller's transaction ([`RepositoryConnectionInitialization`](../../src/PzTools.Backup.Storage/Repository/RepositoryConnectionInitialization.cs)).

The app checks `repository_change_revision` once a second to decide whether to reload the backup list. That reader keeps one connection open (`HoldReadConnection`). Opening a connection per check made SQLite create and delete `-wal` and `-shm` every second, each time scanned by file-system filters. The check runs in a short read transaction, so writers, checkpoints and `VACUUM` are not held up.

### Upgrade from schema 5

Schema 5 kept every worker run twice, in `runs` and in `workflow_runs`/`workflow_stages`, and every writer kept the two in step by hand. Schema 6 keeps only the workflow tables; revisions and packs refer to `workflow_runs`, and the `worker_runs` view answers what `runs` did.

`RepositorySchemaUpgrade.UpgradeFrom5Async` does it in one immediate transaction on a private connection:

1. Runs that only `runs` recorded get a workflow and a backup-worker stage.
2. `revisions` and `packs` are rebuilt with the new references, and `runs` is dropped.
3. `PRAGMA foreign_key_check` must return nothing, or the transaction rolls back and the repository stays schema 5.

A second process opening at the same moment waits on the lock (30 s busy timeout) and then finds schema 6. The private connection matters here: with the shared cache, a second opener in the same process would fail at once on the upgrade's locks instead of waiting. No copy of the old database is kept. The transaction already makes the upgrade all or nothing, and a copy would cost as much disk as the catalog. An older build refuses an upgraded repository.

## Writers and runs

<a id="writer-lock"></a>
### Writer lock

Every method that writes takes a `RepositoryWriterLease` and checks that it is still held and belongs to this repository path. The lease is `.writer.lock` opened with `FileShare.None`; ownership is the open handle, so a file left behind by a dead process blocks nothing. A second acquirer gets `RepositoryBusyException`. A backup holds the lease from before it reads the source until after its commit, so garbage collection can never run between a pack's promotion and its registration.

Whole operations (backup, restore, export, orphan cleanup) also take the `RepositoryAccess` named mutex; see [process architecture](process-architecture.md).

### Run index

The run index comes from the installation's `control.db` ([`RunIndexAllocator`](../../src/PzTools.Control/RunIndexAllocator.cs)): each allocation returns `MAX(last + 1, now in Unix ms × 65536, requested minimum)`. The time floor keeps numbers rising even if `control.db` is recreated. Reserving a workflow with that index also raises `repository_info.next_run_index` to at least index + 1. A caller that supplies no index (tests, direct engine use) gets the next value of `next_run_index`. Numbers are never reused, including after history cleanup.

Each run has a `workflow_runs` row (pipeline, owner component, optional unique `admission_id` that makes the scheduler's reservation idempotent) and one `workflow_stages` row per producer. Both are stamped with the owner's process ID and start time, which recovery uses to tell a dead owner from a live one.

### Backup origin

`backup_kind` is decided inside the commit: `Automatic` when the run's workflow is pipeline `backup-maintenance` owned by `backup-scheduler`, `Manual` for everything else (app, CLI, direct engine). `Unknown` is only the column default for rows that predate the column. Retention counts only `Automatic` revisions.

## What counts as committed

A backup exists only once one SQLite transaction commits all of this ([`CommitRevisionAsync`](../../src/PzTools.Backup.Storage/Repository/RepositoryDatabase.Revisions.cs)):

1. The revision row, with its kind, default name and game version.
2. The pack row (`Committed`) and the new object rows.
3. The file versions, closing the ones they replace, and the revision's `file_count` and `logical_size`.
4. `source_state`: the new `current_revision` and the USN checkpoint.
5. The backup-worker stage, and the workflow when the backup worker owns it, set to `Succeeded`.
6. `repository_change_revision` + 1.

The transaction first checks that the run is `Running` in `worker_runs` and targets this source. It refuses a requested revision number not above the current one, duplicate pack or object IDs, and two entries whose paths are equal ignoring case. The pack file is already sealed, validated and in `packs/` before this transaction starts; see [pack format](pack-format.md#writing).

Totals: a first backup adds up the files in its scan; an incremental backup starts from the totals of the current revision and adjusts them for each version it closes or inserts.

The first backup commits from the scan's `TEMP` table in set-based statements (`CommitInitialRevisionFromStagingAsync`). It is refused if the source already has a revision or if any scanned file has no object.

A run that finds nothing to store calls `AdvanceCheckpointWithoutRevisionAsync`: the checkpoint moves, the stage ends `NoChange`, and no revision is made.

## Interruptions and recovery

| Process stopped | Left behind | Cleaned up by |
| --- | --- | --- |
| While writing the pack | `staging/run-*.tmp` | The next backup moves `staging/*.tmp` into `staging/quarantine/` and warns `temporary_files_quarantined`; maintenance (artifact cleanup, interrupted-operation recovery) deletes `*.tmp` in both folders |
| After the pack moved into `packs/`, before the commit | An unregistered `.pzpack` | The next backup warns `orphan_pack`; garbage collection deletes every unregistered `packs/*.pzpack` |
| During the commit | Nothing; SQLite rolls back | |
| After the commit | Nothing | |

A stage left `Running` by a dead process is closed in two ways. The next backup, holding the writer lease, marks every running backup-worker and maintenance-worker stage `Abandoned` with `process-interrupted` (`RecoverAbandonedRunsAsync`): only the lease holder can be writing. Maintenance recovery (`RecoverInterruptedWorkflowsAsync`) abandons running workflows whose stamped processes have all exited or been replaced; when it cannot tell, it leaves the workflow and reports it.

Before a backup builds on the catalog it checks that every `Committed` pack exists. If one is missing, the backup fails with "The repository references one or more missing committed packs." instead of writing a revision on top of lost data.

`InterruptedOperationRecoveryTests` kills a real process at each of these boundaries and checks that the repository holds either the old state or the committed one.

## Revision metadata

| Column | Rule |
| --- | --- |
| `display_name` | Default "`<prefix> <revision>`", the prefix depending on kind, in the language set at the time. Renames are 1 to 100 printable characters and only for `Active` revisions. |
| `game_version` | The version the running game reported, trimmed, at most 80 printable characters; null when the game was not reporting one. Saves carry no version string. |
| Character columns | Filled after the commit by the character summary reader; a failure there leaves the backup intact and adds a warning. |

## Deletion in storage terms

Deleting marks a revision `Deleted`; reads, restore and export see only `Active` revisions. `current_revision` never moves back: the newest revision stays as the hidden baseline for the next incremental backup even when it is deleted. Rows and pack space are reclaimed later by [housekeeping](repository-housekeeping.md).

## Decisions

- **Refuse, never convert or reset, other versions.** Only schema 5 has an upgrade. Any other format or schema is refused before anything is written, and the player chooses a new folder.
- **No backup copy for the schema 5 upgrade.** The single transaction already makes it all or nothing.
- **Optional nullable columns are added in place.** Builds that do not know `game_version` name their columns explicitly, so the repository keeps its schema number and still opens in them.
- **Object IDs are random UUIDs, not content hashes.** An ID says where an object is. Reuse of identical content is decided by SHA-256 and a byte comparison; see [pack format](pack-format.md#reusing-stored-objects).
