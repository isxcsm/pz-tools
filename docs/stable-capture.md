# Stable file capture

[Documentation index](README.md) · [User guide](../README.md)

Stable capture reads without locking or pausing game writes. It opens sources with
read/write/delete sharing and uses private staged copies for compression and
deduplication. `storage.verify_staged_copies` is enabled by default.

## Copy validation

1. Read source identity and metadata, then calculate SHA-256 `H_before`.
2. Copy into a private memory buffer or temporary file while calculating `H_copy`.
3. Accept when `H_copy = H_before`. Otherwise hash the source again and accept
   when `H_copy = H_after`.
4. If neither matches, discard the copy and retry, up to
   `runtime.capture_attempts` (five attempts by default).
5. Only an accepted copy reaches compression or deduplication.

Identity checks also verify that the open handle still corresponds to the current
path. Retry delays grow with the attempt count. Exhausting attempts raises
`UnstableFileException` and invalidates the backup's pack; rejected copies never
enter it. Turning verification off preserves staging and before/after metadata
checks but omits the content-consistency check.

This validates individual copies, not the game's semantic save consistency or an
atomic snapshot across multiple files.

## Bounded reads and memory

Initial and incremental backups use the same pipeline. The defaults are four
concurrent readers and eight files in flight. One consumer owns enumeration,
progress delivery, deduplication, pack writing, and catalog updates. Producers
only prepare private copies.

Files up to 256 KiB use fixed-size buffers. The 4 MiB pool budget includes active,
queued, writing, and reusable buffers; the queue of eight limits effective capacity
to 2 MiB. Accounting uses allocated capacity, not source length. Readers wait
cancellably when capacity is exhausted, and ready copies are consumed in completion
order so a slow earlier file cannot block buffer return.

Larger files stage to disk. A small file that grows beyond the threshold spills to
disk and releases its buffer. Copies are disposed after pack insertion. Failure,
cancellation, or early enumeration exit cancels outstanding reads and cleans all
copies before closing the pack. Final pack validation and commit boundaries remain
unchanged.

These controls are under `[runtime]` in the backup worker TOML:

| Setting | Default |
|---|---:|
| `small_file_staging_kib` | 256 |
| `staging_memory_mib` | 4 |
| `capture_read_concurrency` | 4 |
| `capture_queue_capacity` | 8 |
| `copy_buffer_kib` | 128 |
| `full_scan_hash_batch_size` | 16 |
| `full_scan_hash_read_concurrency` | 4 |

`small_file_staging_kib = 0` stages all files to disk. The pool limit is not a
total process-memory limit: read buffers, compression, and metadata are additional.

Full-scan hash comparison uses its own batch and reader limits and does not retain
whole file contents. Actual concurrency cannot exceed batch size. Each reader
uses `copy_buffer_kib`, hashes the complete file, and preserves identity checks.
See [runtime configuration](runtime-configuration.md) for allowed ranges and
[backup tuning](backup-tuning.md) for the measurements behind the defaults.

## Missing files and access failures

Incremental planning and always-include handling do not treat
`File.Exists`/`Directory.Exists` returning false as proof of deletion.
A missing-file/path error becomes a tombstone only after enumerating parents from
an accessible source root and confirming the entry is absent.

Disconnected roots, access denial, I/O errors, and ambiguous links prevent revision
and USN checkpoint commit. An always-include file that has never existed is quietly
skipped after absence is confirmed.
