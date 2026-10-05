# Windows USN journal

[Documentation index](../README.md)

An incremental backup has to find what changed in the save since the previous one. On NTFS it reads the volume's change journal, the [USN journal](glossary.md#usn-journal), from a checkpoint saved with the previous backup. When the journal cannot be used it scans the whole save and compares it with the catalog. Both paths produce the same list of changes, with the journal only making it faster; links follow one rule on both ([missing files and links](stable-capture.md#missing-files-and-links)). The code is in [`src/PzTools.Backup.ChangeTracking.Windows/`](../../src/PzTools.Backup.ChangeTracking.Windows/) and [`IncrementalBackupRunner`](../../src/PzTools.Backup.Engine/IncrementalBackupRunner.cs).

## Checkpoint

The checkpoint is `(volume serial, journal ID, next USN)`, stored in `source_state` as `volume_identity` and `journal_id` (16-digit upper-case hex) and `next_usn` (integer). It is written in the same transaction as the revision, or by a run that found no changes ([repository format](repository-format.md#what-counts-as-committed)).

The boundary is taken when planning starts, before any record is read or file is copied. The run reads records from the old checkpoint up to that boundary and saves the boundary as the new checkpoint. Anything written while the backup copies files therefore lies after the new checkpoint and is read by the next backup. When the journal cannot be queried at all, the run keeps the old checkpoint. A first backup takes the boundary before its scan; if the journal is unavailable it stores none, and the next backup scans in full.

## Journal or full scan

`UsnJournalReader.Query` resolves the volume the save folder's files are on (`FinalVolumePath`: the opened folder's final path in volume-GUID form, which follows junctions and symbolic links; `GetVolumeInformation` for the serial), opens it and calls `FSCTL_QUERY_USN_JOURNAL` for the journal ID, first USN and next USN. `UsnCheckpointEvaluator` then decides:

| Condition | Result |
| --- | --- |
| No checkpoint stored | Full scan |
| The query fails with any Windows error, or returns a short structure | Full scan; the old checkpoint is kept |
| Volume serial differs | Full scan ("The source volume identity changed.") |
| Journal ID differs (journal deleted and recreated) | Full scan |
| Checkpoint below the first readable USN | Full scan. The journal has a fixed size, and a busy drive can overwrite the records after the checkpoint between two backups; on one development machine this was about one backup in ten. |
| Checkpoint above the next USN | Full scan |
| Some current catalog entry lacks a file or parent identity | Full scan |
| The save folder's identity differs from the parent recorded for the catalog's top-level entries | Full scan ("The save folder is not the folder the previous backup read.") |
| Reading the records fails part way (Windows error, bad record, journal changed) | Full scan, and the journal handle is released before the scan starts |
| Otherwise | Journal |

Any failure of the journal is a reason to scan, never a reason to fail the backup. RAM disks are one case: some have no volume name, and Windows answers the query with error 4390. An incremental run reports the reason as `fallback` in its `changes.planned` telemetry event; a first backup whose query fails reports it in `journal.unavailable`.

## Reading records

`ReadRange` queries the journal again, re-runs the evaluation, and refuses an upper bound beyond the current next USN. It then calls `FSCTL_READ_USN_JOURNAL` with a fixed 1 MiB buffer, all reason flags, `ReturnOnlyOnClose = 0` and record versions 2 to 3, from the checkpoint until the boundary captured at the start. Records at or past the boundary are ignored, even if the journal grows meanwhile.

`UsnRecordParser` checks each record before producing it: record length inside the buffer, version 2 or 3, file-name offset and length inside the record and even, non-negative USN, a timestamp a `DateTime` can hold. Version 2 has 64-bit file references and version 3 has 128-bit ones; both become `UInt128`. A malformed record is an `InvalidDataException`, which leads to a full scan.

## Turning records into changes

[`UsnDeltaPlanner`](../../src/PzTools.Backup.Engine/UsnDeltaPlanner.cs) works through records in batches of `journal_batch_size` (4,096) instead of holding the whole interval in memory:

1. For the file and parent references in a batch that it has not looked up yet, it reads the catalog's current paths for those references (`ReadCurrentTrackedPaths`, by the 16-byte file-reference index). Every hard-link path of a reference is tracked.
2. A record's path is its name under the parent: directly under the save root, or under a parent directory already tracked. Records under anything else are outside the save and are ignored.
3. Rename-old-name records remember the old path until the matching new-name record, also across batches. Deletes, creates and renames mark both old and new paths as affected; any other reason marks every current path of the file.
4. Data overwrite, extend and truncation reasons (also for named streams) mark the file reference as having changed content.
5. A directory that is affected becomes a subtree root: every catalog entry below it and every entry now on disk below it become candidates.

Each candidate path is then read from disk:

| Found | Becomes |
| --- | --- |
| Confirmed missing ([how](stable-capture.md#missing-files-and-links)) and in the catalog | A tombstone |
| Confirmed missing and not in the catalog | Nothing |
| A junction or symbolic link, or a path beneath one, or any other reparse point | Treated as absent, as the full scan skips it: a tombstone if it is in the catalog, otherwise nothing |
| Content-change reason recorded, new path, or any difference in spelling, kind, size, modified or change time, attributes, file identity or parent identity | A change to capture |
| Otherwise | Unchanged |

## Full-scan fallback

`StreamingFullScanner` walks the save folder and writes one row per entry into a connection-local `TEMP` table (`temp_store = FILE`), committing every `scan_batch_size` (512) rows. Reparse points inside the save are skipped and not entered; the save folder itself, or a folder above it, may be a junction (a save moved to another drive) and is followed. One SQL statement then compares the scan with the current catalog by path key:

- **Added**: a key with no live current version.
- **Modified**: spelling, kind, size, modified time, change time, attributes, file identity or parent identity differ.
- **Deleted**: a live current version whose key was not scanned.

With `capture.full_scan_hash_comparison` on (the default), files that look unchanged are also compared by content:

1. On a local NTFS volume read through `WindowsFileMetadataReader`, a file whose modified and change times are both earlier than the start of the run that made the newest revision, less 2 seconds, is trusted without reading it. On NTFS, last-write and change times read through a handle move with every write, also while the writer keeps the file open; the game writes its saves with ordinary writes, not memory mappings. The 2-second margin covers the roughly 2 ms timestamp step. FAT, exFAT and network shares get no such shortcut.
2. Every other file is hashed with SHA-256 and compared with its stored [fingerprint](compact-repository-format.md#what-the-fingerprint-may-be-used-for). A file with no stored fingerprint counts as changed and is copied once to establish one.
3. Size, times and identity are read from the open handle before and after hashing and from the path afterwards; any difference counts as changed.
4. Files are compared in batches of `full_scan_hash_batch_size` (16) by up to `full_scan_hash_read_concurrency` (4) readers, never more than the batch, each with a `copy_buffer_kib` buffer. No file content is kept.

A file that cannot be opened or read during the comparison, because it was deleted after the listing or access is denied, fails the backup; it is not retried like a capture.

With it off, only names and metadata are compared. A same-size rewrite that leaves the timestamps as they were, which FAT allows, is then missed.

## Files the journal does not see changing

NTFS writes one record per kind of change per open of a file. A file kept open and written again gets no new record until it is closed or a different kind of change happens, so a backup taken in between does not see those writes in the journal. The game keeps `players.db` and `vehicles.db` open while a save is loaded. They are listed in `capture.always_include` (with `thumb.png`) and are read on every backup whatever the journal says, and the backup asks the game to save first ([game bridge](game-bridge.md)). Sampled with Restart Manager every few seconds while paused, while running around writing about a thousand map files, and across a save, a single-player game (build 42.21) held only those two databases and their `-journal` files open; map files were opened, written and closed between samples.

## Volumes without a journal

FAT32 and exFAT drives, such as most USB sticks, have no journal, so every backup of a save there is a full scan. FAT32 also refuses the 128-bit file-ID query; `WindowsFileMetadataReader` then uses the older 64-bit file index in the same identity format. FAT keeps no change time (it reads as zero), steps last-write times by two seconds, and does not move them for a write still being buffered, which is why content comparison matters there.

## Limits

- **Administrator rights.** Opening the volume to query the journal needs an elevated process. The app and its workers run elevated; a worker started from a normal shell gets access denied and falls back to a full scan.
- **Record versions 2 and 3 only.**
- **Links inside the save are never captured**, on either path ([missing files and links](stable-capture.md#missing-files-and-links)).
- **A save folder reached through a link** is followed. The journal and the local-NTFS check use the volume of the folder's final path (`FinalVolumePath`, from the opened folder's handle), not the drive letter written in the path, which for a junction to another drive would name the wrong journal.
- **A save folder that is now another folder** (a copy moved into its place, a junction pointed elsewhere) can have nothing in the journal beneath it. When the save folder's identity differs from the parent recorded for the catalog's top-level entries, the backup scans in full.
- **A full scan reads every file's metadata** and, with content comparison, every recently written file's content.

## Tests

| Test | Needs |
| --- | --- |
| `UsnRecordParserTests` (binary parsing), `UsnCheckpointEvaluatorTests`, `UsnDeltaPlannerTests` | Nothing |
| `LinkedSourceTests` (links inside the save and a linked save folder, journal and full scan alike) | Junctions, which need no elevation |
| `UsnRecordParserTests` live volume query and range read (also checks references against `FILE_ID_INFO`) | `PZTOOLS_TEST_USN=1` in an elevated process; skipped otherwise |
| `IncrementalBackupRunnerTests.FullScanOnFat_...` | `PZTOOLS_TEST_FAT_DIR` naming a folder on a FAT32 or exFAT drive. Backs up a file there and checks that a same-size rewrite with its old time restored is still captured. |
