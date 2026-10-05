# Command line

[Documentation index](../README.md)

The app does its work through 12 programs in the app folder. You can run some of them yourself, to script backups or to check a backup folder without the app. Everyday backups and restores are easier in the app.

## Before you start

- Run the programs where they are, in the app folder. Each one finds `game-bridge\` and the other programs beside itself, not in the current folder.
- Use an administrator terminal. The app runs them as administrator.
- A save is named `<mode>/<save name>`, as in `Sandbox/2026-10-02_02-31-22`. That is its folder under the saves folder.
- Every run gets a run number from `control.db` in `%LOCALAPPDATA%\PzTools`. `--control-db <path>` uses another file. `--run-index <n>` gives the number yourself. You need neither, except where a program below says `--run-index` is required.
- `Ctrl+C` stops `PzTools.Backup.Cli.exe`, the ZIP program, the profiler and the schedulers at the next safe point, with exit code 2. The other programs, the revive program among them, have no safe point and are ended at once; let them finish.

## The programs

| Program | For you to run | What it does |
| --- | --- | --- |
| `PzTools.Backup.Cli.exe` | Yes | Back up, restore, verify and clean up a backup folder. See [below](#pztoolsbackupcliexe). |
| `PzTools.Zomboid.Archive.Cli.exe` | Yes | Export a save or backup to a ZIP, inspect a ZIP, import a ZIP. See [below](#pztoolszomboidarchivecliexe). |
| `PzTools.Zomboid.Recovery.Cli.exe` | Yes, with care | Revive a character in a save that is not being played. See [below](#pztoolszomboidrecoverycliexe). |
| `PzTools.Profiler.Cli.exe` | Yes, `record` only | Record the running game's performance to a `.pzprof` file. See [below](#pztoolsprofilercliexe). |
| `PzTools.Backup.Runner.exe` | Rarely | Runs `PzTools.Backup.Cli.exe backup` with the same options, holding the backup folder's lock while it runs. Its own `--config` is the runner's settings file; give the backup settings file as `--worker-config`. The app and the scheduler use it. |
| `PzTools.Maintenance.Runner.exe` | No | Cleans up one save's backups after a backup. |
| `PzTools.Maintenance.Cli.exe` | No | The cleanup worker the maintenance runner, the state scheduler and the app start. |
| `PzTools.Backup.Scheduler.exe` | No | Runs automatic backups. The app keeps one running. |
| `PzTools.State.Scheduler.exe` | No | Watches saves and the game. The app keeps one running. |
| `PzTools.State.Runner.exe` | No | One check of the saves folder. |
| `PzTools.State.Collector.Cli.exe`, `PzTools.State.Reactor.Cli.exe` | No | The two halves of that check. |

Each program also accepts `--probe` alone, which exits with 0 and does nothing. The app uses it to see whether Windows lets the program start.

## With the app running

| What you run | Is it safe? |
| --- | --- |
| `backup`, `restore`, `verify`, `maintenance prune`, `maintenance gc`, the ZIP commands, revive | Yes. They lock the backup folder as the app does. If the app is using it, they exit with 75 and change nothing. A save the game has open makes `restore` and revive fail with 1, also without changing it. `inspect` only reads the ZIP and takes no lock. |
| `PzTools.Profiler.Cli.exe record` | Not while the app is recording. The game holds one recording, and starting one ends the one running. |
| `PzTools.Profiler.Cli.exe roll-start`, `roll-save`, `roll-stop` | No. They control the recording behind **Keep the last minutes**, which the app manages. |
| `PzTools.Backup.Scheduler.exe configure` on the app's `scheduler.db` | No. It changes the schedule behind the app: **Settings** then shows values that are not in effect, until you next change the backup settings there. |
| Either scheduler's run on the app's databases | Pointless. It exits with 75, as the app's copy holds them. |
| `PzTools.State.Collector.Cli.exe` or `PzTools.State.Reactor.Cli.exe` on the app's `state.db` | No. They wait their turn behind the app's own check (exit 75 while it runs), but what they record changes what the app believes about your saves. |

The app's **Logs** page shows a command-line restore or ZIP operation after the app's next start.

## PzTools.Backup.Cli.exe

```text
PzTools.Backup.Cli.exe backup --repository <backup folder> --source-id <mode/name>
    --source <mode/name>=<save folder> [--save-game] [--require-active-game]
    [--scheduled-utc <time>] [--game-version <text>] [--revision <n>] [settings options]
PzTools.Backup.Cli.exe restore --repository <backup folder> --source-id <mode/name>
    --revision <n> --target <save folder> [--telemetry-identity <folder>]
