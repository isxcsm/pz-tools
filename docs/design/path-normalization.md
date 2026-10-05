# Normalized path identities

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

Every file in a backup is recorded with its path inside the save. The backup
[repository](glossary.md#repository) stores each path once, in two dictionaries, and
backups refer to it by number. Letter case is ignored when deciding whether two paths are
the same file, but the exact spelling each backup saw is kept, so a file renamed only by
changing its case is restored with the spelling it had at the time. This page is for
people reading or changing the storage code.

The dictionaries were introduced in schema 3 and are part of the current format; see
[repository format](repository-format.md) for the version numbers and compatibility.

## In short

- A path has one **key** (its normalized, upper-cased form) and one or more
  **spellings** (the exact forms seen in backups).
- A case-only rename keeps the same key and adds a spelling. Changing it back reuses the
  old spelling.
- Different saves can share dictionary rows without sharing their file histories.
- Keys and spellings are never rewritten. Unused ones are removed later, in bounded
  batches.

## Layout and historical spelling

| Table | Columns | Holds |
| --- | --- | --- |
| `paths` | `path_id`, `path_key` | Normalized relative keys, upper-cased with the invariant culture |
| `path_spellings` | `path_id`, `spelling_id`, `display_path` | Exact spellings; immutable |
| `entry_versions` | `path_id`, `spelling_id` | Only the two integer references, neither path string |

The key is derived by `BackupPath.NormalizeRelative(...).ToUpperInvariant()`. SQLite
`upper()` and the ASCII-only `NOCASE` are not used in its place.

Case-only changes share a path ID but get distinct spelling IDs; reverting the spelling
reuses its old ID. Different [sources](glossary.md#source) can share dictionary rows
without sharing their entry histories:

- current-entry uniqueness stays `(source_id, path_id)`
- the revision key stays `(source_id, path_id, valid_from_revision)`

Integrity rules:

- A composite foreign key requires every version's `(path_id, spelling_id)` pair to
  exist.
- Update triggers forbid rewriting identities or historical spellings.
- A spelling-uniqueness trigger checks the small primary-key range of one path.

The `entry_catalog` view joins the current normalized tables for readers. It is not a
reader for older data and not a writable compatibility schema.

## Limits

- **Spelling uniqueness is checked by a scan.** The trigger avoids a secondary index that
  would store every display string a second time. In exchange it scans the spellings of
  one canonical path linearly; there is normally one.
- **Small repositories can grow slightly.** Normalization pays off for repeated file
  versions, not for the mere number of backups: unchanged files create no new versions.
  A repository where most files have a single version can become slightly larger (see the
  measurements below).

## How it works inside

### Commit

- An initial scan keeps path strings only in connection-local `TEMP` staging. The
  persistent dictionaries are filled in the initial catalog commit, not during scanning,
  and that insertion is set-based.
- An incremental backup inserts with reusable commands, in the same transaction as the
  versions, summaries and checkpoint.
- No dictionary ID is cached across transactions, so a rollback or GC cannot leave a
  stale cached ID.

### Reads

Restore, archive and metadata reads, USN path lookup, full-scan comparisons and revision
compaction all use the normalized tables. A point metadata query first resolves the
numeric path ID and then uses the source/path/revision index; the cached catalog totals
remain. Prefix lookups keep segment-boundary matching and treat wildcard characters
literally.

### Reclamation

- GC removes a spelling only when no version in any source refers to it, counting hidden
  baselines and tombstones. It removes a key only after all its spellings have gone.
- The composite child index supports both the foreign-key checks and these reference
  tests.
- Each dictionary sweep limits the number of rows it inspects across both tables
  together, not only the rows it deletes. Its progress is saved, so the next maintenance
  process continues the scan.
- Object GC includes a sweep of at most 1,000 rows. Periodic housekeeping also works
  through its configured batch even when there are no new backups or deletions.
- No `VACUUM` runs for each path insertion or deletion.

## Measurements

The size experiment and the verification runs from when normalized paths were introduced
are kept in [path normalization measurements](../history/path-normalization-measurements.md).
