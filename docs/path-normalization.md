# Normalized path identities (format 2 / schema 3)

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

Current schema is **4**. This document records the earlier implementation; see [storage hotpaths](storage-hotpaths.md) for the current layout, compatibility boundary and later verification.

This is a pre-release breaking layout change. Schema 1/2 and format 1 repositories
are rejected with `repository-reset-required`; there is no migration, dual reader,
or automatic reset. Start with a new empty backup directory and matching app/workers.
Never reset `Zomboid/Saves` to apply a backup repository change.

## Layout and historical spelling

`paths(path_id, path_key)` interns invariant-uppercase normalized relative keys.
`path_spellings(path_id, spelling_id, display_path)` stores immutable exact spellings.
`entry_versions` stores only the two integer references, not either path string.

The canonical key is still derived by `BackupPath.NormalizeRelative(...).ToUpperInvariant()`;
SQLite `upper()` or ASCII-only `NOCASE` is not substituted. Case-only changes share a
path ID but have distinct spelling IDs. Reverting the spelling reuses its old ID.
Different sources can share dictionary rows without sharing their entry histories:
current-entry uniqueness remains `(source_id, path_id)` and the revision key remains
`(source_id, path_id, valid_from_revision)`.

A composite foreign key requires every version's `(path_id, spelling_id)` pair to
exist. Update triggers forbid rewriting identities or historical spellings. A
spelling-uniqueness trigger checks the small primary-key range of one path; it avoids
a secondary index that would store all display strings a second time. This trades
that index for a linear scan of the spellings of one canonical path (normally one).
The `entry_catalog` view joins the current normalized tables for readers; it is not
a legacy data reader or a writable compatibility schema.

## Commit, reads and reclamation

Initial scans keep strings only in connection-local TEMP staging. The persistent
dictionaries are populated in the initial catalog commit, not during scanning.
Initial insertion is set-based. Incremental insertion uses reusable commands in the
same transaction as versions, summaries and the checkpoint. No dictionary ID is
cached across transactions, so rollback/GC cannot produce stale cached IDs.

Restore, archive/metadata reads, USN path lookup, full-scan comparisons and revision
compaction use the normalized relations. Point metadata queries resolve the numeric
path ID before using the source/path/revision index; the cached catalog totals remain.
Prefix lookups retain segment-boundary and literal wildcard semantics.

GC removes only spellings referenced by no version in any source, including hidden
baselines and tombstones. It removes keys only after all spellings have gone. The
composite child index supports both FK checks and reference tests. Each dictionary
sweep bounds the total removed rows across both tables. Object GC includes a sweep
of at most 1,000 rows; periodic housekeeping also drains its configured batch even
when no new backups or deletions occur. No vacuum runs per path insertion/deletion.

## Reproducible layout experiment

`python scripts/measure-path-normalization.py --baseline-ref 9894bdd`

SQLite 3.46.1, 4,096-byte pages, 3,000 synthetic files, every file gets a version in
every revision, and 10% change their spelling on alternating revisions. Both layouts
use production schema SQL and are VACUUMed. Selected historical snapshots are compared
field-for-field, and both foreign keys and integrity are checked. Windows Python
SQLite 3.49.1 independently produced the same database byte sizes.

| Revisions | Entry versions | Schema 2 bytes | Schema 3 bytes | Reduction |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 3,000 | 1,118,208 | 1,150,976 | -2.93% |
| 5 | 15,000 | 4,218,880 | 3,096,576 | 26.60% |
| 20 | 60,000 | 15,892,480 | 10,489,856 | 33.99% |

Normalization benefits repeated file versions, not the mere presence of many backup
revisions: unchanged files create no new versions. A mostly single-version repository
can become slightly larger. These are synthetic metadata measurements, not user DB
measurements or backup throughput claims. The script also reports fixture construction
time, which is not a C# commit throughput benchmark.

The existing catalog benchmark now evaluates the older aggregation through
`entry_catalog` on the same normalized DB; it compares query algorithms, not the old
physical layout. The compact-format size script also seeds normalized path dictionaries.

## Verification scope

Local isolated production SQL checks: 10 path-normalization cases and 14 housekeeping
cases passed. Both suites also passed on Windows. The path suite checks interning,
spelling preservation, transaction rollback, initial set-based staging, FK/immutability
constraints, bounded collection and lookup plans.

Product commit `926d63671330e50ff7ea79d3a6624b3f5664a6d5` was built and verified on
Windows with **181/181 storage regression cases passed, zero failures or skips**.
This includes all **14 NormalizedPathTests** and the preceding **22 fingerprint cases**.
Evidence: Actions run `36140435756`, job `108088649515`, artifact `10865934595`.
The artifact contains the TRX, layout/query JSON and exact committed source ID.
The reviewed patch SHA-256 is
`e88b5bc1db0b7fa24a6ac34bafa38496825dd199f576f6ff1d54eae716cb9450`.

Coverage includes real capture/case rename/move and per-revision byte/spelling restore,
cross-source sharing, hidden baselines, compaction/GC, rollback, Unicode keys, literal
prefix handling and old-schema rejection. The same 181 cases passed in the preceding
validation run; its publication step failed on a workflow-write permission restriction,
not a test failure. Product publishing and connector-authorized CI updates were then
separated without changing product code or weakening tests.

Temporary transport workflows and payloads are removed from the final branch tree.
The regular PR workflow includes the new SQL checks, layout experiment and path suite.
Selected storage results are not whole-product validation: check the new PR's full
Windows build, lifecycle, JVM and published-distribution jobs before merging. No live
game, user saves or user repository was accessed or reset by this work.
