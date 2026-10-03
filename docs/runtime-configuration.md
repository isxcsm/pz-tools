# Advanced component settings

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

Each background program in PZ Tools (each [component](glossary.md#component)) has its
own settings file with tuning values: timeouts, buffer sizes, batch sizes and how often
things are checked or refreshed. The defaults suit normal use. This page is for someone
who wants to adjust a component, for example for a slow disk, or who is investigating
a problem. Everyday preferences, where the files live and which setting wins are on the
[configuration](configuration.md) page.

## What each file controls

The files are under `%LOCALAPPDATA%/PzTools/config/`. Each one starts as a copy of the
template listed here, which explains every key in English: its unit, its allowed range
and what changing it does.

| Editable file | What it tunes |
| --- | --- |
| [`app/default.toml`](../config/defaults/app/default.toml) | Stored logs, plus: how often lists and progress are refreshed; telemetry catch-up, read grace and stale threshold; how long operation cards stay; thumbnail memory budget and parallel reads; retries and timeouts of an explicit refresh; scheduler restart and back-off; shutdown grace; settings and log-filter debounce; progress frequency of running operations (key `export_progress_interval_ms`, which keeps an older name but applies to every operation); `[profiler]` recording limits (`general_limit_minutes`, `detailed_limit_minutes`) and the most the last minutes may hold on disk (`rolling_max_megabytes`); `[hotkeys]` sounds and in-game notes (`sounds`, `game_notices`; see [hotkeys](profiler.md#hotkeys)) |
| [`backup-worker/default.toml`](../config/defaults/backup-worker/default.toml) | Attempts and back-off for files that keep changing, copy and hash buffer, the small-file staging pool, capture reader and queue limits, full-scan hash batch and reader limits, progress frequency, scan and USN batches, backup heartbeat, and the timeouts for connecting to the game, queueing a save and waiting for it to finish |
| [`backup-scheduler/default.toml`](../config/defaults/backup-scheduler/default.toml) | How often it checks whether a backup is due (not your backup interval), and how early it starts preparing a due backup |
| [`state-scheduler/default.toml`](../config/defaults/state-scheduler/default.toml) | State checks, wake-up polling, the delay between the two independent confirmation checks, how often interrupted work and orphan backups are cleaned up, and the extension-control connection |
| [`maintenance-worker/default.toml`](../config/defaults/maintenance-worker/default.toml) | Batch size for reclaiming deleted revisions, retry delay when another job holds the writer lock, run-history trimming, VACUUM and pack rewriting thresholds. It does not set how many backups are kept. |
| [`archive-worker/default.toml`](../config/defaults/archive-worker/default.toml) | ZIP safeguards, memory budgets for character and thumbnail previews, progress and heartbeat frequency |
| [`restore-worker/default.toml`](../config/defaults/restore-worker/default.toml), [`character-recovery/default.toml`](../config/defaults/character-recovery/default.toml), [`profiler/default.toml`](../config/defaults/profiler/default.toml) | Diagnostic retention, progress and heartbeat frequency |

Every file also has a `[telemetry]` section; see [telemetry](telemetry.md). A limit of
zero there keeps its documented meaning: unlimited.

## Changing a setting

1. Edit the file. The template's comments give the allowed range.
2. Use **Apply settings and restart**. This is the way to reload settings consistently.
3. Before stopping anything, the app checks every installed component's section names,
   key names, value types and ranges. A value outside its range fails this check.

Editing a file never changes an operation that is already running.

A key you leave out uses the built-in default. A value you set explicitly is never
replaced by a built-in default. Choices made in the app and options given on the
command line still take priority over these files.

Existing files are never rewritten, not even at startup after an update. New
installations and **Restore default settings** use the current templates. An existing
installation uses the built-in default for any key it does not contain, until you add
that key yourself.

## Limits

**Out-of-range values are rejected, not worked around.** An invalid value fails
validation. It never turns off a consistency check or turns a bounded wait into an
endless one. If the app's own file is invalid, the app still opens its settings repair
screen, but it does not start workers with a rejected configuration.

**Save timeouts are not all the same.** The game-save settings in the backup worker
have separate timeouts for waiting in the game's queue and for waiting for the save to
finish. Only a save that is still queued can be cancelled safely. A save the game has
already started is not interrupted. When it is unknown whether a save finished, the
backup does not capture files and does not retry automatically. See
[when the game is not saved](game-bridge.md#admission-and-failures).

**New timeouts may need a game restart.** The configured deadlines are sent to the
[game bridge](glossary.md#game-bridge) in the game. A compatible [payload](glossary.md#payload)
update is picked up at an idle moment; an incompatible [bootstrap](glossary.md#bootstrap)
still loaded in the game needs a game restart. See [component updates](module-reload.md).

### Deliberately not editable

Some values look like settings but are not offered, because changing them would break
data, safety or correctness:

- **Data contracts.** Binary formats, schema versions, field sizes and offsets, OS and
  API constants, and enum and status codes.
- **Safety boundaries.** Authentication sizes, allowed commands, hard limits of parsers
  and manifests, path validation, lock ordering, database integrity pragmas and the
  order of atomic writes. They are not switches for bypassing validation.
- **Implementation details.** Low-level OS and SQLite transport buffers, socket
  handshake guards, private bounded diagnostic buffers and internal synchronization
  checks. The workload and copy budgets and the user-facing timeouts above are the
  tuning interface, not every allocation or lock wait.
- **UI design.** Animation geometry and durations, responsive breakpoints and layout
  dimensions. Data refresh and I/O concurrency are configurable.
- **Correctness rules.** The game-format targets of character recovery, and the rule
  that two independent observations are needed to confirm a change. Recovery does not
  erase negative traits.
- **Test inputs.** Benchmark data sizes, seeds and synthetic test timeouts.

## How it works inside

### Reading settings

Tuning values are read once, where a process starts, and handed to the code that uses
them. Libraries do not read TOML again during a scan or a copy. Built-in defaults exist
for keys that are left out and for code that calls a library directly.

The worker option readers in `ComponentOptions` are shared by the pre-restart check and
by worker startup, so both apply the same rules. App and backup options keep their own
schemas. No runtime code rewrites existing TOML files.

### Character summaries in the backup list

The backup list shows a summary of the character in each backup. For older backups
that lack one, the app fills it in the background:

- `app/runtime.character_metadata_batch_size` limits how many attempts are made per
  refresh, failed reads included.
- `character_metadata_retry_seconds` sets how long to wait before trying again.

New backups take the summary from their captured `players.db`. The stored summary
includes survival time and an explicit "complete" flag, so a missing survival time is
not mistaken for work still pending. The collector also picks up collection that was
interrupted.

The collector reads packs without holding the [writer lock](glossary.md#writer-lock),
keeps reads it has finished even when a writer gets in the way, and moves on past
failures. It stores the last read error. A failed read is shown as unavailable with a
retry notice, not as a progress indicator that never ends; a successful retry clears
the error. The code that prepares data for display never changes the repository and
never extracts files from a revision.

Live character snapshots are cached per file version by the background state
projector, not read from UI callbacks. Revision thumbnails are loaded for the rows
actually shown in the list; recycled rows and switching saves cancel their pending
reads. Bitmaps are created on the UI thread; pack and database reads run in the
background.

### Results from other processes

Every process boundary uses `ProcessResultValidator`: the required envelope fields,
the component identity, the [run index](glossary.md#run-index) and the exit status
must agree. Missing output never counts as success. When the app sees a protocol
failure, it keeps the process's stderr in the durable log inbox, separately from the
machine-readable error code. Child processes all use one Job Object implementation and
one teardown path. The result format is described under
[results and exit codes](cli.md#results-and-exit-codes).

### Cleaning up operation telemetry

The [telemetry](glossary.md#telemetry) of archive, restore and character-recovery runs
is temporary. It is removed once the worker has stopped and every available event has
been imported into `logs.db`. A session activity lock prevents removal too early,
including while old events are being replayed.

Cleanup removes only known telemetry files and empty directories under the operations
folder PZ Tools owns. Unknown files and reparse points are left alone. The central log
settings go on controlling how long the imported diagnostics are kept. This cleanup
runs continuously; it is not a one-off migration and does not rewrite TOML.
