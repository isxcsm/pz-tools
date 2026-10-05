# Compact storage representation

[Documentation index](../README.md)

`repository.db` stores the fields that repeat in every file version or object as fixed-size binary values rather than text. This page lists those encodings, what each value may and may not be used for, and the index choices that go with them. Table purposes and version numbers are on [repository format](repository-format.md); path dictionaries are on [path handling](path-normalization.md).

## Encodings

| Data | Stored as | Columns |
| --- | --- | --- |
| Object, pack and repository UUID | 16-byte BLOB in `Guid.ToByteArray()` layout, length checked by `CHECK` | `object_id`, `pack_id`, `repository_id` |
| File and parent identity | 24-byte BLOB: 8-byte volume serial and 16-byte file ID, big-endian ([`FileIdentityCodec`](../../src/PzTools.Backup.Core/Capture/FileIdentityCodec.cs)) | `entry_versions.file_id`, `parent_file_id` |
| Modified and change time of a version | INTEGER, UTC .NET ticks (100 ns). The time-zone offset is not stored. | `modified_utc`, `changed_utc` |
| Change fingerprint | 16-byte BLOB, nullable: the first 16 bytes of the SHA-256 of the file's content. The algorithm is implied. | `stored_objects.content_hash` |
| Checksum and compression algorithm | INTEGER code, limited by `CHECK` and validated on read (`StorageAlgorithmCodec`) | `checksum_algorithm`, `compression_algorithm` |
| Integrity checksum | Full length: 8 bytes for xxHash64, 32 for SHA-256 | `stored_objects.checksum` |
| Path | Integer references into the dictionaries | `path_id`, `spelling_id` |
| Revision size | Two integers kept up to date by each commit | `revisions.file_count`, `logical_size` |

On FAT32, which has no 128-bit file IDs, the identity holds the 32-bit volume serial and the 64-bit file index, zero-extended into the same 24 bytes.

Not compact, because there are few of them: workflow, stage, revision and pack timestamps (ISO 8601 text), the USN checkpoint's volume and journal IDs (16 hex digits), source keys and root paths.

## What the fingerprint may be used for

| Use | Fingerprint? |
| --- | --- |
| Full-scan content comparison, when the USN journal cannot be used ([full-scan fallback](usn-journal.md#full-scan-fallback)) | Yes |
| Choosing the current object to byte-compare for reuse ([reusing stored objects](pack-format.md#reusing-stored-objects)) | Yes, as a filter only |
| Checking that a live file did not change while copied ([stable capture](stable-capture.md)) | No, full SHA-256 |
| Content deduplication key | No, full SHA-256 plus a byte comparison |
| Pack integrity | No, the object's own checksum |

When an object has no fingerprint but its checksum is SHA-256, the first 16 bytes of that checksum serve as one. The fingerprint is recorded only while `capture.full_scan_hash_comparison` is on; an object written while it was off has none, and its file is copied once more the next time a full scan compares it.

128 bits are enough for detecting accidental change. They are not a defence against crafted collisions, which is why nothing that decides identity of content relies on them alone.

## Indexes and table shapes

| Choice | Why |
| --- | --- |
| `stored_objects` and `path_spellings` are `WITHOUT ROWID` | The 16-byte key is the clustered key; there is no separate rowid plus key index |
| `entry_versions` keeps its rowid | The entry-version sweep walks rowids from a saved cursor |
| `ix_entry_versions_current`: unique, partial on open versions | One open version per path; `current_entry_catalog` forces it with `INDEXED BY` so current-only scans stay on the narrow index |
| `ix_entry_versions_current_file_reference` on `substr(file_id, 9, 16)` | USN planning looks up the 16-byte file reference directly, without hex text or lowercasing |
| `ix_entry_versions_current_missing_identity` | Finds versions without file or parent identity, which force a full scan |
| `ix_entry_versions_revision_start`, `_revision_end` | Revision compaction moves interval boundaries |
| `ix_entry_versions_object`, `ix_stored_objects_pack` | Garbage collection and pack usage |
| `ix_entry_versions_spelling` on `(path_id, spelling_id)` | Foreign-key checks and the dictionary sweep |
| `ix_stored_objects_dedup` on `(original_length, checksum)` where SHA-256 | Deduplication candidates; the default xxHash64 objects stay out of it |
| Partial indexes on `revisions` for active, active automatic and unread character data | The backup list, retention and the character reader touch only those rows |

Query shapes that matter:

- Lookups by a set of paths or file references put the values in a `TEMP` table. Up to 1,024 values drive the lookup through the index; more scan the current entries once (`RequestDrivenLookupThreshold`).
- Subtree lookups compare keys as a range, `key >= root || '/'` and `key < root || '0'` (`/` and `0` are adjacent code points), which matches whole path segments and treats `%` and `_` literally.
- `ReadCurrentFileObjectsAsync` forces the wanted paths to be the outer loop with `CROSS JOIN json_each(...)`. Left to choose, SQLite walked the source's entries and scanned the list for each: 13.6 s for an imported save of 12,636 files, against 65 ms.
- Commit loops prepare their `INSERT` and `UPDATE` commands once and rebind them per row.

## Measurements

The size experiment and verification runs from when this representation was introduced are in [compact storage measurements](../history/compact-repository-measurements.md).
