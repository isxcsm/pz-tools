# Path normalization: measurements

[Documentation index](../README.md) · [User guide](../../README.md)

> **Historical record.** This page describes the code and measurements at the time it was written. It is kept for reference and is not updated; for current behaviour start at the [documentation index](../README.md).

Size measurements and verification runs recorded when normalized path identities were introduced.
The current design is described in [path handling](../design/path-normalization.md).

## Reproducible layout experiment

```text
python scripts/measure-path-normalization.py --baseline-ref 9894bdd
```

Setup: SQLite 3.46.1, 4,096-byte pages, 3,000 synthetic files. Every file gets a version
in every revision, and 10% change their spelling on alternating revisions. Both layouts
use the production schema SQL and are VACUUMed. Selected historical snapshots are
compared field for field, and foreign keys and integrity are checked for both. Windows
Python SQLite 3.49.1 independently produced the same database sizes in bytes.

| Revisions | Entry versions | Schema 2 bytes | Schema 3 bytes | Reduction |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 3,000 | 1,118,208 | 1,150,976 | -2.93% |
| 5 | 15,000 | 4,218,880 | 3,096,576 | 26.60% |
| 20 | 60,000 | 15,892,480 | 10,489,856 | 33.99% |

These are synthetic metadata measurements, not measurements of a user database or claims
about backup throughput. The script also reports how long it took to build the fixture;
that is not a benchmark of C# commit throughput.

The catalog benchmark was updated to evaluate the older aggregation through
`entry_catalog` on the same normalized database, so it compares query algorithms rather
than the old physical layout. The size script for
[compact storage](../design/compact-repository-format.md) was also updated to seed normalized path
dictionaries.

## Verification at the time

Local isolated production SQL checks: 10 path-normalization cases and 14 housekeeping
cases passed. Both suites also passed on Windows. The path suite checks interning,
spelling preservation, transaction rollback, initial set-based staging, foreign-key and
immutability constraints, bounded collection and lookup plans.

Product commit `926d63671330e50ff7ea79d3a6624b3f5664a6d5` was built and verified on
Windows with **181/181 storage regression cases passed, zero failures or skips**. This
includes all **14 NormalizedPathTests** and the preceding **22 fingerprint cases**.

| Evidence | ID |
| --- | --- |
| Actions run | `36140435756` |
| Job | `108088649515` |
| Artifact (TRX, layout and query JSON, exact committed source ID) | `10865934595` |
| Reviewed patch SHA-256 | `e88b5bc1db0b7fa24a6ac34bafa38496825dd199f576f6ff1d54eae716cb9450` |

Coverage included real capture, case renames and moves, per-revision restore of bytes
and spelling, sharing across sources, hidden baselines, compaction and GC, rollback,
Unicode keys, literal prefix handling and rejection of old schemas.

The same 181 cases passed in the validation run before it. That run's publication step
failed on a workflow-write permission restriction, not on a test. Publishing and CI
updates were then handled separately, without changing product code or weakening tests.
Temporary transport workflows and payloads were removed from the final branch tree. The
PR workflow at that time included the new SQL checks, the layout experiment and the path
suite.

The selected storage results did not cover the whole product. Check the exact commit's
full validation before merging; [development](../contributing/development.md) describes the current
workflow. No live game, user saves or user repository was accessed or reset by this
work.
