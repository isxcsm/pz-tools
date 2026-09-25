# Storage hotpaths (format 2 / schema 4)

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

> Historical schema-4 implementation. The current schema is 5; see [the follow-up](active-backup-followup.md).

Based on dev `52e8822a3192acaf7cb95d68e6a0657ecab0bbc3`, including localization PR #5.
This is a fresh pre-release schema: older schemas are rejected without modification,
not migrated. Use a new empty backup repository and rebuild the app and workers
from the same commit. Never reset the game's `Zomboid/Saves` folder.

## Request-driven reads and lock scope

Up to 1,024 requested paths/references drive indexed point lookups. TEMP primary
keys remove duplicate requests. Source IDs, current-version filters, historical
spellings, missing paths and Unicode keys retain their existing semantics. Larger
requests can scan the current-entry index; they must not scan historical versions.
`current_entry_catalog` pins that live index so adding maintenance indexes cannot
silently redirect these scans to the full revision history. It is a current-schema
read projection, not compatibility support.

Pure locator reads, TEMP request insertion and TEMP full-scan batches use deferred
transactions. Permanent catalog commits, compaction and GC retain immediate writer
transactions. No dirty reads, write retries or lower isolation levels are added.
Shared-cache table locks still exist: this does not promise that every writer can
run alongside every reader. Windows tests hold a writer on an unrelated table while
these readers complete, and write through another connection from an open scanner
batch's progress callback.

## Operation-scoped verified pack readers

The deduplicating capturer uses an eight-entry LRU of located readers. A cache miss
validates the full pack structure/index using the same handle that will read objects.
There is no validate-close-reopen gap. On Windows the cache alone uses FileShare.Read
(deny writes and deletion); ordinary located/UI readers keep their existing sharing.
Outside Windows no reuse is attempted because the Windows deny-write/delete contract
cannot be assumed. No permanent path-only validation cache is introduced.

Every candidate still checks its object identity/header, length, decompression,
full checksum and actual staged bytes. The 128-bit fingerprint is not a dedup key.
Eviction closes a reader before opening its replacement. Failed/mismatching/cancelled
copies evict the reader. Staging failure also clears the capturer's prior readers.
Initial/incremental runner finally blocks release handles on every completed run;
the injected capturer can then be reused. Direct users must dispose the capturer.
Captures on one capturer remain sequential, as before; readers themselves serialize
stream access. Cache state is neither persisted nor reused across writer changes.

Pinning is an intentional tradeoff: pack maintenance cannot replace those files
until the operation releases them. Normal operations already use the repository
writer lease. Tests verify Windows write/delete denial, LRU eviction, release on
failure/success/cancellation, corrupted payload/index rejection and one structural
validation for several committed objects. This is not protection against hostile
kernel-level or pre-existing memory-mapped mutation of supposedly immutable packs.

## Maintenance indexes and bounded path inspection

`stored_objects(pack_id)` supports per-pack lookup and FK checks. Version start and
non-null end indexes support revision compaction. These indexes cost space and
additional write work; they are not a free storage reduction.

A transactional singleton `path_gc_cursor` records scan positions for spelling and
path tables. A sweep limits **inspected dictionary rows**, including live rows, not
only rows successfully deleted. It resumes by indexed key range, wraps on reaching
the end and revisits names freed below the previous position. Cursor progress and
actual deletion commit or roll back together. All versions of all sources, including
tombstones and hidden baselines, continue to protect names. No cross-transaction ID
cache or inferred reference count is used.

With budget >=2, spellings are visited before keys so small orphan batches can finish
in one pass. A budget of one alternates tables to prevent starvation. Housekeeping
owns one dictionary inspection budget and suppresses duplicate path passes in its
object GC; the combined maintenance/orphan flows defer their preliminary dictionary
pass to housekeeping too. Standalone object GC still performs one 1,000-row sweep.
Returned telemetry distinguishes inspected rows from removed rows.

The budget does not bound all SQL instructions or all maintenance work: object GC,
old version discovery, history retention, pack directory enumeration and VACUUM
retain their separate existing policies. This change does not claim that an entire
maintenance invocation has constant runtime.

## Reproduction and evidence

```text
python scripts/check-path-normalization.py
python scripts/check-housekeeping-sql.py
python scripts/measure-storage-hotpaths.py --baseline-ref 52e8822
```

The benchmark uses the production schema and lookup SQL, separate isolated SQLite
DBs with equal synthetic data, and verifies result equality. Default: 22,000 objects,
22,000 paths, 66,000 file versions, 200 nonempty and 100 empty packs. Warm median of
three query executions, Python SQLite 3.46.1; no .NET/disk/game/UI time is measured.

| Query | Old ms | New ms |
| --- | ---: | ---: |
| Empty packs | 93.1649 | 0.1359 |
| 10 requested paths | 10.1168 | 0.0436 |
| 10 requested file references | 7.9025 | 0.0138 |
| 1,024 requested paths | 13.5268 | 4.6227 |
| 1,024 requested file references | 11.5649 | 1.4026 |
| 8,000 requested paths | 44.2692 | 44.7851 |
| 8,000 requested file references | 20.5861 | 12.0706 |

The large path case has no measured improvement; these are not application speedup
claims. A preliminary experiment exposed a maintenance-index-induced historical
scan, which the live projection now avoids. Query-plan tests cover both small and
large paths, before and after ANALYZE. Do not turn microbenchmark timings into a
flaky CI pass/fail threshold.

VACUUMed synthetic DB allocation grew from 14,651,392 to 16,642,048 bytes (1,990,656
additional bytes) including indexes and the cursor table. Actual user DB costs and
write throughput depend on file/history shape. No user repository was measured.

The isolated SQL suites pass locally. The new Windows tests additionally exercise
actual handle sharing, concurrent TEMP/read transactions, small/large lookup results,
maintenance index plans, cursor rollback/reopen/wrap/budget and retained restore
contents. Record Windows test and full published-payload CI evidence in the PR;
local SQL checks alone do not establish Windows or whole-product correctness.
