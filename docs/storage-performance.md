# Storage performance follow-up

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

Current schema is **4**. This document records the earlier implementation; see [storage hotpaths](storage-hotpaths.md) for the current layout, compatibility boundary and later verification.

This follows compact format 2. The repository at that follow-up was **format 2 / schema 3**.
There is no migration or dual reader for schemas 1/2 or format 1. Opening older data
fails with `repository-reset-required` before configuration writes; it is never
automatically deleted. Start with a new empty backup directory. The game's
`Zomboid/Saves` directory is not a reset target. Publish matching app and workers.
The measurements and verification history below describe the named schema-2 commits;
[path normalization](path-normalization.md) documents the subsequent schema-3 change.

## Implemented changes

### Deduplicate before compression

The private staged copy retains its full SHA-256 digest. Deduplication requests
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
No user database, game, pack compression or UI is measured. On schema 3, the old
aggregation is adapted through the normalized catalog view on the same new DB.

Schema-2 local Python SQLite 3.46.1 medians in milliseconds:

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
The temporary exact-patch transfer workflow was removed after application.

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
one shutdown test's scheduler.db sharing violation. Their causes were not established
by the performance work and were not suppressed. Later fixes and full-suite evidence
are recorded in the [merge review](connection-startup-and-merge-review.md) and PR #1.
Check the final head's full Windows CI independently before merging or publishing.
Actual user saves were not accessed.

## Subsequent path normalization

Schema 3 implements the previously deferred path dictionary. Canonical keys and
immutable historical spellings are stored separately, and file versions reference
their IDs. Historical spelling, case-only renames, compaction, restore, cross-source
sharing and dictionary collection have separate tests and layout measurements.
See [path normalization](path-normalization.md) for its scope, cost tradeoffs and
current verification rather than treating the older measurements above as schema-3 results.

For active-only automatic backups and schema-5 bounded version inspection, see
[the follow-up](active-backup-followup.md). Earlier measurements above are historical.

## Bounded full-scan content reads (2026-09-27)

When USN falls back to a full scan, content comparison now takes batches of 16
catalog entries with at most two concurrent content readers. The SQLite reader and
pending-change list remain on one consumer. Metadata calls and progress callbacks
are serialized, and failure cancels and drains both readers before releasing the
scan. Full SHA-256 calculation and before/after/current-path identity checks remain
unchanged. A missing stored fingerprint still requires a capture, not a baseline
manufactured from a later live read.

An isolated fixture of 6,127 small files (56,839,428 bytes) on warm local NTFS was
compared in alternating order over four rounds. Sequential times were 2948.6,
1981.7, 1898.2 and 1948.4 ms; the production two-reader helper took 1563.6, 1519.3,
1399.2 and 1202.3 ms. The medians were 1965.05 and 1459.25 ms (25.74% less time).
This is file-comparison throughput, not game save, database planning or compression
time. It does not reproduce the reported 19-second live fallback interval or
predict performance on cold storage, under antivirus scans or while playing.

The focused full-scan/fingerprint/runner suite passed 54 tests with no skips.
Coverage includes same-length contents with frozen timestamps, missing/mismatched
baselines, changed metadata, ordered results, serialized monotonic progress,
bounded content readers, and reader disposal on failure/cancellation. The content
reader bound is two; serialized path validation can open one additional temporary
metadata handle. No live game or user save was used by these fixtures.
