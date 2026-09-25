# Compact repository format 2 (pre-release breaking change)

Format 2 starts with a single schema version 1. There is deliberately no import,
migration or dual-format reader for format 1 repositories. Existing repositories
are validated before connection-configuration writes and rejected with
`repository-reset-required`. Opening a supported repository no longer runs schema
DDL on every invocation. Neither path automatically deletes a user's database.
Use a new empty backup directory, or explicitly reset the old backup repository
after exporting anything needed. Do not reset the game's `Zomboid/Saves` folder.
Rebuild/publish the application and workers together.

## Compact representations

| Data | Previous representation | Format 2 |
| --- | --- | --- |
| Change-detection fingerprint | 32-byte SHA-256 plus repeated algorithm text | First 16 bytes of SHA-256; implicit in format 2 |
| File and parent identity | 49 UTF-8 bytes (`volume:file-id`) | 24 bytes: 64-bit volume and 128-bit reference, big-endian |
| Object, pack and repository GUID | 36-character text | 16-byte `Guid.ToByteArray()` layout |
| Entry modified/changed time | 33-character round-trip timestamp | Signed 64-bit UTC .NET ticks (100 ns) |
| Stored-object checksum/compression algorithm | Repeated enum names | Validated small integer codes |

These are field-payload sizes, not whole-row or whole-database sizes. Low-volume
workflow/revision timestamps and source checkpoint strings remain unchanged.
The timestamp conversion preserves instant and precision; a caller's display
timezone offset is not persisted. File identity retains the volume bits: this
is not a lossy truncation to only a file reference.

`content_hash_algorithm` is removed, rather than storing the same value in every
object. An available full SHA-256 integrity checksum may supply its first 16 bytes
for change comparison when the optional fingerprint was not recorded. This is
one format's checksum reuse, not support for an old fingerprint format. A stored
fingerprint must be exactly 16 bytes.

### Integrity boundaries

Only the non-adversarial full-scan change fingerprint is shortened. Source/copy
stability checks still compare full SHA-256 digests. Pack integrity algorithms
are unchanged; SHA-256 remains 32 bytes, and the default xxHash64 remains 8 bytes.
Deduplication still uses full SHA-256 and verifies actual content before reuse.
A 128-bit fingerprint is not a cryptographic authentication guarantee and has a
higher collision risk than a 256-bit fingerprint. SHA-256 computation and source
file reads are not accelerated merely by truncating the stored result.

## Additional implemented optimizations

- `stored_objects` uses `WITHOUT ROWID`, eliminating its separate GUID primary-key
  index. Secondary indexes therefore include the 16-byte primary key. This is
  deliberately not applied to `entry_versions`, whose bounded reclamation uses rowid.
- A partial `(original_length, checksum)` index for SHA-256 objects supports the
  deduplication lookup. The default xxHash64 objects do not populate that index.
- File-reference lookup compares 16-byte BLOB slices instead of casting identities
  to text, slicing hex and lowercasing. Its matching expression index is retained.
  The unused current-parent-reference index is removed; the parent identity column
  itself is retained for tracking correctness.
- Full-scan enumeration prepares one parameterized INSERT per session, reusing it
  across files and rebinding transactions at batch boundaries. Captured-file UPDATEs
  are not yet batched by this change.

## Reproducible space experiment

Run from a checkout with the baseline commit available:

```text
python scripts/measure-compact-repository.py --baseline-ref 6f2023c --entries 22000
```

The script uses isolated temporary databases and production schema SQL. It seeds
22,000 objects and 22,000 entry versions, one pack, and one active revision with
identical synthetic metadata in both layouts, then VACUUMs both. It checks foreign
keys, integrity, strict representation constraints and the dedup query plan. It
does not access real saves or repositories. This is a metadata-layout experiment,
not a pack-integrity or throughput benchmark.

Measured with Python SQLite 3.46.1, 4,096-byte pages:

| Profile | Format 1 bytes | Format 2 bytes | Reduction |
| --- | ---: | ---: | ---: |
| Default xxHash64 width | 14,696,448 | 7,479,296 | 49.11% |
| SHA-256 dedup width | 15,327,232 | 9,273,344 | 39.50% |

Both had zero free-list pages after compaction. The dedup profile includes the cost
of its new lookup index. Actual savings depend on path lengths, history, row counts,
checksum mode and SQLite version. These numbers do not predict the size of the
user's existing database; old repositories are not converted.

## Verification scope

The supplementary housekeeping SQL suite passes all 14 cases locally. Windows
storage regression suites passed **123/123**, with no failures or skipped tests,
on source commit `142b3af60a080de6f20ebf06c3bb4d43a7317833` (workflow run
`36089423483`, verify job `107928542649`). The TRX artifact identifies the exact
source commit; the workflow itself was triggered by its preceding transport commit.
The temporary source-transfer workflow and payload were removed after verification.

Eight new C# cases cover known fingerprint bytes, strict lengths, complete identity
bits, reset-required rejection without modifying the old DB, precise timestamp round
trips, binary lookup, real backup/restore with full SHA-256 checksums, query-plan use
and prepared INSERT reuse across transaction boundaries. Obsolete format-1 migration
tests were removed because migration is explicitly unsupported. Generic initialization
and transaction rollback tests remain.

The selected 123 tests are not the full application test suite. Full Windows solution,
application lifecycle and published-distribution CI must be checked against the final
commit before merging. The earlier housekeeping baseline had five full-suite failures
outside its new tests (three crash-reopen I/O errors, one projection timing assertion
and one scheduler database sharing violation); this document does not dismiss them as
flakes or claim that changing the layout fixes them.

## Remaining review findings (not implemented)

1. `DeduplicatingFileCapturer.CaptureAsync` compresses/writes a candidate before
   looking for a reusable object, then discards the write on a match. Looking up and
   validating candidates from the staged full digest before compression could avoid
   that work. Preserve full byte comparison and collision handling.
2. `ComparingWriteStream` allocates a new buffer on every comparison write. Pooling
   or reusing that buffer can reduce allocation pressure. Measure with dedup enabled.
3. `ReadCatalogIfChangedAsync` aggregates visible entry intervals across every active
   revision after a repository change. Maintaining per-revision file-count/byte-count
   summaries at commit could reduce repeated joins, but deletion, compaction and crash
   consistency need tests before introducing a redundant summary.
4. Path-key/display-path pairs are repeated across entry versions. A separate path
   dictionary with integer IDs is a candidate for long histories, not a free win:
   it adds joins and must preserve Windows case-insensitive matching and display case.

References: Microsoft.Data.Sqlite data types; SQLite WITHOUT ROWID documentation.
