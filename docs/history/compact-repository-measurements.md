# Compact repository format: measurements

[Documentation index](../README.md) · [User guide](../../README.md)

> **Historical record.** This page describes the code and measurements at the time it was written. It is kept for reference and is not updated; for current behaviour start at the [documentation index](../README.md).

Size measurements and verification runs recorded when the compact representation was introduced.
The current format is described in [compact storage](../compact-repository-format.md).

## Reproducible layout experiment

```text
python scripts/measure-compact-repository.py --baseline-ref 6f2023c --entries 22000
```

The script uses temporary databases and the production schema SQL, with the same
synthetic data in both: 22,000 objects, 22,000 versions, one pack and one revision. Both
databases are VACUUMed. It checks foreign keys, integrity, representation constraints and
the query plan. It does not read user data or benchmark real pack I/O. Run from schema 3
onwards, it uses the normalized path layout; the results below belong to schema 1.

Measured at the preceding schema-1 implementation, Python SQLite 3.46.1, 4096-byte pages:

| Profile | Format 1 bytes | Format 2 bytes | Reduction |
| --- | ---: | ---: | ---: |
| Default xxHash64 width | 14,696,448 | 7,479,296 | 49.11% |
| SHA-256 dedup width | 15,327,232 | 9,273,344 | 39.50% |

Both had zero freelist pages after compaction. The SHA-256 profile includes its new
lookup index. Real savings depend on paths, history, checksums and the SQLite version.
The summary columns add a small cost per revision. These measurements do not claim that
every later schema, or your database, has the same sizes.

## Verification at the time

- The schema-1 code `142b3af60a080de6f20ebf06c3bb4d43a7317833` passed 123/123 selected
  Windows storage tests (run `36089423483`, job `107928542649`).
- The follow-up schema-2 code passed 141/141, including 18 new performance and safety
  cases; its own document records the exact commit and TRX evidence.
- Isolated housekeeping SQL checks passed 14/14 at that stage.

Those selected suites did not cover the full application or the published distribution.
Earlier full CI runs had crash-reopen and shutdown-sharing failures outside the scope of
this optimization; the [merge review](connection-startup-and-merge-review.md)
records the later fixes. Check CI for the exact commit before merging or publishing.

The path dictionary that followed, its safeguards for historical spelling, its layout
trade-offs and its newer verification are on [path handling](../path-normalization.md). For
active-only automatic backups and the bounded version inspection of schema 5, see
[the follow-up](active-backup-followup.md).