PzTools.Backup.Cli.exe verify --repository <backup folder>
PzTools.Backup.Cli.exe maintenance prune --repository <backup folder> --source-id <mode/name> --keep <n>
PzTools.Backup.Cli.exe maintenance gc --repository <backup folder>
PzTools.Backup.Cli.exe config validate [settings options]
PzTools.Backup.Cli.exe config show [settings options]
PzTools.Backup.Cli.exe scan <folder> <list.json>
PzTools.Backup.Cli.exe diff <folder> <list.json>
PzTools.Backup.Cli.exe help
```

`backup` and `restore` also take `--run-index` and `--control-db`. `restore` also takes `--config <file>` for its diagnostic settings.

| Command | What it does |
| --- | --- |
| `backup` | Takes one backup of one save. Creates the backup folder `--repository` if it doesn't exist. Prints the result as JSON. |
| `restore` | Replaces the save folder `--target` with backup number `--revision`. See [restore safety](#restore-safety). |
| `verify` | Reads every stored pack and checks it. Prints a JSON report. |
| `maintenance prune` | Deletes all but the newest `--keep` automatic backups of one save (`--keep` at least 1). Other backups stay. This can't be undone. |
| `maintenance gc` | Removes stored data that no backup uses any more. |
| `config validate` | Checks the backup settings and says how many saves they name. |
| `config show` | Prints the backup settings in effect, as TOML. |
| `scan`, `diff` | Diagnostics that don't touch a backup folder: `scan` writes a folder's file list to JSON, `diff` compares the folder with that list and prints what changed. |

`restore`, `verify` and `maintenance` refuse a folder that isn't a backup folder, so a mistyped path doesn't create one. `backup` creates one.

### Options of `backup`

| Option | Effect |
| --- | --- |
| `--repository <folder>` | The backup folder. Required. |
| `--source-id <mode/name>` | Which save to back up. It must match a `--source`. |
| `--source <mode/name>=<folder>` | The save's folder. Repeat it for more saves. The app's settings file names no saves, so you need this. |
| `--save-game` | Asks the game to save first, if it is running with this save loaded and **Save game before backup** is on. |
| `--require-active-game` | Skips the backup (exit 0) if the game stops playing this save before the files are read. |
| `--scheduled-utc <time>` | Prepares early, but saves and reads no files before this time. Written exactly like `2026-10-05T12:00:00.0000000+00:00`: seven decimal places and an offset. |
| `--game-version <text>` | Records this game version with the backup, up to 80 characters. |
| `--revision <n>` | For testing: the number to give the new backup. |

The app also passes options of its own (`--runtime-ticket`, `--runtime-authority`, `--runtime-generation`). They are not for use by hand.

### Settings options

`backup`, `config validate` and `config show` read the backup settings from `%LOCALAPPDATA%\PzTools\config\backup-worker\default.toml`, which the app creates (see [advanced settings](advanced-settings.md)), then **Save game before backup** and the language from `settings.toml`. These options override them for one run:

| Option | Values |
| --- | --- |
| `--repository <folder>` | The backup folder. Required for `backup`; for `config` the default is the current folder. |
| `--config <file>` | Another backup settings file, read instead of the one above. |
| `--source <mode/name>=<folder>` | A save to back up. Replaces the saves named in the file. |
| `--always-include <path>` | A file, relative to the save, to check in every backup even if its timestamps look unchanged. Repeatable. Replaces the list in the file. |
| `--full-scan-hash-comparison` | `true` or `false` |
| `--save-game-before-backup` | `true` or `false` |
| `--verify-staged-copies` | `true` or `false` |
| `--content-deduplication` | `true` or `false` |
| `--checksum` | `auto`, `none`, `xxhash64`, `sha256` |
| `--compression` | `auto`, `none`, `brotli` |
| `--name-language` | A language code the app supports, for backup names |
| `--telemetry-enabled` | `true` or `false` |
| `--telemetry-mode` | `off`, `run`, `phase`, `raw` |
| `--telemetry-batch-size`, `--telemetry-flush-ms`, `--telemetry-retain-runs`, `--telemetry-max-database-mib` | A whole number |

### Example

In Command Prompt:

```text
cd "C:\Games\PzTools-v0.2.3"
.\PzTools.Backup.Cli.exe backup --repository "%USERPROFILE%\Zomboid\Backups" ^
    --source-id Sandbox/MySave --source "Sandbox/MySave=%USERPROFILE%\Zomboid\Saves\Sandbox\MySave"
```

## PzTools.Zomboid.Archive.Cli.exe

```text
PzTools.Zomboid.Archive.Cli.exe inspect --archive <file.zip>
PzTools.Zomboid.Archive.Cli.exe export --repository <backup folder> --source-id <number>
    --revision <n> --output <file.zip>
