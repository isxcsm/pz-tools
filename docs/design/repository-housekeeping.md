# Repository housekeeping

[Documentation index](../README.md)

Housekeeping is the maintenance worker's work on the [repository](glossary.md#repository): marking revisions deleted, removing their rows, deleting unused objects and packs, rewriting mostly unused packs, trimming run history and shrinking the database file. Which backups a player loses and when is on [Backups](../reference/backups.md); this page is how the code does it. Each step is bounded, so one pass does a limited amount and later passes continue.

## Marking revisions deleted

Deleting never removes rows at once. It sets `state = 'Deleted'`, `deleted_utc` and `delete_reason`, and bumps `repository_change_revision`. Reads, restore and export see only `Active` revisions.

| `delete_reason` | Set by | Applies to |
| --- | --- | --- |
| `retention` | `MarkRevisionsForRetentionAsync` after each backup | `Active` `Automatic` revisions beyond the newest `retain_latest_revisions`. `Manual` and `Unknown` ones are not counted. |
| `user` | Deleting one backup, or all backups of a save | Those revisions |
| `save-deleted` | Deleting a save in the app | Every `Active` revision of that source. The transaction stays open while the save folder is deleted and commits only after that succeeds; otherwise it rolls back (`PendingSaveRevisionDeletion`). |
| `orphan-save` | [Orphan cleanup](#orphan-cleanup) | The source's hidden baseline |

`source_state.current_revision` never moves back. The newest revision stays as the baseline of the next incremental backup even when it is `Deleted`, together with its totals and objects. It becomes reclaimable once a newer backup commits.

## When it runs

| Trigger | Process | Work |
| --- | --- | --- |
| The maintenance runner that follows a backup (`--dispatch-lanes`) | `PzTools.Maintenance.Cli` | Retention marking for that source, then starts the lanes below as detached processes: `RevisionReclamation` if due, `ArtifactCleanup` always |
| `RevisionReclamation` lane | Per source | One batch of [revision reclamation](#revision-reclamation), then garbage collection with a 1,000-row path sweep |
| `ArtifactCleanup` lane | Per source | Delete leftover `staging/*.tmp` and `staging/quarantine/*.tmp`, then the [housekeeping pass](#the-housekeeping-pass) for that source |
| `OrphanBackups` lane, started by the state scheduler every `cleanup_interval_seconds` (60) | Whole repository | Interrupted-operation recovery, [orphan cleanup](#orphan-cleanup), the housekeeping pass for all sources, then [pack space reclamation](#pack-space-reclamation) |
| Direct CLI run without `--lane` | `MaintenanceService`, in process | Retention, reclamation, garbage collection, artifact cleanup and housekeeping for one source |

Rules every lane follows:

- It does not start while any game process exists, and stops within about a second if one appears (`GameplayWorkGate`, polled every second). When the game processes cannot be listed, it defers too.
- One process per lane and repository (named mutex). Another operation can ask a lane to yield, which cancels it.
- It writes only under the [writer lock](repository-format.md#writer-lock). Per-source lanes retry the lock every `writer_retry_delay_ms`; the orphan lane holds the `RepositoryAccess` mutex for its whole run and ends `Busy` if the lock is taken.

The state scheduler skips an `OrphanBackups` pass when neither the list of save folders nor `repository_change_revision` changed since the last one, except once an hour so that time-based work still happens. When the game exits it dispatches one at once instead of waiting for the interval, and the app dispatches one more as it closes. The pass is a detached process, so it finishes after the app has gone, and defers by itself if the game starts.

<a id="when-disk-space-comes-back"></a>
## Revision reclamation

A source is due when its `Deleted` revisions below `current_revision` number at least `revision_batch_size` (20), or the oldest was deleted more than `revision_compaction_max_delay_minutes` (60) ago. After a backup, the dispatcher checks the source it backed up. The `OrphanBackups` pass also takes up to four due sources, oldest deletion first, which is how saves that are no longer played get reclaimed.

`CompactDeletedRevisionsAsync` takes the oldest due revisions, up to the batch size, in one transaction. For each deleted revision R:

1. S is the next later revision that is `Active` or is `current_revision`.
2. Versions that ended at R now end at S.
3. Versions that started at R and live past S now start at S. Versions that started at R and ended by S are deleted.
4. The revision row is deleted.

Every `Active` revision and the baseline see the same files before and after. Garbage collection follows.

## The housekeeping pass

`RepositoryHousekeepingService.RunAsync`, for one source or for all:

1. For all sources only: revision reclamation of the due sources, as above.
2. Entry-version sweep (`SweepUnreachableEntryVersionsAsync`): inspects up to `database_cleanup_batch_size` rows of `entry_versions` in rowid order from a saved cursor (one per source, one for all) and deletes closed versions whose interval contains no `Active` revision and not `current_revision`. Open versions and current tombstones are never deleted. The limit counts inspected rows, so a repository with nothing to delete does not walk its whole history under the writer lock. Cursor and deletions commit together; a short window wraps to the start next time.
3. Garbage collection, if steps 1 or 2 removed anything.
4. Dictionary sweep with the same row budget ([path handling](path-normalization.md#removing-unused-paths)).
5. [History trimming](#completed-execution-history).
6. [Database file-space recovery](#database-file-space-recovery).

## Garbage collection

`CollectGarbageAsync` in one transaction deletes `stored_objects` rows that no version references, optionally sweeps up to 1,000 dictionary rows, and deletes `packs` rows that own no objects (`Committed` or `Superseded`). After the commit it deletes those pack files, then every `packs/*.pzpack` that is not registered: packs from interrupted backups or compactions, and files an earlier deletion could not remove. Files that cannot be deleted are reported, the run ends `Degraded`, and the next pass tries again.

## Orphan cleanup

[`OrphanBackupCleanupService`](../../src/PzTools.Backup.Engine/OrphanBackupCleanupService.cs) removes the history of a save whose folder is confirmed missing under the configured saves root. A source counts as missing only when all of these hold; anything else defers it to a later pass:

- Its key is exactly `<mode>/<save>` with valid names, and its recorded root equals `<saves root>/<mode>/<save>`.
- Neither the saves root, its ancestors nor the mode folder is a reparse point.
- The saves root lists without error, and either the mode folder is absent or its listing lacks the save.
- The mode folder holds no restore journal `.<save>.pztools-restore.json`, no `.<save>.pztools-staging-<guid>` or `-rollback-<guid>`, and the save has no pending save-file edit.
- No workflow or worker run for the source is `Running`.

For a confirmed source, `ReclaimOrphanSourceAsync` deletes every version and every revision except the current one, marks that one `Deleted` (`orphan-save`) with zero totals, and clears the USN checkpoint. The empty baseline keeps revision numbers increasing if a save of the same name appears again. Garbage collection follows. A moved save folder looks the same as a deleted one.

<a id="pack-space-reclamation"></a>
## Pack space reclamation

A pack is deleted only when nothing in it is needed. Each incremental backup writes one pack, and a manual or old backup usually still needs a few unchanged files from many earlier packs, so those packs stay on disk mostly unused. Revision reclamation and garbage collection cannot recover that space. [`PackSpaceReclaimer`](../../src/PzTools.Backup.Engine/PackSpaceReclaimer.cs) rewrites such packs; it runs last in the `OrphanBackups` pass so that only data still needed is copied.

**Selection.** Live bytes are the stored lengths of the objects a `Committed` pack still holds.

1. A pack is sparse when it has live bytes and they are less than `pack_reclamation_sparse_percent` (50) of its size. A pack with no live bytes is left to garbage collection.
2. Nothing happens until the sparse packs together hold at least `pack_reclamation_minimum_mib` (16) of dead space.
3. Packs are taken sparsest first until the next would push the live bytes over `pack_reclamation_maximum_copy_mib` (128). The sparsest is always taken, so one large pack cannot block reclamation forever.
4. The repository's drive needs free space of at least twice the live bytes plus 64 MiB; if free space cannot be read, the pass is skipped.

A rewritten pack is fully live, so it is not chosen again until it has itself become sparse. The threshold bounds how often data is copied.

**Rewrite** ([`PackCompactor`](../../src/PzTools.Backup.Engine/PackCompactor.cs)):

1. Each object is read at its recorded offset, decompressed and written into one new pack under the same object UUID, checksum algorithm and compression algorithm (Brotli at the default quality 3). Its length and checksum must equal the original's, or the object is discarded and the pass fails.
2. The new pack is sealed, fully validated and moved into `packs/` like any other ([writing](pack-format.md#writing)).
3. One transaction registers the new pack (with the newest `created_run_index` of the packs it replaces), moves every object's location to it, and marks the old packs `Superseded`; a pack that still owns an object fails the transaction.
4. Garbage collection deletes the superseded packs.

| Killed | State | Next pass |
| --- | --- | --- |
| Before the new pack is promoted | Old packs untouched; a file in `staging/` | Artifact cleanup deletes it |
| After promotion, before the switch | An unregistered pack | Garbage collection deletes it |
| After the switch | Superseded packs still on disk | Garbage collection deletes them |

Every retained backup stays restorable throughout. `InterruptedOperationRecoveryTests` kills a real process at each of these points.

## Completed execution history

`PruneCompletedHistoryAsync` deletes old `workflow_stages` and their `workflow_runs` in one transaction, at most `database_cleanup_batch_size` workflows per pass. A workflow is eligible only when all hold:

- It is not `Running` and completed before now minus `history_retention_days` (90).
- It is not among the newest `history_minimum_runs` (1,000) run indexes.
- No revision and no pack refers to it.
- None of its stages is `Running`, lacks a completion time, or completed after the cutoff.

A completion time that cannot be parsed counts as missing, so the record is kept. `history_retention_days = 0` turns trimming off. `next_run_index`, sources and current revision state are never touched. Telemetry has its own retention ([telemetry](telemetry.md)).

## Database file-space recovery

`TryVacuumAsync` runs SQLite `VACUUM` on a private, non-pooled connection with a one-second lock timeout. In order, it returns:

| Status | When |
| --- | --- |
| `disabled` | `vacuum_enabled = false` |
| `database-size-limit` | Pages × page size above `vacuum_maximum_database_mib` (256); such a database keeps its free pages |
| `below-threshold` | Free pages below `vacuum_minimum_free_mib` (4) or below `vacuum_minimum_free_percent` (25) of all pages |
| `active-work` | Another worker run, or any non-maintenance workflow, is `Running` |
| `insufficient-space` | The database's drive or the temp folder's drive has less than twice the database size plus 64 MiB free |
| `space-check-unavailable` | Free space could not be read |
| `busy` | A lock could not be taken |
| `compacted` | Done; a WAL `TRUNCATE` checkpoint was attempted, and readers may postpone the truncation |

It uses SQLite's transactional `VACUUM`, never `VACUUM INTO` followed by swapping the file under open WAL readers. Microsoft.Data.Sqlite runs native work synchronously even in its async methods, so cancellation is wired to `sqlite3_interrupt`; a lane asked to yield stops the rebuild. The reported sizes are page counts times page size, not the folder's disk usage. Recovering file space does not securely erase deleted data.

## Settings

`[maintenance]` in the maintenance worker's file, `%LOCALAPPDATA%\PzTools\config\maintenance-worker\default.toml`; packaged defaults in [`config/defaults/maintenance-worker/default.toml`](../../config/defaults/maintenance-worker/default.toml). See [advanced settings](../reference/advanced-settings.md#which-setting-wins) for how files are layered.

| Key | Default | Range | Controls |
| --- | --- | --- | --- |
| `retain_latest_revisions` | 100 | 1 or more | Automatic backups kept per save. The app's backup count replaces it. |
| `writer_retry_delay_ms` | 200 | 50–5000 | Wait between attempts at the writer lock |
| `revision_batch_size` | 20 | 1–1000 | Deleted revisions reclaimed per source per pass; a full batch is due at once |
| `revision_compaction_max_delay_minutes` | 60 | 0–10080 | When a smaller batch becomes due |
| `history_retention_days` | 90 | 0–3650 | Minimum age of trimmed history; 0 turns trimming off |
| `history_minimum_runs` | 1000 | 1 or more | Newest run indexes always kept |
| `database_cleanup_batch_size` | 1000 | 1–10000 | Rows inspected per entry-version and dictionary sweep; workflows per history batch |
| `vacuum_enabled` | `true` | | Database file-space recovery |
| `vacuum_minimum_free_mib` | 4 | 1 or more | Free space needed before `VACUUM` |
| `vacuum_minimum_free_percent` | 25 | 1–100 | Share of free pages needed before `VACUUM` |
| `vacuum_maximum_database_mib` | 256 | 1 or more | Largest database rebuilt automatically |
| `pack_reclamation_enabled` | `true` | | Pack space reclamation |
| `pack_reclamation_sparse_percent` | 50 | 10–90 | Live share under which a pack is sparse |
| `pack_reclamation_minimum_mib` | 16 | 1 or more | Dead space needed before anything is copied |
| `pack_reclamation_maximum_copy_mib` | 128 | 1–4096 | Live data copied per pass |

The pass interval is `cleanup_interval_seconds` (60, 10–86400) under `[scheduler]` in the state scheduler's file.

## Limits

- **Nothing is immediate.** Every step waits for a pass that is allowed to run and gives way to the game and to other operations.
- **Pack space reclamation needs the game closed** and the free space above.
- **Free-space checks are admission checks.** Something else can still fill the disk during the pass.
- **Object deletion in garbage collection is not batched.** It deletes every unreferenced object in one statement.

## Tests

`RepositoryHousekeepingTests`, `RepositoryMaintenanceTests` and `OrphanBackupCleanupTests` cover the production code paths; `InterruptedOperationRecoveryTests` covers interruption of reclamation and recovery of interrupted workflows.
