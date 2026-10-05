# Normalized path identities

[Documentation index](../README.md)

Every file version in the repository refers to its path by number. Paths live once, in two dictionaries shared by all sources: a **key** that decides which file a path is (letter case ignored) and one or more **spellings** that record exactly how backups saw it. A file renamed only by changing case keeps its history and is restored with the spelling it had in each backup. The tables belong to the current schema; see [repository format](repository-format.md).

## Normalizing a path

[`BackupPath.NormalizeRelative`](../../src/PzTools.Backup.Core/BackupPath.cs) turns a path relative to the save folder into the stored spelling:

- `\` becomes `/`; trailing `/` is removed.
- Rooted paths, a leading `/`, empty segments, `.` and `..` are rejected.
- Case and every other character are kept as they are.

The key is that spelling passed through .NET `ToUpperInvariant()`. SQLite's `upper()` and `NOCASE` are not used in its place: they fold only ASCII and would split or merge non-ASCII names differently from the rest of the code.

## Tables

| Table | Columns | Holds |
| --- | --- | --- |
| `paths` | `path_id`, `path_key` (unique, binary collation) | Keys |
| `path_spellings` | `path_id`, `spelling_id`, `display_path` | Exact spellings, numbered from 0 per path |
| `entry_versions` | `path_id`, `spelling_id` | Only the two numbers, never a path string |

Readers use the `entry_catalog` and `current_entry_catalog` views, which join the strings back. They are views of the current schema, not a compatibility layer for older data.

Rules the database enforces:

- A composite foreign key requires each version's `(path_id, spelling_id)` to exist.
- Update triggers forbid changing a key or a spelling; rows are only inserted and, once unused, deleted.
- An insert trigger rejects a second identical spelling for the same path. It scans that path's spellings, normally one, instead of keeping an index that would store every display string a second time.

## Writing paths

Paths are interned inside the commit transaction that uses them:

- Incremental commits use `RepositoryPathWriter`: insert the key if new, read its ID, then insert the spelling if new with the next free `spelling_id` for that path, and read it back.
- The first backup keeps path strings only in its connection-local `TEMP` scan table and fills the dictionaries with set-based statements in the commit.
- No dictionary ID is cached across transactions. A rollback or a garbage-collection pass could otherwise leave a cached number pointing at a row that no longer exists, or at a different one later.

A commit with two entries whose normalized paths are equal ignoring case is refused rather than merged. The scan table has the key as its primary key, so a save folder in which a case-sensitive directory holds two names differing only in case cannot be scanned.

## Case-only renames

The key does not change, so the file keeps its `path_id`, its current-version slot and its history. The new spelling gets a new `spelling_id`; changing back reuses the old one. Both the full scan and the USN planner compare the exact spelling, so the rename produces a new version, which usually reuses the existing object (see [reusing stored objects](pack-format.md#reusing-stored-objects)).

Different sources share dictionary rows but never histories: the open version is unique per `(source_id, path_id)`, and a version's key is `(source_id, path_id, valid_from_revision)`.

## Reading paths

Restore, export, metadata reads, USN path lookups, full-scan comparisons and revision compaction all go through the dictionaries. A single-path query first resolves the key to its `path_id`, then uses the version indexes. Subtree queries compare keys as a range on segment boundaries, so `map` does not match `map_old`, and `%` and `_` in names are ordinary characters.

## Removing unused paths

A spelling is unused when no version of any source refers to it; hidden baselines and tombstones count as references. A key is unused once all its spellings are gone. [`SweepUnreferencedPathsAsync`](../../src/PzTools.Backup.Storage/Repository/RepositoryDatabase.PathCollection.cs) removes them in bounded passes:

- One budget of inspected rows (not deleted rows) covers both tables: `database_cleanup_batch_size`, default 1,000, per housekeeping pass; 1,000 when run inside a garbage-collection pass.
- With a budget above one row, spellings are swept first so a small set of orphans can go in one pass; with a budget of one, the order alternates so neither table starves.
- The positions reached are saved in `path_gc_cursor` in the same transaction as the deletions, so the next maintenance process continues where this one stopped. A window that comes back short wraps to the start on the next pass.
- No `VACUUM` runs per insertion or deletion; see [database file-space recovery](repository-housekeeping.md#database-file-space-recovery).

## Limits

- **Spelling uniqueness costs a scan of one path's spellings** on each insert. There is normally one.
- **A repository can grow slightly.** The dictionaries pay off for repeated versions of the same files. A repository where most files have a single version can end up a little larger.

## Measurements

The size experiment and verification runs from when the dictionaries were introduced are in [path normalization measurements](../history/path-normalization-measurements.md).
