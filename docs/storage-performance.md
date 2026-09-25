# Storage performance follow-up

This follows compact format 2. The current repository is **format 2 / schema 3**.
There is no migration or dual reader for schema 1 or format 1. Opening older data
fails with `repository-reset-required` before configuration writes; it is never
automatically deleted. Start with a new empty backup directory. The game's
`Zomboid/Saves` directory is not a reset target. Publish matching app and workers.

## Implemented changes

### Deduplicate before compression

The private staged copy now retains its full SHA-256 digest. Deduplication requests
that digest even when copy-verification and optional change-fingerprint recording
are disabled. Search the current pack and committed repository by full digest and
length, then compare actual bytes. Only a new object is compressed and written.
A reused file reports a `deduplication` progress phase rather than a fake compression
phase. A failed or cancelled comparison invalidates the writer.

The short 16-byte change fingerprint is never a deduplication key. Pack checksums,
full source/copy verification, final pack validation, and collision handling are
not weakened. Same-run keys use four 64-bit values instead of allocating a 64-char
hexadecimal digest for every capture. This still hashes and compares content; it
eliminates redundant compression/writing, not all I/O for duplicates.

### Reuse bounded comparison memory

`ContentComparisonStream` rents one 128 KiB scratch buffer per comparison and chunks
larger incoming blocks. It reuses that buffer across synchronous/asynchronous writes
and the final length check. Disposal returns/clears it once, including exceptional
paths, and does not dispose the borrowed staged source stream. A shorter source is
a content mismatch, while cancellation and real I/O errors propagate.

### Commit revision totals once

`revisions.logical_size` and `revisions.file_count` are authoritative immutable
snapshot metadata. Initial capture sums the captured staging rows once. Incremental
commits start from the previous revision's totals, subtract closed live files, and
add new live files using checked arithmetic. The catalog changes, totals, checkpoint,
and completed run commit or roll back together. Empty commits inherit the baseline.

The latest revision remains a baseline even when Deleted. Reclamation preserves
retained snapshot totals. Orphan cleanup explicitly zeros its now-empty baseline
before a recreated source can make its next revision. Tests independently recompute
all retained/latest totals from entry visibility intervals.

Catalog reads no longer join every file version to every visible revision. They
read totals directly, with an indexed lookup only for the requested metadata path's
historical timestamp. No metadata path means no such lookup at execution time.
The catalog transaction is a deferred read transaction. Object/pack registration
and entry close/insert commands are prepared and reused across the commit batch.

## Reproducible SQL measurement

```text
python scripts/measure-catalog-performance.py --baseline-ref 2f3ce6f
```

The baseline commit must be present in the checkout. The script extracts both SQL
queries from production source and executes them on the SAME isolated fresh-schema
SQLite database: 10,000 files, 100 revisions, 100 changed files per later revision,
19,900 total entry versions. Summary values are independently seeded. Both queries
are warmed before three measured repetitions, and all 100 result rows must match.
No user database, game, pack compression or UI is measured.

Local Python SQLite 3.46.1 medians in milliseconds:

| Catalog query | Previous aggregation | Cached totals |
| --- | ---: | ---: |
| No metadata path | 840.3681 | 0.1832 |
| Historical players.db timestamp | 860.8856 | 0.2536 |

These are warm synthetic query measurements, NOT whole-app speedup claims or a
promise for user hardware. The cost of maintaining totals is paid on commit; that
cost is not included in this read benchmark. The new query uses a source/path/range
index for metadata, rather than a source-wide entry join. C# regression tests assert
the query plan and validate write-side totals separately. No wall-clock assertion
is used as a flaky pass/fail performance gate.

## Verification evidence

Product commit `a4e2b04451dd6c1153539eee6b1c3a28da47c6e6` passed **141/141** Windows
storage regression cases with **zero failures or skips**. New `StoragePerformanceTests`
contribute 18 cases. Evidence: Actions run `36119666063`, verify job `108021962587`,
TRX artifact `storage-performance-tests-a4e2b04451dd6c1153539eee6b1c3a28da47c6e6`.
The temporary exact-patch transfer workflow is removed after application.

Coverage includes local/committed reuse without a capture phase, disabled optional
hash flags, a forged digest candidate with different actual bytes, cancelled reuse,
bounded buffer return on success/mismatch/cancel, file-directory replacement,
case changes, deletion/resurrection, revision gaps, rollback, hidden baselines,
orphan recreation, generated histories through compaction, checked overflow,
query-plan use, and previous-schema rejection without modification.

The existing isolated production housekeeping SQL checks also pass **14/14**.
These targeted results are not the full application lifecycle/published-payload gate.
Before this follow-up, full CI at `2f3ce6f` recorded **678 passed, 3 failed, 36 skipped**
(run `36090166800`). Failures were two killed-process database reopen I/O errors and
one shutdown test's scheduler.db sharing violation. Their causes are not established
by the performance work and are not suppressed. Check the final head's full Windows
CI independently before merging or publishing. Actual user saves were not accessed.

## Remaining candidate

Path-key/display-path normalization into a separate path dictionary is not part of
this change. It needs a separate layout comparison and end-to-end validation of
historical spelling, case-only renames, compaction and restore joins. The current
path representation and case behavior remain unchanged.

Current path storage uses [normalized immutable path dictionaries](path-normalization.md).
Earlier measurements and CI counts above describe their explicitly named commits.
