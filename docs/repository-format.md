# Repository format

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

The backup [repository](glossary.md#repository) is the backup folder you choose, with
everything PZ Tools stores in it. This page describes what that folder contains, when a
backup counts as saved, and which storage versions this build of PZ Tools can open. It is
for people reading or changing the storage code, and for anyone whose backup folder was
refused. For where the repository sits among the other parts, see the
[overview](overview.md).

## Current version

| Version | Current |
| --- | --- |
| Repository format | **2** |
| Repository schema | **6** (schema 5 is upgraded when opened) |

This page is the one place these numbers are recorded; other pages link here. Build and
publish the app and the workers together, so that they agree on the version.

## What is in a backup folder

```text
repository/
  repository.db
  telemetry.db
  .pztools/<component>/telemetry.db
  packs/
  staging/
  .writer.lock
```

| Item | What it holds |
| --- | --- |
| `repository.db` | The authoritative record: [sources](glossary.md#source), [revisions](glossary.md#revision-backup), checkpoints, object locations and the [catalog](glossary.md#catalog) || `telemetry.db`, `.pztools/<component>/telemetry.db` | Diagnostics ([telemetry](glossary.md#telemetry)). Losing them does not remove any revision. |
| `packs/` | The [pack](glossary.md#pack) files holding the stored file contents; see [pack format](pack-format.md) |
| `staging/` | Temporary files while a pack is being written |
| `.writer.lock` | The [writer lock](glossary.md#writer-lock) |

Editable settings are not kept in the repository. They live centrally in
`%LOCALAPPDATA%/PzTools/config/<component>/default.toml`; see
[configuration](configuration.md).

## Upgrading from schema 5

Schema 5 kept every worker run twice: in `runs`, and in `workflow_runs` with its
`workflow_stages`. Each writer kept the two in step by hand. Schema 6 keeps only the
workflow tables. Revisions and packs refer to `workflow_runs`, and the `worker_runs`
view gives what `runs` used to: the run of the backup worker's stage, or of the
maintenance worker's when no backup shares the run, with its status in the five values
telemetry uses.

A schema 5 repository is upgraded the first time this build opens it, in one
transaction:

1. Any run that only `runs` recorded gets a workflow and a backup-worker stage.
2. Revisions and packs are rebuilt with the new references, and `runs` is dropped.
3. Every reference is checked before the commit. If anything fails, or the process
   stops part way, nothing is changed and the repository stays schema 5.

Processes that open the repository at the same moment wait for the first upgrade and
then find it done. No copy of the old database is kept: the transaction already makes
the upgrade all or nothing, and a copy would take as much disk as the catalog, which
grows with every save file and backup. The previous app version refuses an upgraded
repository.

## When a backup folder is refused

Formats and schemas other than the current one and schema 5 have no migration and no
compatibility reader. When the backup folder already has a non-empty `repository.db`,
its format and schema are checked before anything is written to it. If either is
unsupported, or the recorded schema and the migration table disagree, it is refused
with `repository-reset-required` and left unmodified. The app shows this as an
incompatible backup folder. PZ Tools does not convert or erase it.

A `repository.db` that is not a PZ Tools repository at all (it has no repository
identity) fails with an ordinary error instead.

To continue, either choose a new empty backup folder, or explicitly reset the backup
repository after keeping any data you need. The original `Zomboid/Saves` folder is never
a reset target.

## How it works inside

### Stored representation

A new database is created at the current schema and records version 6 in
`schema_migrations`. An existing database must match the supported format and schema,
or be [upgraded from schema 5](#upgrading-from-schema-5). Repository connections turn
on foreign keys.

| Data | Representation |
|---|---|
| Object, pack and repository UUIDs | 16-byte BLOB |
| File and parent identities | 24-byte BLOB: 8-byte volume identity plus 16-byte file reference |
| File modification and change times | UTC .NET ticks, keeping 100 ns precision |
| Comparison fingerprint | First 16 bytes of SHA-256; nullable |
| Checksum and compression algorithms | Validated integer codes; integrity checksums keep their full length |
| Revision totals | `file_count` and `logical_size`, updated in the catalog transaction |

Why these representations were chosen, and what they saved, is on
[compact storage](compact-repository-format.md).

### Paths and objects

Paths are stored once, in `paths` and `path_spellings`. File versions refer to them by
`path_id` and `spelling_id`, which keeps the spelling each backup had, including
case-only renames. If two paths in one commit normalize to the same key, the commit fails
rather than merging them silently. See [path handling](path-normalization.md).

Object IDs are opaque locators, not content hashes. Deduplication uses full SHA-256 and
a byte comparison, then reuses the existing object without compressing it again.

Independently of that setting, an incremental backup compares each file it is about to
store with the object its path already holds. The game rewrites every chunk it has
loaded on each save, mostly with the bytes they had, and a new time makes each one look
changed. When the length and the comparison fingerprint match and every byte compares
equal, the new version reuses that object. The fingerprint only picks the candidate;
the byte comparison decides. An earlier pack that cannot be read is not an error here:
the file is stored again. With the game saving each time and the player standing still,
389 of the 391 files a backup took were reused, and the backup added 150 KB instead of
1.27 MB.
[Storage performance](history/storage-performance.md) records the implementation work.

### Commit boundaries

Only a process holding an exclusive handle to `.writer.lock` may write to the
repository. The file may stay behind after the process exits: ownership belongs to the
open handle, not to the file, so a leftover file does not block later work. A lease that
has been disposed is rejected.

The installation's `control.db` hands out the `run_index`
([run index](glossary.md#run-index)), including for failed and cancelled attempts.
History cleanup never reuses a number.

A revision commits these together, in one step:

- pack and object registration
- catalog versions
- totals
- the checkpoint
- completion of the run

Until that commit the backup does not exist. An initial backup adds up the captured files
once; an incremental backup applies its changes to the previous totals.

A [USN](glossary.md#usn-journal) checkpoint needs the volume identity, the journal ID and
the next USN. Planning the changes of an incremental backup queries only the file
references that the changed records need.

### Revision metadata

Each revision stores its display name, a character summary and its `backup_kind`. A
default display name is written in the interface language of the day. The backup list
recognises an unedited default name in any language and shows it in the current one.

`game_version` is an optional, nullable column holding the version the running game
reported when the backup was made. A save contains no version string, so it is recorded
only while the game has that save loaded, and older backups have none. Repositories that
lack the column get it added in place when they are opened. This does not change the
schema version: builds that predate the column name their columns explicitly and keep
working with the same repository.

### Retention and deletion

What gets deleted and when is described for users in
[housekeeping](repository-housekeeping.md). In storage terms:

- Count-based retention applies only to active `Automatic` revisions. `Manual` and
  `Unknown` revisions are exempt from the count, but explicit deletion and cleanup after
  a confirmed missing source still apply.
- A user deletion first marks a revision `Deleted`. That hides it from browsing, restore
  and export.
- The current revision and checkpoint do not roll back. Even a deleted latest revision
  stays as a hidden incremental baseline, keeping the totals and objects the next backup
  needs. Orphan-source cleanup empties that baseline and sets its file count and logical
  size to zero.

Space is reclaimed later:

1. Reclamation runs when a source's deleted revisions reach the default batch of 20, or
   the oldest has waited 60 minutes, at the next maintenance pass that is able to run. It
   also covers saves that are no longer being played.
2. Separate bounded batches remove closed file versions that no retained revision and no
   current baseline needs. Open current versions and current tombstones stay.
3. Object GC removes only unreferenced objects and packs.
4. A conditional SQLite `VACUUM` gives database pages back without recompressing packs.
5. Pack compaction writes and verifies replacement packs, switches object locations in
   one transaction, and leaves the superseded packs for GC. Maintenance applies it
   automatically to packs that are mostly unused.

Eligibility, limits and history retention are on
[repository housekeeping](repository-housekeeping.md#pack-space-reclamation).

### Bounded maintenance

Schema 4 added cleanup indexes, current-entry views and `path_gc_cursor`. Schema 5 adds
`entry_gc_cursors` for inspecting file versions. Path cleanup and version cleanup both
limit how much they inspect at a time, and commit the cursor movement together with the
deletions. Design details are in [storage hot paths](history/storage-hotpaths.md) and
[follow-up optimizations](history/active-backup-followup.md).