PzTools.Zomboid.Archive.Cli.exe export-live --source <save folder> --save-id <mode/name> --output <file.zip>
PzTools.Zomboid.Archive.Cli.exe import --archive <file.zip> --saves-root <saves folder>
PzTools.Zomboid.Archive.Cli.exe help
```

All four also take `--run-index`, `--control-db`, `--config <file>` (an archive settings file read last, over the others) and `--telemetry-identity <folder>`.

| Command | What it does |
| --- | --- |
| `inspect` | Checks a ZIP and prints its save name, mode, size, character and survival time. |
| `export` | Writes one backup to a ZIP. `--source-id` here is the save's number in the backup folder, not its name. |
| `export-live` | Writes the save as it is now to a ZIP. It fails if the game writes the save meanwhile. |
| `import` | Unpacks a ZIP made by PZ Tools into `<saves folder>\<mode>\<name>`. See [importing ZIP archives](files-and-folders.md#importing-zip-archives) for the limits. |

## PzTools.Zomboid.Recovery.Cli.exe

```text
PzTools.Zomboid.Recovery.Cli.exe --repository <backup folder> --saves-root <saves folder>
    --save-id <mode/name> --run-index <n> --telemetry-identity <folder>
    [--player-id <n>] [--remains none]
```

Revives the character in a save, as [revive a character](../guides/revive-a-character.md) does in the app. The game must not have the save open. It keeps no copy of the files it changes, so take a backup first.

| Option | Effect |
| --- | --- |
| `--repository` | The backup folder. It is locked while the revive runs. |
| `--run-index`, `--telemetry-identity` | Required here: a number of your choice and a folder for the diagnostic records. |
| `--player-id <n>` | Which character, when the save has more than one (split screen). |
| `--remains none` | Revive without the dead character's belongings. Without it, a dead character with an empty inventory gets the belongings back if exactly one body or zombie matches. No match, or several, is refused; then use `--remains none`. |

## PzTools.Profiler.Cli.exe

```text
PzTools.Profiler.Cli.exe record --output <file.pzprof> --stop-file <file> --mode general|detailed
    --run-index <n> --telemetry-identity <folder>
    [--max-seconds <5..1800>] [--process-id <pid>] [--keep-raw]
```

Records until the stop file appears, `--max-seconds` (default 600) runs out, or the game exits, then converts the recording to `--output`. Without `--process-id` it looks for the one running game and fails if there are none or several. `--keep-raw` keeps the raw `.pzprof.jfr` recording beside the output; it holds full file paths, so don't share it. See [find a laggy mod](../guides/find-a-laggy-mod.md).

`roll-start`, `roll-save` and `roll-stop`, and the options `--bridge` and `--owner`, are for the app.

## Results and exit codes

Each run prints one JSON line to standard output (the profiler prints progress lines before it): `version`, `component`, `runIndex`, `outcome`, `startedUtc`, `completedUtc`, and `result` or `error` (`code` and `message`). `verify`, `maintenance prune`, `maintenance gc`, `config`, `scan` and `diff` print their own output instead, and `PzTools.Backup.Cli.exe` writes errors from those to standard error as JSON with `success`, `code` and `message`. The schedulers print one JSON line per job they start.

| Code | Meaning |
| ---: | --- |
| 0 | Done. For `backup`, also when nothing had changed or the game stopped with `--require-active-game`. |
| 1 | Failed. |
| 2 | Stopped with `Ctrl+C`, at a safe point. |
| 3 | `verify` found missing or damaged data, or cleanup finished but could not delete some files. |
| 4 | `maintenance gc` finished, but some files could not be deleted. |
| 64 | Unknown command or option, or a bad value. See the exceptions below. |
| 75 | Busy: another program is using that save or backup folder. Nothing was changed. Try again later. |

Some return 1 instead of 64 for a bad option or value: the revive program and `PzTools.State.Runner.exe`. The revive program ignores an option it doesn't know.

A backup's `result` can carry `warnings`, such as diagnostic records that could not be written or leftover files found in the backup folder. They don't change the exit code.

## Restore safety

A restore builds the backup in a hidden folder beside the save, `.<save>.pztools-staging-<id>`, checking each stored file as it reads it and flushing every file to disk. Only then does it move the old save aside to `.<save>.pztools-rollback-<id>`, rename the new copy into place and delete the old one. Until that rename the save is untouched, and a failed restore removes its own folder.

A restore refuses a save the game has open. It also finishes or undoes an earlier interrupted restore of the same save first. A record of each restore in progress, `.<save>.pztools-restore.json`, sits beside the save so the app can finish or undo it after a crash. If an old save can't be deleted yet, the restore still counts as done and the app removes it later.
