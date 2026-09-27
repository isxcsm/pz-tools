# Storage performance follow-up

[Documentation index](README.md) · [User guide](../README.md)

Historical performance record spanning the named schema-2 commits, subsequent schema-3
path work and the dated full-scan follow-up below. See [repository format](repository-format.md)
for the current layout and compatibility contract; [storage hotpaths](storage-hotpaths.md)
records the later schema-4 work.

## Implemented changes

### Deduplicate before compression

Deduplication retained the staged copy's full SHA-256 digest even with optional
verification/fingerprint flags disabled. It searched the current pack and committed
repository by digest and length, then compared bytes. Only new objects were compressed
and written; reused files reported `deduplication` progress. Failed or cancelled
comparison invalidated the writer.

The 16-byte fingerprint was not a dedup key. Full integrity/collision checks remained;
same-run keys used four 64-bit values instead of a 64-character digest allocation.
The saving was redundant compression/writing, while hashing and byte reads remained.

### Reuse bounded comparison memory

`ContentComparisonStream` reused one rented 128 KiB buffer per comparison, chunking
larger blocks. Disposal returned/cleared it without disposing the borrowed source.
A short source meant mismatch; cancellation and I/O errors propagated.

### Commit revision totals once

`revisions.logical_size` and `revisions.file_count` became immutable snapshot totals.
Initial capture summed staging rows once; incremental commits adjusted prior totals
with checked arithmetic. Catalog changes, totals, checkpoint and completion committed
together. Empty commits inherited the baseline.

The latest revision stayed a baseline even when Deleted. Reclamation preserved retained
totals; orphan cleanup zeroed the emptied baseline before source recreation. Tests
recomputed totals independently from entry visibility intervals.

Catalog reads used totals directly and an optional indexed historical metadata lookup,
inside a deferred transaction. Object/pack registration and entry commands were prepared
once per commit batch.

## Reproducible SQL measurement

```text
python scripts/measure-catalog-performance.py --baseline-ref 2f3ce6f
```

The baseline commit must be available. Both production queries ran on the same isolated
SQLite database: 10,000 files, 100 revisions, 100 changed files per later revision and
19,900 entry versions, with independently seeded totals. After warmup, three repetitions
were measured and all 100 result rows had to match. Schema-3 runs adapted the old query
through the normalized catalog view.

Schema-2 local Python SQLite 3.46.1 medians in milliseconds:

| Catalog query | Previous aggregation | Cached totals |
| --- | ---: | ---: |
| No metadata path | 840.3681 | 0.1832 |
| Historical players.db timestamp | 860.8856 | 0.2536 |

These warm synthetic timings excluded commit-time maintenance of totals, compression,
game and UI work. C# tests checked the source/path/range index plan and write-side totals
separately; timings were not CI pass/fail thresholds.

## Verification evidence

Product commit `a4e2b04451dd6c1153539eee6b1c3a28da47c6e6` passed **141/141** Windows
storage regression cases with **zero failures or skips**. New `StoragePerformanceTests`
contribute 18 cases. Evidence: Actions run `36119666063`, verify job `108021962587`,
TRX artifact `storage-performance-tests-a4e2b04451dd6c1153539eee6b1c3a28da47c6e6`.
Coverage included verified reuse and cancellation, buffer lifetime, snapshot totals
across history/cleanup, overflow, query plans and prior-schema rejection.

Isolated production housekeeping SQL checks passed **14/14**. Before this follow-up,
full CI at `2f3ce6f` recorded **678 passed, 3 failed, 36 skipped**
(run `36090166800`). Failures were two killed-process database reopen I/O errors and
one shutdown test's scheduler.db sharing violation. Their causes were not established
by the performance work and were not suppressed. Later fixes and full-suite evidence
are recorded in the [merge review](connection-startup-and-merge-review.md) and PR #1.
The targeted performance results did not cover the full application/published-payload gate.

## Subsequent path normalization

Schema 3 separated canonical path keys from immutable historical spellings, referenced
by file-version IDs. [Path normalization](path-normalization.md) records its tests and
layout costs; the schema-2 measurements above do not measure that change. The
[schema-5 follow-up](active-backup-followup.md) covers bounded version inspection.

## Bounded full-scan content reads (2026-09-27)

This follow-up batched 16 catalog entries with at most two concurrent content readers
during USN fallback. One consumer owned SQLite reads and pending changes; metadata and
progress callbacks stayed serialized. Failure cancelled/drained both readers before
release. Full SHA-256 and path-identity checks were retained, and a missing fingerprint
still required capture.

An isolated fixture of 6,127 small files (56,839,428 bytes) on warm local NTFS was
compared in alternating order over four rounds. Sequential times were 2948.6,
1981.7, 1898.2 and 1948.4 ms; the production two-reader helper took 1563.6, 1519.3,
1399.2 and 1202.3 ms. The medians were 1965.05 and 1459.25 ms (25.74% less time).
This measured file comparison only, excluding game saving, database planning and
compression. Cold storage, antivirus activity and live gameplay were not measured.

The focused full-scan/fingerprint/runner suite passed 54 tests with no skips, covering
change detection, baseline handling, ordered progress and reader lifetime. The bound
was two content readers plus one temporary serialized metadata handle. Fixtures used
no live game or user save.
