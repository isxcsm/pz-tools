# Repository housekeeping

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

Housekeeping is the cleanup PZ Tools does in the background of your backup folder (the
[repository](glossary.md#repository)): it trims old automatic backups, removes backups of
saves that no longer exist, and gives disk space back. The first sections are for anyone
who wants to know which backups get deleted and when. The later ones are for people
reading or changing the maintenance code.

Removing a backup from the list and freeing its disk space are two separate steps. A
backup leaves the list first; its disk space comes back later, in batches.

## What gets deleted and when

| Backups | When they are removed from the list |
| --- | --- |
| Automatic backups beyond the [retention](glossary.md#retention) limit | When a newer automatic backup takes the count over the limit, the oldest are marked deleted |
| Manual backups, and backups of unknown origin | Never by the count limit. Only when you delete them, or by orphan cleanup below |
| A backup you delete | At once |
| Backups of a save you delete through the app | Together with the save |
| Backups whose save folder has disappeared ([orphan backups](glossary.md#orphan-backups)) | By orphan cleanup, once the folder is confirmed missing |

A backup removed from the list can no longer be browsed, restored or exported. The count
limit is set in the app and applies only to automatic backups. Manual backups stay until
you delete them or until cleanup runs after their original save folder has disappeared.

**Export important history before you delete or move the original save.** Moving a
save folder looks the same as deleting it once cleanup has confirmed it is gone.

### Orphan cleanup

Orphan cleanup removes a save's whole backup history when its original folder is
confirmed missing under the configured saves root. It is careful about what counts as
missing. These are put off to a later pass rather than treated as a deletion:

- a saves root that cannot be read
- a path it is not sure about
- reparse points (links and junctions)
- a restore or save edit that is still pending

It also gives way to gameplay and to other work, so cleanup is not immediate.

### When disk space comes back

Deleted backups are cleaned out in batches, per save:

- As soon as a save has `revision_batch_size` deleted backups waiting (default 20), they
  can be reclaimed.
- A smaller batch can be reclaimed once the oldest has waited
  `revision_compaction_max_delay_minutes` (default 60).

Either way, the work is done by the next maintenance pass that is able to run. It can
take longer when the app is stopped, when other work is running, or when maintenance has
given way to more urgent work. Saves you are no longer playing are included: they need
neither another backup nor another deletion to trigger it.

Freeing space inside partly used data files is a further step; see
[pack space reclamation](#pack-space-reclamation).

## Settings

Edit `config/maintenance-worker/default.toml` under `%LOCALAPPDATA%\PzTools`; the
packaged defaults come from `config/defaults/maintenance-worker/default.toml` in the
source tree. See [configuration](../reference/settings.md) for how component settings are layered. Build and
publish the app and workers together, and do not use new configuration keys with an
older worker.

| Key | Default | Range | What it controls |
| --- | --- | --- | --- |
| `retain_latest_revisions` | 100 | 1 or more | Automatic backups kept when maintenance runs without the app; the app passes its own retention count instead |
| `writer_retry_delay_ms` | 200 | 50–5000 | Wait before retrying when another operation holds the repository writer |
| `revision_batch_size` | 20 | 1–1000 | Deleted backups reclaimed per save in one pass; a full batch starts at once |
| `revision_compaction_max_delay_minutes` | 60 | 0–10080 | How long a smaller batch waits |
| `history_retention_days` | 90 | 0–3650 | Minimum age of execution history before it is trimmed; 0 turns trimming off |
| `history_minimum_runs` | 1000 | 1 or more | Newest IDs kept in each run history, whatever their age |
| `database_cleanup_batch_size` | 1000 | 1–10000 | Size of each file-version and run-history cleanup batch |
| `pack_reclamation_enabled` | `true` | | `false` turns pack space reclamation off |
| `pack_reclamation_sparse_percent` | 50 | 10–90 | A pack is rewritten when less than this share of it is still needed |
| `pack_reclamation_minimum_mib` | 16 | 1 or more | Unused space needed in total before anything is copied |
| `pack_reclamation_maximum_copy_mib` | 128 | 1–4096 | About how much needed data one pass copies |
| `vacuum_enabled` | `true` | | `false` turns database file-space recovery off |
| `vacuum_minimum_free_mib` | 4 | 1 or more | Free database space needed before a rebuild |
| `vacuum_minimum_free_percent` | 25 | 1–100 | Share of free database pages needed before a rebuild |
| `vacuum_maximum_database_mib` | 256 | 1 or more | Largest database that is rebuilt automatically |

The typed preflight and the worker entry points read the same values.

## Limits

- **Not immediate.** Every step waits for a pass that is allowed to run, and gives way
  to gameplay and to other work.
- **Pack space reclamation needs the game closed** and enough free disk space (see
  below).
- **Large databases are not rebuilt automatically.** Above 256 MiB by default, the
  database keeps its reusable pages instead of starting an unbounded rebuild.
- **Not secure erasure.** Recovering database file space does not securely erase what
  was deleted.
- **Free-space checks are admission checks.** They do not guarantee that something else
  will not use up the disk at the same time.

## How it works inside

Maintenance runs as separate cleanup steps (lanes) in the maintenance worker. Each step
is bounded, so one pass does a limited amount of work and later passes continue.

### Revision reclamation

The periodic orphan-maintenance worker also checks up to four eligible sources per pass,
oldest deletion first. This is what makes reclamation reach inactive saves.

The latest revision of a save stays as a hidden incremental baseline even when it is
marked `Deleted`, because the next backup builds on it.

A closed file version (one that a later version replaced or removed) is deleted only when
its visibility interval overlaps neither an `Active` revision nor the current baseline.
Open versions and current tombstones (records that a file was removed) stay. Garbage
collection (GC) follows reclamation and keeps every object that a remaining entry still
refers to. Changes are made in batches; selecting candidates may scan more rows than the
batch limit.

<a id="pack-space-reclamation"></a>
### Pack space reclamation

**Why it is needed.** A [pack](glossary.md#pack) file is deleted only when no retained
backup needs anything in it. Each incremental backup writes one pack. A manual or older
backup usually needs a few unchanged files from many earlier packs, so every one of those
packs stays on disk with most of its content unused. Revision reclamation and GC cannot
recover that space, because the packs are still partly in use.

**What is selected.** The periodic maintenance worker rewrites sparse packs after its
other steps:

1. A committed pack is sparse when less than `pack_reclamation_sparse_percent` (default
   50) of its bytes belong to registered objects. A pack with nothing needed in it is
   ordinary garbage that GC deletes without a rewrite.
2. Nothing is copied until the sparse packs together hold at least
   `pack_reclamation_minimum_mib` (default 16) of unused space.
3. A pass takes the sparsest packs first, up to about `pack_reclamation_maximum_copy_mib`
   (default 128) of needed data, and writes them into one new pack. The sparsest pack is
   always taken, so one large pack cannot block reclamation for ever. Later passes
   continue.

A rewritten pack is fully needed, so it is not selected again until it has itself
become sparse.

**When it runs.** Only while the game is closed, and under the repository-access lock
and the [writer lease](glossary.md#writer-lock). Because of that, the periodic worker is
also dispatched as soon as the game exits and once more when the app closes, instead of
waiting for its one-minute interval. The pass is a detached process: it finishes on its
own after the app has closed, and defers by itself if the game is running.

**When it is skipped.** When free disk space is below twice the data to copy plus
64 MiB, or when free space cannot be determined.

**How it stays safe.**

1. Every object is decompressed, rewritten and compared with its recorded checksum.
2. Object locations switch to the new pack in one transaction.
3. Only then are the emptied packs removed by GC.

A pass killed at any point leaves every retained backup restorable. Before the switch,
the repository is unchanged apart from a staging file or an unregistered pack that
cleanup deletes. After it, only the emptied packs remain, for GC.

### Completed execution history

The repository keeps a record of past jobs ([workflows](glossary.md#workflow) in
`workflow_runs`, with their stages in `workflow_stages`). By default at least 90 days of
completed history and the newest 1,000 workflow IDs are kept. Only older, unreferenced
records are eligible.

These are always protected:

- running work, or work whose completion time is missing
- live stages, or stages whose completion time is missing
- the run that owns a revision, and the run that created a pack
- records with a completion time that cannot be parsed (uncertain, so kept)

Stages are deleted before their workflow parents, and runs are deleted in the same
transaction.

Housekeeping does not reset `repository_info.next_run_index`, source identities or the
current revision state. Retained backup metadata is not history garbage. Component
[telemetry](glossary.md#telemetry) has its own retention policy.
`history_retention_days = 0` turns history trimming off.

### Database file-space recovery

Maintenance may run SQLite `VACUUM` when at least 4 MiB and 25% of the logical database
pages are free. Automatic rebuilds are capped at 256 MiB by default; larger databases
keep their reusable pages. `vacuum_enabled = false` turns this step off.

Before rebuilding, the worker:

- holds the existing writer lease
- checks for active backup workflows and runs
- uses a private, non-pooled connection, and skips the step on lock contention
- checks that both the database volume and the temporary-storage volume have twice the
  logical database size plus 64 MiB free

It uses SQLite's transactional `VACUUM`, never `VACUUM INTO` followed by swapping an open
repository file. Microsoft.Data.Sqlite's async methods run native SQLite work
synchronously, so native `sqlite3_interrupt` is registered for maintenance cancellation;
the maintenance yield watcher can request the interruption.

After rebuilding, a WAL `TRUNCATE` checkpoint is attempted. Readers can put off the
physical truncation. The result reports:

- `BeforeBytes` / `AfterBytes`: logical page count times page size, not total directory
  usage
- `CheckpointCompleted`: whether the checkpoint completed
- normal skip reasons: `below-threshold`, `active-work`, `busy`, `insufficient-space`,
  `space-check-unavailable`, `database-size-limit` and `disabled`

Partly used pack files are handled separately, by
[pack space reclamation](#pack-space-reclamation).

## Verification

For an isolated SQL check:

```text
python scripts/check-housekeeping-sql.py
```

SQL fixtures alone do not establish app-level behaviour. For the production code path use
`RepositoryHousekeepingTests` and the orphan-cleanup integration tests.
`InterruptedOperationRecoveryTests` kills a real process at each boundary of pack space
reclamation.
