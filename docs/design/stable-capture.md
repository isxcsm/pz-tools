# Stable file capture

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

While the game runs it may write a save file at any moment, including while PZ Tools
is copying it. [Stable capture](glossary.md#stable-capture) is how the backup worker
still gets a consistent copy of each file: copy it, check the copy against the file,
and try again if the file changed meanwhile. The game is never locked out or paused.
This page is for people working on the capture code or tuning its settings.

## What happens to each file

Source files are opened with read, write and delete sharing, so the game can keep
writing. Each file is copied into a private staged copy, and only that copy is used
for compression and deduplication.

1. Read the file's identity and metadata, then calculate its SHA-256 hash, `H_before`.
2. Copy the file into a private memory buffer or temporary file while calculating
   `H_copy`.
3. Accept the copy if `H_copy = H_before`. Otherwise hash the file again and accept
   the copy if `H_copy = H_after`.
4. If neither matches, discard the copy and try again, up to `runtime.capture_attempts`
   times (five attempts by default). The wait between attempts grows with each
   attempt.
5. Only an accepted copy goes on to compression or deduplication.

The identity checks also confirm that the open handle still belongs to the file
currently at that path.

If every attempt fails, the worker raises `UnstableFileException` and the backup's
pack is invalidated. A rejected copy never enters a pack.

The content check is controlled by `storage.verify_staged_copies`, which is on by
default. Turned off, copies are still staged and the before/after metadata checks
still run, but the content-consistency check is skipped.

## Missing files and access failures

A file is not treated as deleted just because `File.Exists` or `Directory.Exists`
returns false. This applies to incremental planning and to the always-include list.
A "file or path not found" error becomes a tombstone (a record that the file was
deleted) only after the worker lists the parent folders from an accessible source root
and confirms the entry is gone.

An always-include file that has never existed is skipped quietly once its absence is
confirmed.

A disconnected root, denied access, an I/O error or an ambiguous link stops the backup
from committing its revision and its [USN](glossary.md#usn-journal) checkpoint.

## Settings

These are under `[runtime]` in the backup worker's TOML file:

| Setting | Default | What it controls |
| --- | ---: | --- |
| `capture_attempts` | 5 | Copy attempts per file before giving up |
| `capture_retry_delay_ms` | 200 | Base wait between attempts, multiplied by the attempt number |
| `small_file_staging_kib` | 256 | Largest file staged in memory; `0` stages every file to disk |
| `staging_memory_mib` | 4 | Memory pool budget for staged copies |
| `capture_read_concurrency` | 4 | Files read at the same time |
| `capture_queue_capacity` | 8 | Files in flight |
| `copy_buffer_kib` | 128 | Read buffer for copying and for each full-scan hash reader |
| `full_scan_hash_batch_size` | 16 | Files per full-scan hash batch |
| `full_scan_hash_read_concurrency` | 4 | Full-scan hash readers at the same time |

See [runtime configuration](../reference/advanced-settings.md) for the allowed ranges and
[backup tuning](../history/backup-tuning.md) for the measurements behind the defaults.

## Limits

- **Per file, not per save.** Each copy is checked on its own. This does not make the
  save consistent as the game understands it, and it is not an atomic snapshot across
  several files.
- **Without verification** only the metadata checks remain to notice a file that
  changed during the copy; keep `verify_staged_copies` on for live saves.
- **The pool is not a memory limit.** `staging_memory_mib` limits staged copies only.
  Read buffers, compression and metadata use memory on top of it.

## How it works inside

### One pipeline

First and incremental backups use the same pipeline. By default four readers run at
once and eight files are in flight. A single consumer owns listing the files,
delivering progress, deduplication, writing packs and updating the catalog. The
readers only prepare private copies.

### Memory

Files up to 256 KiB are copied into fixed-size buffers.

- The 4 MiB pool budget covers active, queued, writing and reusable buffers.
- With a queue of eight, the effective capacity is 2 MiB.
- Buffers are counted by allocated capacity, not by the file's length.
- When the pool is full, readers wait, and the wait can be cancelled.
- Finished copies are consumed in the order they complete, so a slow file earlier in
  the list cannot hold up the return of buffers.

Larger files are staged to disk. A small file that grows past the threshold while it
is copied spills to disk and releases its buffer. Copies are disposed of once they are
in the pack.

On failure, cancellation or an early end of the file listing, outstanding reads are
cancelled and every copy is cleaned up before the pack is closed. The final pack
validation and the commit boundaries are not affected.

### Full-scan hashing

When the USN journal is not used, full-scan hash comparison has its own batch and
reader limits and does not keep whole file contents in memory. The number of readers
never exceeds the batch size. Each reader uses a buffer of `copy_buffer_kib`, hashes
the complete file and keeps the identity checks.
