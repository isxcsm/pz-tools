# Repository format

[Documentation index](README.md) · [User guide](../README.md)

The current repository format is **2**, schema **5**. Older formats and schemas
have no migration or compatibility reader. They are rejected without modification
with `repository-reset-required`. Use a new empty backup directory or explicitly
reset the backup repository after preserving needed data. The original
`Zomboid/Saves` directory is never a reset target. Build and publish the app and
workers together.

```text
repository/
  repository.db
  telemetry.db
  .pztools/<component>/telemetry.db
  packs/
  staging/
  .writer.lock
```

`repository.db` is authoritative for sources, revisions, checkpoints, object
locations, and the catalog. Telemetry databases are diagnostic; losing them does
not remove revisions. Editable settings live in the central
`%LOCALAPPDATA%/PzTools/config/<component>/default.toml`.

## Stored representation

New databases create the current schema and record version 5 in
`schema_migrations`. Existing databases must match the supported format and
schema. Repository connections enable foreign keys.

| Data | Representation |
|---|---|
| Object, pack, and repository UUIDs | 16-byte BLOB |
| File and parent identities | 24-byte BLOB: 8-byte volume identity plus 16-byte file reference |
| File modification/change times | UTC .NET ticks, preserving 100 ns precision |
| Comparison fingerprint | First 16 bytes of SHA-256; nullable |
| Checksum/compression algorithms | Validated integer codes; integrity checksums retain their full length |
| Revision totals | `file_count` and `logical_size`, updated with the catalog transaction |

Paths are interned in `paths` and `path_spellings`; file versions reference
`path_id` and `spelling_id` to preserve historical spelling, including case-only
renames. Normalization collisions fail rather than silently merge.

Object IDs are opaque locators. Deduplication uses full SHA-256 and byte comparison,
then reuses an existing object without recompression. See
[path normalization](path-normalization.md), [compact storage](compact-repository-format.md),
and [storage performance](storage-performance.md) for implementation details.

## Commit boundaries

An exclusive handle to `.writer.lock` permits repository writes. The file may
remain after exit; ownership belongs to the handle, so a leftover filename does
not block future work. Disposed leases are rejected.

The installation's `control.db` allocates `run_index`, including failed and
cancelled attempts. History cleanup does not reuse numbers.

A revision commits pack/object registration, catalog versions, totals, checkpoint,
and run completion together. Initial backups aggregate captured files once;
incremental backups apply deltas to previous totals. USN checkpoints require volume
identity, journal ID, and next USN. Delta planning queries only file references
needed by the changed records.

## Retention and deletion

Revisions store their display name, character summary, and `backup_kind`.
Count-based retention applies only to active `Automatic` revisions. `Manual`
and `Unknown` revisions are exempt from this count, but explicit deletion and
confirmed-missing-source cleanup still apply.

User deletion first marks a revision `Deleted`, excluding it from browsing,
restore, and export. The current revision/checkpoint do not roll back. Even a
deleted latest revision remains a hidden incremental baseline, retaining required
totals and objects. Orphan-source cleanup empties that baseline and sets its file
count and logical size to zero.

Reclamation runs when deleted revisions reach the default batch of 20 or the oldest
has waited 60 minutes, at the next eligible maintenance opportunity. It also covers
saves that are no longer being played. Separate bounded batches remove closed file
versions no retained revision or current baseline needs; open current versions and
current tombstones remain. Object GC removes only unreferenced objects and packs.
Conditional SQLite VACUUM reclaims database pages without recompressing packs.

Explicit pack compaction writes and verifies replacements, switches object
locations transactionally, then leaves superseded packs for GC. Automatic pack
recompression is disabled. See [repository housekeeping](repository-housekeeping.md)
for maintenance eligibility and history retention.

## Bounded maintenance

Schema 4 introduced cleanup indexes, current-entry views, and `path_gc_cursor`.
Schema 5 adds `entry_gc_cursors` for file-version inspection. Both path and version
cleanup bound inspection work and commit cursor movement with deletions. Design
details are in [storage hot paths](storage-hotpaths.md) and
[follow-up optimizations](active-backup-followup.md).
