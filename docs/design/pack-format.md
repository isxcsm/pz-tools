# Pack format

[Documentation index](../README.md)

A [pack](glossary.md#pack) is a file in the repository's `packs/` folder holding the stored contents of many files, one [object](glossary.md#object) each. A pack is never changed after it is written; space is reclaimed by writing a replacement ([pack space reclamation](repository-housekeeping.md#pack-space-reclamation)). The repository database says which objects exist and where ([repository format](repository-format.md)). The code is in [`src/PzTools.Backup.Storage/Packs/`](../../src/PzTools.Backup.Storage/Packs/).

## Layout

Integers are little-endian. UUIDs use the byte layout of .NET `Guid.ToByteArray()`.

| Region | Size | Contents |
| --- | --- | --- |
| Header | 36 bytes | Magic `PZPACK01`, format version (int32, 1), pack UUID, run index that created it (int64) |
| Object records | 80-byte header + payload, repeated | Contiguous from offset 36, in index order |
| Index | 12 + 24 × count + 32 bytes | Magic `PZINDEX1`, object count (int32), one entry per object (UUID, record offset as int64), SHA-256 of the index header and entries |
| Trailer | 16 bytes | Magic `PZEND001`, offset of the index (int64) |

Object header:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | Magic `POBJ` |
| 4 | 16 | Object UUID |
| 20 | 1 | Checksum algorithm: 0 none, 1 xxHash64, 2 SHA-256 |
| 21 | 1 | Compression: 0 none, 1 Brotli |
| 22 | 2 | Flags (always 0) |
| 24 | 8 | Original length |
| 32 | 8 | Stored (payload) length |
| 40 | 1 | Checksum length: 0, 8 or 32, fixed by the algorithm |
| 41 | 7 | Zero |
| 48 | 32 | Checksum of the original bytes, zero-padded |

The database stores the same algorithms with different numbers (`stored_objects`: checksum 1 none, 2 xxHash64, 3 SHA-256; compression 1 none, 2 Brotli), the .NET enum values. `PackFormat` and `StorageAlgorithmCodec` each translate their own; do not copy codes between them.

## Algorithms

| Setting (`[storage]`, backup worker) | Default | Resolves to |
| --- | --- | --- |
| `checksum` | `auto` | xxHash64. `none` and `sha256` are the alternatives. |
| `compression` | `auto` | Brotli. `none` is the alternative. |
| `compression_level` | 3 | Brotli quality 1 to 11 for new objects. Not recorded; reading does not need it. |

`auto` is resolved before a writer opens and is never stored. Each object records the algorithms it was written with, so packs written under different settings sit side by side, and a settings change affects only new objects.

## Writing

[`PackWriter`](../../src/PzTools.Backup.Storage/Packs/PackWriter.cs):

1. `CreateAsync` creates `staging/run-<run>-<pack id>.tmp`, writes the header, and opens a delete-on-close sidecar `...idx.tmp` that collects index entries.
2. `AddObjectAsync` reserves the 80-byte header, streams the content through the checksum (over the original bytes) and, for Brotli, the compressor, then writes the header back. `DiscardLastObject` truncates the last record again; compaction uses it when a copied object does not match.
3. A failed or cancelled capture calls `Invalidate`. An invalidated writer refuses to seal.
4. `SealAndPromoteAsync` copies the sidecar into the index with its SHA-256, writes the trailer, flushes to disk and closes the file.
5. It then validates the closed file completely, decompressing and checksumming every payload, and checks that pack UUID and run index match the writer.
6. `File.Move` into `packs/<pack id>.pzpack`, never overwriting.

If sealing fails, the temporary file is deleted; if even that fails, both errors are thrown together. Disposing a writer that was not promoted deletes its temporary file. A file under `packs/` is therefore always complete and verified. It is not part of any backup until the [commit transaction](repository-format.md#what-counts-as-committed) registers it. A pack that reached `packs/` without being registered is deleted by garbage collection.

A backup run writes at most one pack. It is created when the first file needs storing, so a run that reuses every object writes none.

## Reading

| Entry point | Used by | Checks on open |
| --- | --- | --- |
| `OpenForLocatedReadsAsync` | Restore, export, single-file reads, compaction | Header, version, trailer, index checksum, index entries in order and inside the data area, pack UUID equal to the repository's. Records are not walked. |
| `OpenPinnedForLocatedReadsAsync` | Byte comparisons during a backup, through `ValidatedPackReaderCache` | The same, opened with `FileShare.Read`, so Windows denies writers and replacement while the handle lives |
| `ValidateAsync(verifyPayloads)` | Sealing, `RepositoryVerifier` | Every record header, contiguity, and optionally every payload |
| `OpenAsync` | Tests and tools | Loads every object descriptor |

Reads go to the record offset stored in `stored_objects.pack_offset`; the repository is authoritative and the index is not consulted per read. Every located read checks that the offset lies in the data area, the magic, that the object UUID is the one asked for, known algorithm codes, the checksum length for the algorithm, that the payload ends before the index, the decoded length and the checksum. Any failure is a `PackFormatException`.

`RepositoryVerifier` checks every `Committed` pack: the file exists, its length equals `packs.byte_length`, it validates with payloads, and its UUID matches. Each problem lists the `Active` revisions that need that pack.

## Reusing stored objects

A staged file copy can end up referring to an object that already exists instead of adding one. Two mechanisms do this ([`DeduplicatingFileCapturer`](../../src/PzTools.Backup.Engine/DeduplicatingFileCapturer.cs)). Both reuse the existing object UUID, pack and algorithms; nothing is compressed again.

**The path's current object.** The game rewrites every map chunk it has loaded on each save, mostly with the bytes they already had, and the new timestamps make each one look changed. An incremental backup therefore reads, for every file it is about to store, the object that path currently holds. When the lengths and the 16-byte change fingerprints match, it compares the decoded object with the staged copy byte by byte, and reuses the object only if every byte is equal. The fingerprint only picks the candidate. If the old pack cannot be read, the file is stored again rather than failing the backup. This needs the fingerprint, which is recorded only while `capture.full_scan_hash_comparison` is on (the default). With the game saving and the player standing still, 389 of 391 captured files were reused and the backup added 150 KB instead of 1.27 MB ([storage performance](../history/storage-performance.md)).

**Content deduplication** (`storage.content_deduplication`, default off, requires `checksum = "sha256"`). The staged copy's full SHA-256 and length are looked up first among objects already written in this run, then among committed SHA-256 objects (partial index `ix_stored_objects_dedup`). Each candidate is byte-compared before its object is reused. A failed or cancelled comparison invalidates the pack.

## Limits

- With checksum `none`, damage to the structure or a length change is still found, but a payload change that keeps its length is not.
- xxHash64 and SHA-256 detect accidental damage. Nothing here authenticates the data.
- Opening reads the whole index into memory, 24 bytes per object.

## Decisions

- **A short fingerprint is never a deduplication key.** Deduplication keys on the full SHA-256 and confirms with bytes; the 16-byte fingerprint only selects the one candidate for current-object reuse, which is also byte-compared.
- **Reader cache per backup, not per process.** `ValidatedPackReaderCache` keeps at most eight verified handles for one run, then closes them. A process-wide "this path was validated" cache was rejected: a file can change between operations, and the pinned handle is what makes the earlier validation still true. Any failed read drops the handle, so a partial comparison is never remembered as a validation. Outside Windows, where `FileShare.Read` does not pin a file, every comparison reopens and revalidates.
