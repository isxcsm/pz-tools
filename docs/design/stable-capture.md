# Stable file capture

[Documentation index](../README.md)

The game can write a save file at any moment, including while a backup copies it. [Stable capture](glossary.md#stable-capture) gets a consistent copy of each file without locking the game out: copy the file into a private staged copy, check the copy against the file, and try again if the file changed meanwhile. Only an accepted staged copy reaches deduplication, compression and the pack. The code is [`StableFileCapturer`](../../src/PzTools.Backup.Engine/StableFileCapturer.cs) and [`FileCapturePipeline`](../../src/PzTools.Backup.Engine/FileCapturePipeline.cs). Asking the game to save before the backup is separate; see [game bridge](game-bridge.md).

## One attempt

The source is opened for reading with read, write and delete sharing, so the game keeps full access.

1. Read the file's identity through its path, then through the open handle. If they differ, the file was replaced while opening.
2. Hash the whole file through the handle with SHA-256: `H_before`.
3. Copy it from the start into the staged copy, hashing again: `H_copy`.
4. Read identity through the handle and the path. Both must still equal the identity from step 1, or the file was renamed, deleted or replaced.
5. If `H_copy` equals `H_before` (same length too), accept.
6. Otherwise hash the file once more, `H_after`, checking identity before, after and through the path. Accept if `H_copy` equals `H_after`; otherwise this attempt failed.

With `storage.verify_staged_copies = false`, steps 2, 5 and 6 are replaced by metadata checks: identity, length, modified time, change time and attributes must be identical at opening, before and after the copy, through the handle and through the path, and the copy's length must equal the file's.

The SHA-256 of the copy is also the source of the 16-byte [change fingerprint](compact-repository-format.md#what-the-fingerprint-may-be-used-for) and, with content deduplication, of the deduplication key. It describes the private copy, never a later read of the live file.

## What metadata is recorded

The catalog stores the metadata read *before* the read that matched: from step 1 when `H_copy = H_before`, from just before `H_after` otherwise. A game write that lands after that point then moves the file's times past what the catalog holds, and the next scan revisits the file instead of treating it as captured. The recorded length is always the length of the verified copy, because matching hashes can survive a size change after the metadata was read. Without verification, the metadata read through the path after the copy is recorded.

## Retries and failures

| Event | Result |
| --- | --- |
| The copy matches neither read, the identity changed, or opening or reading the source fails (`IOException`, access denied, Windows error) | The attempt is discarded. Up to `capture_attempts` (5) attempts, waiting `capture_retry_delay_ms` (200) × attempt number between them: 2 seconds of waiting in all by default. |
| All attempts fail | `UnstableFileException`; the backup fails |
| The staged copy cannot be created or written (backup drive full, for example) | The backup fails at once, without retries |
| Cancellation | The backup ends `Cancelled` |

When a backup fails or is cancelled, its pack is invalidated and deleted, no revision is committed and the [USN checkpoint](usn-journal.md#checkpoint) does not move, so the next backup sees the same changes again. A rejected copy never enters a pack. A file that disappears between planning and copying fails the backup the same way after its retries; the next backup records it as deleted.

## Missing files and links

A file is not treated as deleted because `File.Exists` or `Directory.Exists` returns false; those hide access and I/O errors. When reading a path's metadata reports "file not found" or "path not found", the planner confirms it before writing a tombstone (`ConfirmMissingEntry`):

- Neither the save folder nor any of its ancestors may be a reparse point.
- Starting at the save folder, each segment of the path is looked up by an exact-name listing of its parent that must finish without error. The first segment that is absent confirms the deletion. A segment that is now an ordinary file where a folder was also confirms it.
- A reparse point on the way, a listing error or an inaccessible folder aborts the backup instead. So does finding every segment present after all.

An always-included file that was never in the catalog and is confirmed missing is skipped quietly. A link inside the save, a disconnected drive, denied access or an I/O error stops the backup before it commits its revision or checkpoint. This applies to journal planning and to `capture.always_include`. A full scan instead lists the whole tree; a listing error fails it, and a path missing from a complete listing is a deletion.

## Pipeline and memory

First and incremental backups share one pipeline. Up to `capture_read_concurrency` (4) readers stage files at once, with at most `capture_queue_capacity` (8) files in flight, counting queued, reading and finished-but-unconsumed copies. One consumer, the backup runner, owns listing the files, progress, deduplication, writing the pack and updating the catalog; readers only produce private copies and never touch the pack writer.

| Staged copy | Where |
| --- | --- |
| File no larger than `small_file_staging_kib` (256 KiB) when opened | A fixed-size buffer from a private pool |
| Larger file, or `small_file_staging_kib = 0` | `staging/capture-<guid>.tmp` in the repository, delete-on-close |
| Small file that grows past the buffer while copied | Spills to a staging file and returns its buffer at once |

The pool holds `staging_memory_mib` (4 MiB) divided by the buffer size: 16 buffers by default. It counts buffers by capacity, not by file length, and includes buffers being read, queued, written and kept for reuse. With the default queue of eight, the queue is reached before the pool. Readers wait for a free buffer, and the wait can be cancelled. Finished copies are consumed in the order they complete, so a slow file early in the list does not hold buffers that other readers need. A copy is disposed as soon as it is in the pack.

On failure, cancellation or an early end of the file list, the pipeline cancels outstanding reads and disposes every staged copy before the runner closes or invalidates the pack.

## Settings

`[runtime]` in the backup worker's file, plus one `[storage]` key. Ranges are enforced by `BackupTuningOptions`; see [advanced settings](../reference/advanced-settings.md) for editing.

| Setting | Default | Range | Controls |
| --- | --- | --- | --- |
| `storage.verify_staged_copies` | `true` | | Hash comparison of the copy with the file |
| `capture_attempts` | 5 | 1–20 | Attempts per file |
| `capture_retry_delay_ms` | 200 | 10–5000 | Base wait, multiplied by the attempt number |
| `copy_buffer_kib` | 128 | 16–4096 | Read buffer for copying, hashing and full-scan comparison |
| `small_file_staging_kib` | 256 | 0–1024 | Largest file staged in memory; 0 stages every file to disk |
| `staging_memory_mib` | 4 | 1–256 | Staging buffer pool |
| `capture_read_concurrency` | 4 | 1–8 | Files read at the same time |
| `capture_queue_capacity` | 8 | 1–128 | Files in flight |

The measurements behind the defaults are in [backup tuning](../history/backup-tuning.md).

## Limits

- **Per file, not per save.** Each copy is consistent on its own. Several files are not captured as one atomic snapshot, and nothing here makes the save consistent as the game understands it; that is what saving the game first is for.
- **Each verified file is read at least twice**, three times when the first hash does not match.
- **Without verification** only metadata can reveal a file that changed during the copy. A write that keeps the size and lands within the timestamp resolution goes unnoticed.
- **The pool is not a memory limit.** It bounds staged copies only; read buffers, compression and catalog work use memory on top.

## Decisions

- **A private buffer pool rather than `ArrayPool.Shared`**, so that buffers kept for reuse count against the same budget as copies in use.
- **Producers never touch the pack.** Readers own only their private copies; the single consumer owns every pack write and every invalidation.
- **Metadata from before the matching read**, so that a later game write makes the file look changed rather than captured.

`StableFileCapturerTests`, `BoundedCaptureStagingTests` and `FileCapturePipelineTests` cover these rules, including a source that disappears or is denied during capture.
