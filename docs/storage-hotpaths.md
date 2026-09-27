# Storage hotpaths (format 2 / schema 4)

[Documentation index](README.md) · [User guide](../README.md)

Historical schema-4 implementation based on dev `52e8822a3192acaf7cb95d68e6a0657ecab0bbc3`,
including localization PR #5. See [repository format](repository-format.md) for the
current contract and [the schema-5 follow-up](active-backup-followup.md) for later work.

## Request-driven reads and lock scope

Requests up to 1,024 paths/references used indexed point lookups, deduplicated by TEMP
primary keys. Larger requests could scan the live-entry index, pinned by
`current_entry_catalog` so maintenance indexes could not redirect reads to full history.
Source filtering, historical spellings, missing paths and Unicode semantics were retained.

Locator reads and TEMP work switched to deferred transactions; permanent writes,
compaction and GC retained immediate transactions. Isolation and shared-cache table
locks were unchanged. Windows tests checked readers alongside unrelated-table writes
and writes during scanner progress callbacks.

## Operation-scoped verified pack readers

The deduplicating capturer gained an eight-entry LRU. Cache misses validated the full
pack/index using the same handle as object reads. Cached Windows readers used
FileShare.Read to deny writes/deletion; ordinary/UI readers kept their sharing rules.
Reader reuse was disabled outside Windows, where this sharing contract could not be assumed.

Candidates still required identity/header, length, decompression, full-checksum and
byte comparison; the 128-bit fingerprint was not a dedup key. Eviction closed the old
handle first. Failure/cancellation evicted readers, staging failure cleared the cache,
and runner completion released all handles. Direct callers had to dispose the capturer.
Captures remained sequential and cache state was not persisted across writer changes.

Pinned packs could not be replaced by maintenance until release. This was an intentional
tradeoff, tested with Windows sharing, eviction, cleanup and corruption fixtures; it did
not protect against pre-existing mapped-file or kernel-level mutation.

## Maintenance indexes and bounded path inspection

`stored_objects(pack_id)` supported per-pack lookup/FK checks. Version start and non-null
end indexes supported compaction, at a cost in space and write work.

The transactional `path_gc_cursor` budgeted **inspected dictionary rows**, including
live rows. Indexed range scans resumed and wrapped to revisit newly freed names;
cursor progress and deletion committed together. Every source/version, including
tombstones and hidden baselines, protected referenced names.

Budgets >=2 visited spellings before keys; a budget of one alternated tables to prevent
starvation. Housekeeping shared one inspection budget across combined maintenance and
orphan cleanup. Standalone object GC retained a 1,000-row sweep. Telemetry distinguished
inspected from removed rows.

The budget did not bound object GC, old-version discovery, retention, pack enumeration
or VACUUM, so total maintenance time was not bounded by it.

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

The large path case showed no improvement. These query timings did not measure app
speed; query-plan tests checked small/large requests before and after ANALYZE rather
than imposing timing thresholds.

VACUUMed synthetic DB allocation grew from 14,651,392 to 16,642,048 bytes (1,990,656
additional bytes) including indexes and the cursor table. Actual user DB costs and
write throughput depend on file/history shape. No user repository was measured.

Local isolated SQL suites passed. Windows test coverage included handle sharing,
concurrent reads, query plans, cursor recovery/budgets and retained restore contents;
this record contains no final Windows or published-payload result counts.
