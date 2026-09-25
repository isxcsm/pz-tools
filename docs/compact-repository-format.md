# Compact repository format 2 (pre-release breaking change)

The current layout is **format 2 / schema 2**. See the [performance follow-up](storage-performance.md)
for revision summary columns, deduplication before compression and current verification.
There is deliberately no migration or dual-format reader for format 1 or schema 1.
Old data is rejected with `repository-reset-required`, never automatically deleted.
Use a new empty backup directory. Do not reset the game's `Zomboid/Saves` directory.
Rebuild/publish the application and workers together.

## Compact representations

| Data | Format 1 | Format 2 |
| --- | --- | --- |
| Change-detection fingerprint | 32-byte SHA-256 plus algorithm text | First 16 bytes; algorithm implicit |
| File and parent identity | 49 UTF-8 bytes | 24 bytes: volume 64 bits and reference 128 bits, big-endian |
| Object, pack and repository GUID | 36-character text | 16-byte `Guid.ToByteArray()` layout |
| Entry modified/changed time | 33-character timestamp | Signed 64-bit UTC .NET ticks, 100 ns |
| Stored checksum/compression algorithm | Repeated names | Validated integer codes |

These are field-payload sizes, not row/database sizes. Low-volume workflow/revision
timestamps and source checkpoint strings remain unchanged. Time conversion preserves
instant and precision; display timezone offsets are not persisted. File identity
retains the volume bits. `content_hash_algorithm` is removed rather than repeated.
A full SHA-256 integrity checksum may supply its first 16 bytes for change comparison
when the optional fingerprint was not recorded. This is checksum reuse within one
format, not legacy fingerprint support. Stored fingerprints must be exactly 16 bytes.

Only the non-adversarial full-scan fingerprint is shortened. Source/copy stability
checks still use full SHA-256. Pack checksum widths are unchanged: SHA-256 is 32 bytes
and the default xxHash64 is 8 bytes. Deduplication confirms full digest and actual
bytes. Truncating the fingerprint does not accelerate SHA-256 or authenticate data.

## Implemented layout improvements

`stored_objects` uses `WITHOUT ROWID`, eliminating a separate GUID primary-key index.
Secondary indexes include its 16-byte primary key. `entry_versions` keeps rowid for
bounded reclamation. A partial `(original_length, checksum)` index supports SHA-256
deduplication; default xxHash64 objects do not populate it.

File-reference lookup compares BLOB slices using a matching expression index rather
than casting identities to text and lowercasing hex. The unused current-parent-reference
index is removed, not the parent identity column. Full-scan INSERT commands are prepared
once per session and rebound across transaction batches. The performance follow-up also
reuses object/pack/entry commit commands and adds atomic file-count/byte-count summaries.

## Reproducible layout experiment (schema-1 baseline)

```text
python scripts/measure-compact-repository.py --baseline-ref 6f2023c --entries 22000
```

The script uses temporary databases and production schema SQL, with identical synthetic
22,000 objects and 22,000 versions, one pack and one revision. Both databases are
VACUUMed. It checks foreign keys, integrity, representation constraints and query plan.
It does not read user data or benchmark actual pack I/O.

Measured at the preceding schema-1 implementation, Python SQLite 3.46.1, 4096-byte pages:

| Profile | Format 1 bytes | Format 2 bytes | Reduction |
| --- | ---: | ---: | ---: |
| Default xxHash64 width | 14,696,448 | 7,479,296 | 49.11% |
| SHA-256 dedup width | 15,327,232 | 9,273,344 | 39.50% |

Both had zero freelist pages after compaction. The SHA-256 profile includes its new
lookup index. Actual savings depend on paths, history, checksums and SQLite version.
The new summary columns add a small per-revision cost; these historical measurements
are not a claim that every future schema or the user's database has identical sizes.

## Verification history

The schema-1 code `142b3af60a080de6f20ebf06c3bb4d43a7317833` passed 123/123 selected
Windows storage tests (run `36089423483`, job `107928542649`). The follow-up schema-2
code passed 141/141 including 18 new performance/safety cases; see its document for
exact commit and TRX evidence. Isolated housekeeping SQL checks pass 14/14.

Selected suites are not the full application/published-distribution gate. Earlier
full CI had crash reopen and shutdown sharing failures that are not dismissed or
silenced by this optimization. Consult final-head CI before merging or publishing.
The path dictionary remains a separate unimplemented candidate; historical spelling,
case-only renames and compaction/restore joins require independent validation.
