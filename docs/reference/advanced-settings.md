# Advanced settings

[Documentation index](../README.md)

The TOML files in the folder that **Open folder** under **Settings → Advanced → Open configuration
files** opens. They hold
values the Settings page does not show: log storage, recording limits, how backups are
checked and stored, timeouts for talking to the game, and diagnostic records. The defaults
suit normal play. Everything on the Settings page itself is in [settings](settings.md).

## The files

The folder is `%LOCALAPPDATA%\PzTools\config`. It has one subfolder per background part of
PZ Tools, each with a `default.toml`. A missing file is created from the app's built-in
template when the app starts; an existing file is never rewritten, not even by an update.
Most keys in a template have a comment with their unit, allowed range and what changing them
does.

| File | What it controls | Worth changing? |
| --- | --- | --- |
| [`app`](../../config/defaults/app/default.toml) | Which log entries are stored, recording limits, hotkey sounds and notes, and screen refresh and timing of the app itself | Yes, see [app](#app) |
| [`backup-worker`](../../config/defaults/backup-worker/default.toml) | How each backup reads, checks, compresses and stores files, and how long it waits for the game to save | Yes, see [backup-worker](#backup-worker) |
| [`state-scheduler`](../../config/defaults/state-scheduler/default.toml) | How often the game's state is checked, how often interrupted work and backups of deleted saves are cleaned up, and the game-extension connection | A few keys, see [state-scheduler](#state-scheduler) |
| [`maintenance-worker`](../../config/defaults/maintenance-worker/default.toml) | When deleted backups give their disk space back, and rewriting mostly unused data files | A few keys, see [maintenance-worker](#maintenance-worker) |
| [`archive-worker`](../../config/defaults/archive-worker/default.toml) | Safety limits for importing a save from a ZIP file, and preview size limits | When a trusted ZIP is refused, see [archive-worker](#archive-worker) |
| [`backup-scheduler`](../../config/defaults/backup-scheduler/default.toml) | How often it checks whether a backup is due (not your backup interval) and how early it prepares one | No |
| [`backup-runner`](../../config/defaults/backup-runner/default.toml), [`maintenance-runner`](../../config/defaults/maintenance-runner/default.toml), [`state-runner`](../../config/defaults/state-runner/default.toml), [`state-collector`](../../config/defaults/state-collector/default.toml), [`state-reactor`](../../config/defaults/state-reactor/default.toml) | Diagnostic records only | No |
| [`restore-worker`](../../config/defaults/restore-worker/default.toml), [`character-recovery`](../../config/defaults/character-recovery/default.toml), [`profiler`](../../config/defaults/profiler/default.toml) | Diagnostic records, progress and activity-signal frequency | No |

Game-extension choices are not in this folder; see [files and folders](files-and-folders.md).

## Applying changes

1. Edit a file and save it.
2. In **Settings → Advanced**, choose **Apply settings and restart** and confirm.

PZ Tools first saves any edit still pending on the Settings page. It refuses with "Try
again when the current work is done." while a backup, restore or other operation runs.
It then checks every file: section names, key names, value types and ranges. If a file in
this folder fails, it names it, for example "Could not apply the settings. Check
backup-worker\default.toml.", and keeps running with the old values. A mistake it cannot
pin on one file shows "Could not apply the settings. Check what you entered."
If everything passes, the app restarts and every part reads its file again.

The app takes the values in its own file only when it starts. It does read the `app` and
`backup-worker` files again whenever you change something on the Settings page, so a mistake
in either one makes those changes fail to save until it is fixed. Each background part reads
its file when it starts, and a backup worker starts for every backup, so a `backup-worker` edit can reach
the next backup before you apply it, without being checked. Apply after every edit so a
mistake is caught before anything uses it. An operation that is already running keeps the
values it started with.

The backup timeouts are also sent to the code PZ Tools runs inside the game. After an app
update, a game still running with the older version of that code needs a restart before
custom timeouts reach it.

## Resetting

**Reset advanced settings → Restore default settings** asks for confirmation, then:

1. moves the whole `config` folder to
   `%LOCALAPPDATA%\PzTools\config-backups\config-<date>-<time>-<id>` (date and time in UTC),
2. creates new files from the current templates,
3. restarts the app.

It does not check your edited files first, so it works when they are broken. It needs the
same idle moment as **Apply settings and restart**. The settings on the Settings page,
your saves and your backups are not changed. To bring an edit back, copy it from the
folder in `config-backups`.

## Which setting wins

A key you leave out uses its built-in default. A value you set is used, unless the
Settings page offers the same choice: then the Settings page wins.

| Advanced key | Overridden by |
| --- | --- |
| `backup-worker` `[capture] save_game_before_backup` | **Save game before backup** |
| `backup-worker` `[capture] game_save_countdown` | **In-game save countdown** |
| `backup-worker` `[naming] language` (not in the template) | **Language** |
| `maintenance-worker` `[maintenance] retain_latest_revisions` (not in the template) | **Automatic backups to keep** |
| `state-reactor` `[state] backup_on_death` (not in the template) | **Back up when the character dies** |

The command-line tools accept options that override these files again; see the
[command line](command-line.md).

## Settings worth knowing

The rest of the keys tune internals such as buffers, batch sizes and refresh intervals.
They are documented in the template comments; changing them rarely helps.

### app

| Key | Default | Range | What it does |
| --- | --- | --- | --- |
| `[logs] record_minimum_level` | `"Information"` | `Trace`, `Information`, `Warning`, `Error`, `Critical` | Lowest level stored for the Logs page. Entries below it are never stored, so a Logs page filter cannot bring them back. |
| `[logs] max_entries` | 100000 | 10000–500000 | Entries kept. Once full, the oldest are deleted, unread warnings and errors included. |
| `[profiler] general_limit_minutes` | 30 | 1–30 | A Standard recording nobody stops ends after this many minutes. |
| `[profiler] detailed_limit_minutes` | 10 | 1–30 | The same for a Detailed recording, whose file is about five times as large. |
| `[profiler] rolling_max_megabytes` | 256 | 64–2048 | Most disk the kept last minutes may use. A long Detailed window can reach it and then holds less. |
| `[hotkeys] sounds` | `true` | | A hotkey answers with Windows sounds. |
| `[hotkeys] game_notices` | `true` | | A hotkey answers with a note over your character's head. |
| `[runtime] success_card_seconds` | 5 | 1–60 | How long a finished operation's card stays. |
| `[runtime] failure_card_seconds` | 10 | 1–120 | How long the card of an operation that failed, finished only in part, was cancelled or was skipped stays. Its log stays on the Logs page. |

The `[logs]` section must be present. The file may contain only `[logs]`, `[runtime]`,
`[profiler]` and `[hotkeys]`.

### backup-worker

| Key | Default | Range | What it does |
| --- | --- | --- | --- |
| `[capture] always_include` | `["players.db", "vehicles.db", "thumb.png"]` | Paths relative to the save folder, no `..` | Read in every backup even when they look unchanged. `[]` turns this off. It cannot capture changes the game has not written to disk. |
| `[capture] full_scan_hash_comparison` | `true` | | When Windows change tracking is unavailable, compare file contents with the previous backup, so edits that keep a file's size and times are caught. `false` is faster but can miss such edits. |
| `[storage] checksum` | `"auto"` | `auto` (XxHash64), `none`, `xxhash64`, `sha256` | Per-file check for detecting damaged backup data. |
| `[storage] compression` | `"auto"` | `auto` (Brotli), `none`, `brotli` | Compression of stored data. |
| `[storage] compression_level` | 3 | 1–11 | How hard new data is compressed. Above 5 the size hardly shrinks while the time keeps growing. Data already stored is unchanged. |
| `[storage] content_deduplication` | `false` | | Store identical files from different backups once. Requires `checksum = "sha256"`. |
| `[storage] verify_staged_copies` | `true` | | Check that a file did not change while it was copied from the live save. Keep it on. |
| `[runtime] capture_attempts` | 5 | 1–20 | Tries to copy a file that keeps changing before the backup fails. |
| `[runtime] game_connection_timeout_seconds` | 30 | 5–120 | Wait to connect to the running game. On failure the backup uses the files on disk, with a warning. |
| `[runtime] game_queue_timeout_seconds` | 15 | 1–60 | Wait for the game to start saving. A save that has not started by then is cancelled. |
| `[runtime] game_completion_timeout_seconds` | 150 | 30–600, and at least `game_queue_timeout_seconds` + 20 | Wait for the save to finish. On timeout it is unknown whether the game saved, so the backup stops and does not retry. |
| `[telemetry] mode` | `"phase"` | `off`, `run`, `phase`, `raw` | Detail of the backup's diagnostic records. Use `raw` only briefly; it writes a record per file. |

`format_version = 1` must stay as it is.

### state-scheduler

| Key | Default | Range | What it does |
| --- | --- | --- | --- |
| `[scheduler] interval_seconds` | 3 | 1 or more | Time between checks of the game's state. |
| `[scheduler] cleanup_interval_seconds` | 60 | 10–86400 | How often interrupted work and backups of saves that no longer exist are looked for. Heavy cleanup waits while the game may be running. |
| `[extensions] reconcile_interval_ms` | 1000 | 250–1000 | How often the game extensions' settings are compared with the game. Lower reacts sooner and costs more disk and control work. |
| `[extensions] connect_timeout_seconds` | 20 | 5–60 | Time allowed to connect a game extension. Raise it on a slow PC. |

### maintenance-worker

| Key | Default | Range | What it does |
| --- | --- | --- | --- |
| `[maintenance] revision_batch_size` | 20 | 1–1000 | Once a save has this many deleted backups waiting, their space is reclaimed at the next cleanup. |
| `[maintenance] revision_compaction_max_delay_minutes` | 60 | 0–10080 | A smaller batch waits at most this long. 0 reclaims at the next cleanup. |
| `[maintenance] pack_reclamation_enabled` | `true` | | While the game is closed, rewrite data files that are mostly unused so the space comes back. |

The other maintenance keys are listed in [repository housekeeping](../design/repository-housekeeping.md#settings).

### archive-worker

| Key | Default | Range | What it does |
| --- | --- | --- | --- |
| `[archive] maximum_entries` | 1000000 | 1 or more | A ZIP with more files and folders than this is refused. |
| `[archive] maximum_single_file_bytes` | 68719476736 (64 GiB) | More than 0 | A ZIP holding a larger single file is refused. |
| `[archive] minimum_free_space_reserve_bytes` | 5368709120 (5 GiB) | 0 or more | Free disk space that must remain after an import… |
| `[archive] minimum_free_space_reserve_percent` | 10 | 0–100 | …or this share of the ZIP's unpacked size, whichever is larger. |

Raise these only for a ZIP you trust.

### Diagnostic records in every file

Every file except `app` has a `[telemetry]` section for its diagnostic records. These are not your
backups and not the Logs page.

| Key | Default | What it does |
| --- | --- | --- |
| `enabled` | `true` | `false` stops recording. The work itself still runs, but failures are harder to investigate. |
| `retain_runs` | 100 | Runs whose records are kept. 0 means no limit. |
| `max_database_mib` | 64 | Approximate size limit of the records. 0 means no limit. The database file may stay larger on disk. |
