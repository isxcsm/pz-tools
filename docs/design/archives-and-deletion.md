# Archives and deletion

[Documentation index](../README.md)

How ZIP export, ZIP import, backup deletion and save deletion work: the order of steps, the locks each one takes, what
an interruption leaves behind, and the checks that keep them from touching the wrong files. The player's steps are in
[Move a save to another PC](../guides/move-a-save.md) and [Backups](../reference/backups.md#deleting-backups). When the
disk space of deleted backups comes back is in [repository housekeeping](repository-housekeeping.md).

| Code | Role |
| --- | --- |
| [`ZomboidArchiveService`](../../src/PzTools.Zomboid.Archive/ZomboidArchiveService.cs), [`ArchiveModels`](../../src/PzTools.Zomboid.Archive/ArchiveModels.cs) | Inspect, export (backup and live), import |
| [`PzTools.Zomboid.Archive.Cli`](../../src/PzTools.Zomboid.Archive.Cli/Program.cs) | The archive worker: `inspect`, `export`, `export-live`, `import`; takes the named mutexes and the writer lock |
| [`OperationCoordinator`](../../src/PzTools.App.Core/OperationCoordinator.cs) | In-app gates; starts the archive worker; runs the deletions in process |
| [`SaveDeletionService`](../../src/PzTools.App.Core/SaveDeletionService.cs) | Deletes a save folder |
| [`RepositoryDatabase.SaveDeletion`](../../src/PzTools.Backup.Storage/Repository/RepositoryDatabase.SaveDeletion.cs), [`RepositoryDatabase.Maintenance`](../../src/PzTools.Backup.Storage/Repository/RepositoryDatabase.Maintenance.cs) | Marks revisions deleted |
| `MainWindowShell.xaml.cs` (`ExportButton_Click`, `ImportButton_Click`, `DeleteSave_Click`, `DeleteRevision_Click`, `DeleteAllBackupsButton_Click`) | Button conditions, confirmations, re-checks, refresh afterwards |

## Locks

Three layers, from the outside in. Each is tried once and never waited for; a lock that is taken ends the operation
as busy. The mutex names and the writer lock are described in [process architecture](process-architecture.md#locks).

| Operation | In-app gate | Named mutexes (`OperationMutexScope`) | Writer lock (`.writer.lock`) |
| --- | --- | --- | --- |
| Inspect an archive | None | None | No |
| Export a backup | `repository:<backup folder>` (`RepositoryRead`) | `RepositoryAccess` on the backup folder | Held while the revision is read |
| Export the current save (live export) | `save:<save folder>` | `SaveWrite` on the save folder | No |
| Import | `save:<saves root>` | `SaveWrite` on the saves root | No |
| Delete a backup, delete all backups | `repository:<backup folder>` (`RepositoryWrite`) | `RepositoryAccess` on the backup folder | Yes |
| Delete a save | `repository:<backup folder>` and `save:<save folder>` | `RepositoryAccess` on the backup folder and `SaveWrite` on the save folder | Yes, plus an open write transaction for the whole folder deletion |

- The in-app gates are one `SemaphoreSlim(1, 1)` per family and full path. `RepositoryRead` and `RepositoryWrite`
  map to the same `repository:` gate, so inside the app a backup export excludes a backup or deletion as a write
  would.
- `SaveWrite` locks are per path and do not nest. An import locks the saves root, not the folder it creates, so it
  does not exclude a restore or deletion of another save's folder. Inside the app this does not matter, because the
  page runs one action at a time (below).
- Above the gates, the Save manager page refuses every action while any operation other than a performance recording
  is running, or while one of its own actions is in progress, from its dialog to its refresh
  (`HasConflictingOperation`). While the telemetry projection is faulted, the page goes by the last operations it
  saw, so work it saw running keeps the actions locked, but work started after the fault is not seen. The gates and mutexes are what stop
  work started from the command line or a second process.
- Busy outcomes: the worker returns `Busy` and records `run.busy` when a mutex or the writer lock is taken. The
  in-process deletions throw `operation-busy`, shown as **The game or other work is using the file. Try again in a
  moment.** A taken writer lock throws `RepositoryBusyException`, whose inner sharing violation maps to the same text.

## Archive format

```text
Mode/
Mode/Save/
Mode/Save/<folders>/
Mode/Save/<files>
Mode/Save/pztools-manifest.json
```

The manifest is written last, after every file. A save file named `pztools-manifest.json` at the save's root is left
out of the archive, because the manifest takes that name. Folders are stored without compression, files with
`CompressionLevel.Optimal`.

Version 1 archives, made by older versions, hold the save's files and the manifest at the archive root. Import still
reads them; export writes only version 2.

| Manifest field (JSON, camelCase) | Value |
| --- | --- |
| `format` | `pztools-zomboid-save` |
| `version` | `2` (`1` is still read) |
| `saveId`, `mode`, `saveName` | The save's key `Mode/Save` and its two parts. A key without `/` exports as mode `Unknown`. |
| `lastPlayedUtc` | The modification time of the save's root `players.db`: from the folder for a live export, from the revision's catalog for a backup |
| `sourceId`, `revision` | The repository source and revision; `0` and `0` for a live export |
| `exportedUtc` | When the archive was written |
| `entryTimeZone` | The exporting PC's Windows time zone ID. Absent in archives from before file times were kept. |

### File times

A ZIP entry stores a local clock time without an offset, from 1980 to 2107, in two-second steps. Export writes each
file's modification time converted to the exporting PC's local time; a time outside 1981–2106 keeps the time of
writing instead. Import reads each entry time as clock time in `entryTimeZone` (in this PC's zone when the field is
missing or the zone is unknown here), each date with its own daylight saving rule
(`ZomboidArchiveService.EntryTimeUtc`). A time in a skipped hour is read one hour later; a time in a repeated hour is
read as standard time. `players.db` then gets the exact `lastPlayedUtc`, so the Save manager's last-played time
is exact and not rounded to two seconds. `ExportAndImport_KeepTheSavesFileTimes` and
`EntryTimes_AreReadInTheExportingPcsZone_EachDateWithItsOwnDaylightSaving` cover this.

## Export

Both kinds write a temporary file `<output>.<guid>.tmp` beside the chosen output and replace the output with
`File.Move(..., overwrite: true)` only after everything succeeded. On any failure the temporary file is deleted in a
`finally` and an existing output file is left as it was.

### Exporting a backup

1. The app takes the `repository:` gate and starts `PzTools.Zomboid.Archive.Cli export`.
2. The worker takes `RepositoryAccess` on the backup folder, then the writer lock, so background cleanup cannot
   rewrite or remove a pack while it reads. If cleanup or a backup holds either, the export ends `Busy` and can be
   started again.
3. It deletes `.pztools\archive-export-*` folders left in the backup folder by older versions, which restored the
   revision into a folder first.
4. It looks up the source by its numeric ID to get the key, then reads the revision with `RevisionRestorer.ReadAsync`.
   Only `Active` revisions can be read, so a deleted backup cannot be exported. Paths are checked as for a restore,
   against a folder that is never created. Folders are added first, then files in pack order.
5. Each object is verified as it is read and streamed straight into the ZIP entry. Nothing is restored to disk. A
   damaged object (`PackFormatException`) fails the export as `backup-data-damaged`, shown as **This backup is
   damaged. Choose another backup. The save is unchanged.**
6. The manifest is written, the temporary file replaces the output.

Exporting a backup is allowed while the game runs: it does not read the save.

### Exporting the current save (live export)

Live export copies the save folder as it is, without making a backup. The app refuses it while the save is being
played: **Export ZIP** is disabled for the current save while the save list shows it active or the state projection
has failed, its tooltip says **Cannot export while playing. Quit the game.**, and the click handler checks both again
after the file picker closes. The worker itself does not know whether the game is running. When it runs anyway (from
the command line, or because the game started after the check), the listing comparison below is its only protection.

1. The app takes the `save:<save folder>` gate and starts `PzTools.Zomboid.Archive.Cli export-live`. The worker takes
   `SaveWrite` on the save folder.
2. The output path must be outside the save folder.
3. The worker lists the folder recursively: relative path, file or folder, length, modification time. A reparse point
   anywhere fails the export. The save must contain `players.db`.
4. Each file is compressed straight from the save into the temporary archive, read only up to the length it was listed
   with. A file that is shorter or longer than listed fails the export.
5. After the manifest is written, the folder is listed again and compared with the first listing. Any difference fails
   the export.
6. The temporary file replaces the output.

Steps 4 and 5 fail with `export-save-changed`, shown as **The save changed while exporting. Quit the game and try
again.**

There is no private copy of the save first. It would write each of the save's many small files a second time and make
export several times slower, without adding a check: the comparison in step 5 is the check either way. The
comparison sees changes to the file list, lengths and modification times. A write that changes none of them is not
detected, and nothing makes the copy a consistent snapshot of a world the game is writing. That is why the app
requires leaving the game.

## Import

The app runs it in two worker calls: `inspect` for the preview, then `import`, which inspects again. The file picker
accepts `.zip` and `.pzsave`.

### Checks on every archive

`ValidateEntries` runs before anything is read from an entry, in both `inspect` and `import`.

| Check | Refused when |
| --- | --- |
| Entry count | More than `maximum_entries` (1,000,000) files and folders |
| One file's size | Larger than `maximum_single_file_bytes` (64 GiB) unpacked |
| Path | Empty or white space, starts with `/`, contains `:`, has a `.` or `..` segment |
| Duplicates | Two entries with the same path, ignoring case |
| Links | An entry marked as a Unix symbolic link |
| Manifest | Missing; ambiguous (no root manifest and more than one `*/pztools-manifest.json`); empty or over 1 MiB; failing CRC-32; wrong `format`; a `version` other than 1 or 2; a mode or save name that is empty, `.`, `..` or contains a character invalid in a file name |
| Layout | The manifest is not at `<Mode>/<Save>/pztools-manifest.json` (version 2) or the root (version 1); no `players.db` beside it; a version 2 entry outside `<Mode>/` and `<Mode>/<Save>/` |

The limits come from `[archive]` in the archive worker's configuration, the preview limits below from its
`[preview]` section ([files and
folders](../reference/files-and-folders.md#importing-zip-archives)). `ArchiveSafetyOptions` also has a compression-ratio
check (`archive-unsafe-ratio`), but its defaults turn it off and the worker never sets it.

The preview reads `thumb.png` only up to `thumbnail_mib` (16) and only if it starts with the PNG signature, and
extracts `players.db` to a temporary file only up to `players_database_mib` (64) to read the character's name and
hours survived. Above either limit the preview leaves that part out; the import is unaffected.

### Steps

1. The app shows the preview with **Import** disabled until inspection finishes; closing the dialog cancels it.
   **Cancel** is the default button.
2. On **Import**, the app takes the `save:<saves root>` gate and starts `import`. The worker takes `SaveWrite` on the
   saves root.
3. It inspects the archive again with the configured limits.
4. It deletes every folder in the saves root whose name starts with `.pztools-import-`, to remove staging left by an
   earlier import. This match is by prefix alone, unlike recovery's (below).
5. The mode folder must not be a reparse point; it is created if missing.
6. It chooses the name: the manifest's save name if nothing in the mode folder has it (files and folders, ignoring
   case), otherwise the first free of `Save(1)`, `Save(2)`, and so on.
7. It creates `.pztools-import-<guid>` in the saves root as staging, opens the archive again, validates the entries,
   reads the manifest again and refuses the archive if it differs from the inspected one, and checks the layout.
8. Free space: the sum of the files' unpacked sizes must fit on the saves drive with a reserve left, the larger of
   `minimum_free_space_reserve_bytes` (5 GiB) and `minimum_free_space_reserve_percent` (10) of that sum.
9. Each entry except the manifest is written into staging with `FileMode.CreateNew`, after a check that its path stays
   inside staging. Each copy stops at the entry's declared length, fails if the data is shorter or longer, and checks
   CRC-32. Each file gets its time from the ZIP entry.
10. The staged save must contain `players.db`, which gets `lastPlayedUtc`.
11. `Directory.Move` moves the staged save to `<Mode>/<chosen name>`. This is the only step that makes the save
    visible. It fails if that name appeared since step 6, so an existing save is never overwritten.
12. Staging is deleted in a `finally`.

The imported save has no backups. Its key is `Mode/<chosen name>`, so its revision numbers are independent of the
save it came from (`Restore_UsesImportedSaveKeyWithIndependentRevisionNumbers`).

### Refreshing after an import

After a successful import the app runs the state runner at once (`RefreshStateAsync`: up to
`state_refresh_attempts`, 20, tries `state_refresh_retry_ms`, 250 ms, apart while it is busy; the runner takes the
`StateCollection` mutex), then projects the state, backup, details and health views. The import's card is already
marked done when this refresh starts. If the refresh fails, that card stays done and a separate warning card adds
**Done, but the list may update late. Do not run it again.** under the success message, so the player does not
import the same archive twice.

## Deleting backups

### One backup

1. The delete button of a backup row is enabled when the page is idle, the details are not loading and the backup
   projection has not failed. It works while the game runs, and on any backup, including the newest.
2. The confirmation names the save and the backup; **Cancel** is the default.
3. After it closes, the handler checks again that the same backup of the same save is selected and the backup
   projection has not failed.
4. `DeleteRevisionAsync` takes the gate, `RepositoryAccess` and the writer lock, and calls `MarkRevisionDeletedAsync`.
   In one transaction it sets the `Active` revision to `Deleted` with `delete_reason = 'user'` and increments
   `repository_change_revision`. Anything other than exactly one row changed (the backup is gone or already deleted)
   rolls back and fails.
5. The app refreshes the views without collecting the save state.

The backup leaves the restore and export choices at once. Nothing on disk is removed here; see
[repository housekeeping](repository-housekeeping.md).

### All backups of a save

**Delete all backups** follows the same steps with `MarkAllRevisionsDeletedAsync`. The transaction reads the source
by key and fails if its ID is not the one shown (an internal error, shown as the generic error text), marks every `Active`
revision `Deleted` (`user`), and fails if there was none. The save folder is not touched: the card says **All deleted.
The save is unchanged.**

## Deleting a save

Deleting a save removes its folder permanently, without the Recycle Bin, and marks all its backups deleted.

### Before the work starts

1. The delete button of a save row is enabled when the page is idle, the save's observation is fresh, its activity is
   `Inactive` (an unknown activity also disables it) and the state projection has not failed. While the save is played the tooltip says **The save cannot be
   deleted while playing. Stop playing and try again.**
2. The confirmation names the save and its folder; **Cancel** is the default.
3. After it closes, the handler checks again that the save is still listed, fresh, not played, the state projection
   has not failed, and its folder is exactly `<saves root>\<Mode>\<Save>`. Otherwise it fails with **The save changed.
   Quit the game and try again.**

### Order of steps

`OperationCoordinator.DeleteSaveAsync`:

1. Take the `repository:` and `save:` gates, then `RepositoryAccess` and `SaveWrite`, then the writer lock.
2. `PrepareSaveRevisionDeletionAsync` opens a `BEGIN IMMEDIATE` transaction. If the repository has a source for the
   save, its recorded folder must equal the folder being deleted, or the deletion is refused. It marks every `Active`
   revision `Deleted` with `delete_reason = 'save-deleted'` and, if it marked any, increments
   `repository_change_revision`, without committing.
3. `SaveDeletionService.DeletePermanently` deletes the folder:
   1. Check the save ID: exactly `Mode/Save`, neither part empty, `.`, `..`, ending in a space or dot, or containing a
      character invalid in a file name. The saves root must not be a drive root. The folder must be inside the saves
      root. No folder from the save up to the drive root may be a reparse point. `players.db` must exist.
   2. Open `players.db` sharing only delete. This fails if the game or anything else has it open, and while the handle
      is held nobody else can open it.
   3. List everything once. A reparse point or a read-only file anywhere refuses the deletion.
   4. Open every other file once with no sharing and close it again. A file in use refuses the deletion before
      anything is deleted.
   5. Delete the files folder by folder, checking each folder's ancestors for reparse points again, leaving
      `players.db`.
   6. Delete the folders deepest first, each non-recursively. A file created after step 4 makes this fail instead of
      being deleted unchecked.
   7. Delete `players.db`, release its handle, delete the save folder.
4. Commit the transaction, with `CancellationToken.None`, because once the folder is gone a cancel request must not
   leave its backups active.
5. The app collects the save state and refreshes the views, as after an import.

The card shows the four `SaveDeletionPhase` values, the first three with counts: **Finding files to delete…**, **Checking save
files…**, **Deleting save files…** and **Removing associated backups…**.

### Failures and interruptions

| When | Save folder | Backups |
| --- | --- | --- |
| Refused in steps 3.1–3.4 | Unchanged | The transaction rolls back; unchanged |
| An error in steps 3.5–3.7 | Partly deleted. `players.db` goes last, so the folder usually still holds it and is still listed as a save. A file created in the save's root after step 3.4 makes the final folder delete fail after `players.db` is gone; the folder then remains without it. | Rolled back; still `Active` and restorable |
| The process ends during steps 3.5–3.7 | The same | SQLite rolls back the open transaction; still `Active` |
| The commit in step 4 fails | Deleted | Still `Active`. The card says **The save was deleted, but its backups remain.** (`SaveBackupDeletionFailedException`) |
| The process ends between step 3 and the commit | Deleted | Still `Active` |

Files and the database cannot change in one transaction, so these are the only partial states. Backups left `Active`
for a folder that no longer exists are later removed by [orphan cleanup](repository-housekeeping.md#orphan-cleanup),
once it confirms the folder is missing.

Other saves, other saves' backups and archives exported earlier are never touched
(`Deletion_PermanentlyDeletesOnlySelectedSave`, `DeleteSave_DeletesSelectedFolderAndAllItsBackupsOnly`,
`Deletion_DoesNotCleanUpPreviouslyStoredSaves`).

## Interrupted archive operations

| Interrupted | Left behind | Cleaned up by |
| --- | --- | --- |
| Export (either kind) | `<output>.<guid>.tmp` beside the chosen output. The output, if it existed, is unchanged. | Nothing; the file stays until deleted by hand |
| Import before step 11 | `.pztools-import-<guid>` in the saves root; no save appears | The next import (step 4), and [interrupted-operation recovery](process-architecture.md#recovering-interrupted-operations) at app start and in every orphan-backups pass, which deletes it under `SaveWrite` on the saves root, so never during a running import |
| Import after step 11 | A complete save | — |

The state collector ignores `.pztools-import-<guid>` folders (`SaveOperationPaths.IsTemporaryDirectory`), so a half
extracted import is never listed as a save. Recovery deletes only names whose suffix is a GUID and keeps lookalikes
such as `.pztools-import-ordinary-save` (`ImportLookalikeDirectory_IsPreserved`); the import's own cleanup in step 4
does not make that distinction.

## Tests

| Test class | Covers |
| --- | --- |
| [`ArchiveTests`](../../tests/PzTools.Backup.Tests/ArchiveTests.cs) | Round trips, name collisions, version 1 layout, live export change detection, output inside the save, damaged objects, entry limits, path traversal, file times |
| [`ArchiveIntegrityTests`](../../tests/PzTools.Backup.Tests/ArchiveIntegrityTests.cs) | CRC-32 and changed payloads, including empty files and the manifest |
| [`SaveDeletionTests`](../../tests/PzTools.Backup.Tests/SaveDeletionTests.cs) | Scope checks, locked files, cancellation, files created after validation, progress |
| [`AppCoreTests`](../../tests/PzTools.Backup.Tests/AppCoreTests.cs) | `DeleteRevision_*`, `DeleteAllRevisions_*`, `DeleteSave_*`, `LiveExport_*`, `ArchiveInspect_*` through `OperationCoordinator` |
| [`InterruptedOperationRecoveryTests`](../../tests/PzTools.Backup.Tests/InterruptedOperationRecoveryTests.cs) | Killed imports, the import lock during recovery |
| [`ProcessPipelineIntegrationTests`](../../tests/PzTools.Backup.Tests/ProcessPipelineIntegrationTests.cs) | The published archive worker end to end |
