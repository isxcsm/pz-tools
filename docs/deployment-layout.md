# Files and folders

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

PZ Tools keeps its files in three separate places: the app folder with the program
itself, your own data under `%LOCALAPPDATA%\PzTools`, and the backup folders you
choose. This page lists what is in each, so you know which files are yours to edit,
which belong to the app, and what a backup folder contains. It also covers the limits
for importing ZIP archives and how jobs are numbered.

## The three places

| Place | Belongs to | Holds |
| --- | --- | --- |
| The app folder, wherever you extracted the package | The app | Program files and read-only default settings |
| `%LOCALAPPDATA%\PzTools` | You | Your preferences, editable settings, and the small databases for scheduling, game state and logs |
| The backup folder you choose | Your backups | A backup [repository](glossary.md#repository) |

PZ Tools does not create its databases or `.pztools` folders next to your save folders
or next to archives you import. Development runs use the same layout for app data.

### The app folder

```text
<app folder>\                          # for example C:\Program Files\PzTools\
  PzTools.App.exe and worker executables
  defaults\<component>\default.toml    # read-only packaged defaults
  save-bridge\                         # the save bridge, its attach runtime, extensions
```

The packaged defaults are the starting point for each
[component's](glossary.md#component) settings. To update the app, see the
[user guide](../README.md).

### Your data

```text
%LOCALAPPDATA%\PzTools\
  settings.toml                       # choices saved from the app
  config\<component>\default.toml     # editable component settings
  config-backups\                     # TOML copies made by Restore defaults
  extensions\                         # game-extension settings
  control.db                          # installation-wide run_index allocator
  state.db                            # current game and save state
  scheduler.db                        # schedule and command inbox
  logs.db                             # logs shown in the app
  operations\<component>\<operation>\ # temporary operation telemetry
  profiles\                           # performance recordings, one file each
  cache\
  temp\
```

`config` holds one editable settings file per component; [configuration](configuration.md)
lists them and explains how they combine with the packaged defaults. Existing settings
files are not moved or rewritten automatically. What each database holds is described
in [process architecture](process-architecture.md#which-database-holds-what).

### A backup folder

```text
<backup folder you choose>\
  repository.db, packs\, staging\, telemetry.db
  .pztools\<component>\...            # component diagnostics
```

See [repository format](repository-format.md) for what these files are, and
[telemetry](telemetry.md) for the diagnostic databases.

## Importing ZIP archives

Inspecting and importing a ZIP archive is checked against these limits:

| Setting in `[archive]` | Default | Limit |
| --- | --- | --- |
| `maximum_entries` | 1,000,000 | Files and folders in the archive, in total |
| `maximum_single_file_bytes` | 64 GiB (`68719476736`) | Uncompressed size of any one file |
| `minimum_free_space_reserve_bytes` | 5 GiB (`5368709120`) | Free space that must remain after import |
| `minimum_free_space_reserve_percent` | 10 | Free space that must remain, as a share of the archive's uncompressed contents |

The checks cover paths, links, duplicate entries, per-file sizes and the number of
bytes actually extracted. A high compression ratio alone is not a reason to reject an
archive.

There is no fixed cap on the total size extracted. Instead, before importing, the
worker estimates the space needed and requires at least
`max(5 GiB, 10% of uncompressed archive contents)` to be free afterwards. The
percentage is of the archive's contents, not of the drive's capacity.

To change the limits, edit `config/archive-worker/default.toml`, or pass a settings
file with `--config`. The packaged `defaults/archive-worker/default.toml` supplies the
initial values.

## Run numbers

Every job attempt gets a [run index](glossary.md#run-index), a number that ties
together its revision, log entries and diagnostics. Gaps in these numbers are
normal: a run that was busy or failed still used its number, and numbers are never
reused.

### How run numbers are allocated

`control.db` hands out run indices atomically, always increasing, across the whole
installation.

- A scheduler or the app allocates the number and passes it to its runners and
  workers.
- A command-line or runner call made directly allocates its own, through
  `--control-db` or the default control database.
- The number is allocated before the job tries to take its mutex.
- If the control database is unavailable, the run fails. There is no fallback to a
  local counter.

The first number allocated is at least the current UTC time in Unix milliseconds
shifted left by 16 bits. That makes collisions unlikely if a lost `control.db` is
recreated. Recovery tools may also pass the largest value seen so far as an exclusive
lower bound.
