# Configuration

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

This page lists PZ Tools' settings: where they are stored, their defaults and allowed
values, and which one wins when the same choice is made in more than one place. For
everyday use the app's Settings screen is enough. The files described here are for
fine-tuning, and for running the [command-line tools](cli.md) without the app.

Tuning values for each background program (timeouts, buffers, polling) are on a
separate page: [advanced component settings](runtime-configuration.md).

## Where settings live

| File | What it holds |
| --- | --- |
| `%LOCALAPPDATA%/PzTools/settings.toml` | The choices you make in the app (UI preferences) |
| `%LOCALAPPDATA%/PzTools/config/<component>/default.toml` | Advanced settings, one file per [component](glossary.md#component) |
| `defaults/<component>/default.toml` in the app folder | Packaged defaults, read-only |
| `%LOCALAPPDATA%/PzTools/extensions/` | Game-extension choices (`settings.json`) and an optional tuning override per extension; packaged defaults are in `save-bridge/extensions/` in the app folder. See [game extensions](game-extensions.md) |

Workflows, schedules and recorded logs are stored in databases, not in these files.

The app creates 14 component TOML files, with English keys and comments. Changing the
UI language does not rewrite them, update their comments or insert missing keys.

To edit a component file:

1. In Settings, use **Open folder** to find the files.
2. Edit the file and save it.
3. Use **Apply settings and restart**.

**Restore defaults** moves the current `config` directory into `config-backups` and
recreates the templates. Your UI choices are kept.

## Which setting wins

The backup worker reads `config/backup-worker/default.toml`, unless `--config` selects
another file. From lowest to highest priority:

1. Code defaults
2. The TOML file
3. The same choice made in the app, where the app offers it
4. Options given explicitly on the command line

Relative source paths in that TOML file are resolved against the file's own folder.

Other components merge, in this order: the packaged `defaults/<component>/default.toml`,
the central `config/<component>/default.toml`, overlapping app settings, and an explicit
`--config`. The central file is shared by every run of that component in one
installation.

A parent process does not pass its settings on to the processes it starts. BackupRunner
and MaintenanceRunner take `--worker-config` to override their child worker's settings
explicitly; see [the command line](cli.md#runners-schedulers-and-archives).

## App settings

These live in `settings.toml` and are normally changed from the Settings screen.

| Setting | Default | Behaviour |
|---|---|---|
| `[ui].system_tray` | `false` | When enabled, closing the window hides it in the tray. Restore or exit through the tray menu. Exit asks for confirmation and stops the scheduler. |
| `[backup].automatic_enabled` | `true` | Turns automatic backups on or off, independently of the interval, death-backup and save-before-backup preferences. |
| `[backup].interval_minutes` | `5` | Integer from 1 through 60. Editing it does not turn automatic backups on. |
| `[backup].pause_periodic_during_game` | `true` | Keeps the remaining interval while the game is paused, the player is asleep, or the game's state is unknown, and resumes counting afterwards. See [game-aware timing](runtime-pause-backups.md). |

Turning automatic backups off keeps the chosen interval. It does not stop manual
backups or backups that have already started. Turning them back on checks the current
play state and starts a new interval.

Settings files from older versions have no `automatic_enabled` key. In those files
`interval_minutes = 0` means automatic backups are off, and five minutes is kept as the
interval. Reading such a file does not rewrite it; the next time settings are saved,
both fields are written. Once `automatic_enabled` is present, an interval of zero or of
the wrong type is an error.

### Stored logs

Two keys in `config/app/default.toml` decide which log entries are stored:

| Key | Default | Allowed values |
|---|---|---|
| `[logs].record_minimum_level` | `"Information"` | `Trace`, `Information`, `Warning`, `Error`, `Critical` |
| `[logs].max_entries` | `100000` | 10000 to 500000 |

The level and count filters on the Logs screen change only what is displayed. Entries
discarded by `record_minimum_level` cannot be brought back by changing a filter.

## Backup worker settings

The generated `config/backup-worker/default.toml` template includes:

```toml
format_version = 1

[capture]
save_game_before_backup = true
game_save_countdown = true
always_include = ["players.db", "vehicles.db", "thumb.png"]
full_scan_hash_comparison = true

[storage]
checksum = "auto"
compression = "auto"
content_deduplication = false
verify_staged_copies = true

[telemetry]
enabled = true
mode = "phase"
batch_size = 256
flush_interval_ms = 250
retain_runs = 100
max_database_mib = 64
```

These are the template's values. A custom TOML file that leaves out telemetry fields
gets the engine's fallback values instead: `raw` mode, 1,000 runs and 256 MiB. Run
`config show` to see the settings actually in effect.

### Saving the game first

`save_game_before_backup` asks the game to save before files are captured, when the
game integration is used. Turned off, only data already on disk is backed up.

`game_save_countdown` controls the in-game notices. Turned off, it skips the notices
and the manual backup's five-second delay, but the game is still asked to save.
Periodic backups keep their scheduled deadline either way.

Changes apply from the next backup. The app's own switches for both settings take
priority; see [save bridge](save-bridge.md#settings).

### Which files are captured

`always_include` recaptures the listed paths (relative to the save folder) in every
backup, even when the [USN journal](glossary.md#usn-journal) or a full comparison
reports no change. A file on the list that was stored before and is now missing is
recorded as deleted (a tombstone) once its absence is confirmed. Leaving the key out
uses the same default list; an explicit `[]` turns the extra capture off.

`full_scan_hash_comparison` applies when the USN journal is unavailable. It reads file
contents and compares their SHA-256 with the previous backup, including files whose
size and times match. A file with no comparison fingerprint yet is captured once to
establish a baseline. The repository stores these fingerprints as the first 16 bytes of
SHA-256 ([repository format](repository-format.md)); a full SHA-256 integrity checksum
can also serve as the baseline.

On a local NTFS drive, a file whose size, times, attributes and identity match the
previous backup is not read again if it was last written more than two seconds before
the run that made the save's newest backup began. There, a file's last-write and change
times move with every write, also while the game keeps the file open. A write in the
same instant as the previous backup's look at the file can keep the old time, so files
written around or after that run are still compared. On other drives (FAT, exFAT,
network shares) every such file is compared. See
[USN journal](usn-journal.md#when-it-is-used) for when this fallback happens.

Turning `full_scan_hash_comparison` off does not affect `always_include`, existing
fingerprints or integrity checksums.

### Checking copies

`verify_staged_copies` checks each private copy with SHA-256 and retries reads of files
that keep changing ([stable capture](glossary.md#stable-capture)). With it off, staging
and metadata checks remain but content consistency checks are reduced. Keep it on for
saves that are being played.

Capture defaults, set in the `[runtime]` section:

| Limit | Default |
|---|---|
| Parallel file readers | 4 |
| Files in flight | 8 |
| Staging memory pool | 4 MiB |
| Staging slot size | 256 KiB (so 8 files × 256 KiB = 2 MiB of staging is actually used) |
| Full-scan hash batch | 16 files, at most 4 readers |

See [stable capture](stable-capture.md) and
[advanced component settings](runtime-configuration.md) for the allowed ranges.

### Checksums and compression

| Key | Values | `auto` means |
|---|---|---|
| `checksum` | `auto`, `none`, `xxhash64`, `sha256` | XxHash64 |
| `compression` | `auto`, `none`, `brotli` | Brotli |

`content_deduplication = true` requires `checksum = "sha256"`.

### Backup names

New backups are named in the selected app language; in English, `Manual backup N` and
`Automatic backup N`. Existing names do not change when the language changes.

App `[ui].language`, worker `[naming].language` and CLI `--name-language` accept the
[supported locale codes](localization.md), including `en-US`, `ko-KR` and `ja-JP`. The
values `Korean` and `English` from older files are still read.

## Retention and cleanup

The app decides how many automatic backups to keep ([retention](glossary.md#retention)).
Manual backups and backups of unknown origin do not count towards it. They can still
be deleted explicitly, and they are covered by the separate cleanup for save folders
confirmed missing ([orphan backups](glossary.md#orphan-backups)).

Maintenance rewrites mostly unused pack files while the game is closed. The maintenance
TOML holds diagnostics and bounded maintenance controls; see
[repository housekeeping](repository-housekeeping.md).

[Telemetry](glossary.md#telemetry) retention is separate from backup retention:

- `enabled = false` turns recording off.
- A `retain_runs` or `max_database_mib` of zero turns that limit off.
- The size limit measures used database pages, not the size of the file on disk.

See [telemetry](telemetry.md) for the modes and what happens on failure.

The app owns the backup schedule. The state scheduler's `[scheduler].interval_seconds`
is used only when `--interval-seconds` is not given. Archive resource limits are listed
under [deployment layout](deployment-layout.md).

## Checking and overriding from the command line

```powershell
dotnet run --project src/PzTools.Backup.Cli -- config validate --repository C:\Backups\pz
dotnet run --project src/PzTools.Backup.Cli -- config show --repository C:\Backups\pz
```

When the CLI is used directly, define sources in TOML or pass repeated
`--source <id>=<path>` options. Source options on the command line replace the whole
TOML source list. Repeated `--always-include <relative-path>` options likewise replace
the whole `always_include` list.

Other overrides:

- `--checksum`, `--compression`
- `--content-deduplication`, `--verify-staged-copies`
- `--full-scan-hash-comparison`, `--save-game-before-backup`
- `--name-language`
- `--telemetry-{enabled,mode,batch-size,flush-ms,retain-runs,max-database-mib}`

Boolean options take `true` or `false`. Telemetry modes are `off`, `run`, `phase` and
`raw`. See the [command line](cli.md) page for all commands.

## Limits and errors

- Unknown keys and unknown options are errors.
- Source IDs must be unique, ignoring case.
- Source roots cannot overlap each other or the repository.
- `always_include` paths must be relative and cannot contain `..`.
- `always_include` does not ask the game to write unsaved changes to disk. Only
  `save_game_before_backup` does that.
- With `full_scan_hash_comparison` off, a change that keeps a file's size and times
  can be missed.
- With `automatic_enabled` present, `interval_minutes = 0` or a non-integer interval
  is an error.
