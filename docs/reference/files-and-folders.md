# Files and folders

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](../design/glossary.md)

PZ Tools keeps its files in three separate places: the app folder with the program
itself, your own data under `%LOCALAPPDATA%\PzTools`, and the backup folders you
choose. Outside them it changes one file of the game's, and only when you set the game's
memory: the memory options in `ProjectZomboid64.json` in the game folder (see
[game memory](../design/game-memory.md)). This page lists what is in each, so you know which files are yours to edit,
which belong to the app, and what a backup folder contains. It also covers the limits
for importing ZIP archives and how jobs are numbered.

## The three places

| Place | Belongs to | Holds |
| --- | --- | --- |
| The app folder, wherever you extracted the package | The app | Program files and read-only default settings |
| `%LOCALAPPDATA%\PzTools` | You | Your preferences, editable settings, and the small databases for scheduling, game state and logs |
| The backup folder you choose | Your backups | A backup [repository](../design/glossary.md#repository) |

PZ Tools does not create its databases or `.pztools` folders next to your save folders
or next to archives you import. Development runs use the same layout for app data.

### The app folder

```text
<app folder>\                          # for example C:\Games\PzTools-v0.2.2\
  PzTools.App.exe and worker executables
  defaults\<component>\default.toml    # read-only packaged defaults
  game-bridge\                         # the game bridge, its attach runtime, extensions
  pztools-files.txt                    # every file above, with its size and SHA-256
```

**Checking the folder.** A release lists its files in `pztools-files.txt`. A little after
each start the app checks its folder against it, in the background: when the list is new to
the folder (the first start of a release, or a release extracted over it) every file is read
and hashed once; after that only missing files and sizes are looked at. A folder that is not
whole (usually a release extracted over the one running, whose files in use kept the old
version) shows a card, *PZ Tools files are not intact*, asking for the ZIP to be extracted
again into an empty folder, with the download page one click away; the files are named in
the log entry's details. Files the list does not name, such as ones left from an older release,
are not reported: nothing the app runs loads a file only because it is in its folder. A
development build has no list and is not checked. A file another program holds for a moment
(a scanner) is not blamed, and the folder is then checked whole again at the next start.

If the app folder's path has letters outside ASCII (a folder named in another alphabet, say), two small
files of the bridge are also copied to `%TEMP%\PzTools\attach\` (or, if that path is not
ASCII either, to a folder only you can write under `%ProgramData%\PzTools\attach\`), as
the game cannot load them from such a path. See [getting into the game](../design/game-bridge.md#getting-into-the-game).

The packaged defaults are the starting point for each
[component's](../design/glossary.md#component) settings. To update the app, see the
[user guide](../../README.md).

### Your data

```text
%LOCALAPPDATA%\PzTools\
  settings.toml                       # choices saved from the app
  update.json                         # what the last update check found
  install-check.json                  # the app folder last found whole, and its file list
  game-memory.json                    # the game memory chosen, and the game's own from before
  game-memory-original.json           # the game's launcher file as shipped, kept at the first change
  config\<component>\default.toml     # editable component settings
  config-backups\                     # TOML copies made by Restore default settings
  profiles-index.json                 # what each recording is, read once
  extensions\                         # game-extension settings
  control.db                          # installation-wide run_index allocator
  state.db                            # current game and save state
  scheduler.db                        # schedule and command inbox
  logs.db                             # logs shown in the app
  save-versions.json                  # last game version seen per save
  .pztools\<scheduler.db|state.db>\<component>\ # scheduler and state-pipeline telemetry
  operations\<component>\<operation>\ # temporary operation telemetry
  profiles\                           # performance recordings, one file each
  crash\                              # error reports, newest 20 kept
  cache\
  temp\
```

`config` holds one editable settings file per component; [configuration](settings.md)
lists them and explains how they combine with the packaged defaults. Existing settings
files are not moved or rewritten automatically. What each database holds is described
in [process architecture](../design/process-architecture.md#which-database-holds-what).

### A backup folder

```text
<backup folder you choose>\
  repository.db, packs\, staging\, telemetry.db
  .pztools\<component>\...            # component diagnostics
```

See [repository format](../design/repository-format.md) for what these files are, and
[telemetry](../design/telemetry.md) for the diagnostic databases.

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

Every job attempt gets a [run index](../design/glossary.md#run-index), a number that ties
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
