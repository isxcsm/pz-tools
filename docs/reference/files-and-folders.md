# Files and folders

[Documentation index](../README.md)

## Where PZ Tools keeps files

| Place | What is there |
| --- | --- |
| The app folder, wherever you extracted the ZIP | The program. See [the app folder](#the-app-folder). |
| `%LOCALAPPDATA%\PzTools` | Your settings, the app's databases, logs, error reports and performance recordings. See [the data folder](#the-data-folder). |
| The backup folder chosen in **Settings** (default `%USERPROFILE%\Zomboid\Backups`) | Your backups. See [the backup folder](#the-backup-folder). |
| The saves folder chosen in **Settings** (default `%USERPROFILE%\Zomboid\Saves`) | The game's saves. PZ Tools changes them only when you restore, revive, import or delete. See [saves](#what-pz-tools-changes-in-a-save). |
| The game folder | `ProjectZomboid64.json`, and only when you set **Game memory**. See [the game folder](#what-pz-tools-changes-in-the-game-folder). |
| `%USERPROFILE%\.pztools-bridge\bootstrap.lock` | An empty lock file that lets one program at a time connect to the game. |
| `%TEMP%\PzTools` or `%ProgramData%\PzTools` | Used only when a path has letters outside ASCII. See [non-ASCII paths](#folders-used-only-for-non-ascii-paths). |

PZ Tools adds nothing to the registry, the Start menu or Windows startup.

## The app folder

The release is `PzTools-v<version>-win-x64.zip`, with a `.sha256` file beside it on the release page. The ZIP holds one folder, `PzTools-v<version>`, so a new release extracts beside the old one.

| Item | What it is |
| --- | --- |
| `PzTools.App.exe` | The app. It asks for administrator rights when it starts. |
| `PzTools.*.exe` (12 more) | The background programs the app starts for backups, restores, checks and recordings. They are listed in [command line](command-line.md). |
| `*.dll`, `*.winmd`, `*.pri`, `Microsoft.UI.Xaml\`, the language folders (`af-ZA` to `zh-TW`) | .NET libraries and the Windows App SDK (WinUI), which is included. |
| `Assets\` | Icons and images. |
| `defaults\<component>\default.toml` | The packaged default settings for each part of the app. Don't edit them; a new release replaces them. Your own changes go in the data folder (see [advanced settings](advanced-settings.md)). |
| `game-bridge\` | What the game loads to save on request, record performance and run extensions: two jars and a DLL, `runtime\` (a small Java runtime used to connect to the game), and `extensions\` (the in-game extensions and their packaged settings). |
| `pztools-files.txt` | Every file above with its size and SHA-256. The app checks its folder against it. |
| `START-HERE.txt` | Install steps. |
| `LICENSE`, `THIRD_PARTY_NOTICES.md`, `licenses\` | Licenses. |

### Installing

1. Install the .NET 10 Runtime for Windows x64 if you don't have it.
2. Extract the whole ZIP into a folder of your own, such as `Documents`. Keep every file and subfolder together.
3. Run `PzTools.App.exe` and approve the administrator prompt.

Keep your saves and backup folders outside the app folder. The [getting started](../guides/getting-started.md) guide walks through the first run.

### Updating

1. Close PZ Tools, including from the tray.
2. Extract the new ZIP. It makes a new folder named for its version.
3. Run `PzTools.App.exe` from the new folder. Delete the old folder once the new one works.

Your settings, logs and backups are not in the app folder, so they carry over.

Don't extract a new release over the folder of a running app. Files in use keep the old version and the rest take the new one, and the app then runs parts of two releases.

### The install check

About 8 seconds after it starts, the app compares its folder with `pztools-files.txt`.

| Situation | What the app does |
| --- | --- |
| First start of a release in this folder | Reads and hashes every listed file once, in the background. |
| Later starts | Checks only that each listed file exists and has the right size. |
| A file is missing or different | Shows the card **PZ Tools files are not intact** with the button **Open download page**. The log entry's details name the files (the first 10 of each kind). Extract the ZIP again into an empty folder. |
| A file is held open by another program, such as a virus scanner | Not counted as broken. The whole folder is hashed again at the next start. |
| A file the list doesn't name, such as one left from an older release | Ignored. Nothing the app runs loads a file just because it is in the folder. |
| A development build (no `pztools-files.txt`) | Not checked. |

The app remembers the folder it last found whole in `install-check.json` in the data folder.

If a background program is missing when the app starts, it shows **Some PZ Tools files are missing. Extract the downloaded package again.** and closes.

## The data folder

`%LOCALAPPDATA%\PzTools` belongs to you and the app. It is shared by every copy of the app you run, so it survives updates. Only one copy of the app runs at a time; starting a second one brings the first window forward.

| Item | What it is |
| --- | --- |
| `settings.toml` | The choices you make in **Settings**. |
| `config\<component>\default.toml` | Editable settings for each part of the app. See [advanced settings](advanced-settings.md). |
| `config-backups\` | Copies of `config\` made by **Restore default settings**, one folder each. |
| `extensions\settings.json` | Which game extensions are on, and their options. `settings.json.lock` beside it is used while it is written. |
| `extensions\vehicle-drivetrain.toml` | Optional. Your own values for the vehicle extension's tuning, over the packaged ones in the app folder. You create it; the app never does. |
| `logs.db` | What the **Logs** page shows. Its size is capped by the log settings. |
| `control.db` | Hands out the run number every job gets. |
| `state.db` | What the app knows about your saves and the running game. |
| `scheduler.db` | The automatic backup schedule and its queue. |
| `.pztools\scheduler.db\` and `.pztools\state.db\` | Diagnostic records of the schedulers and save checks, one `telemetry.db` per part. See [telemetry](../design/telemetry.md). |
| `operations\<component>\` | Diagnostic records of one restore, ZIP import or export, revive or recording each. A folder is removed once its entries are in `logs.db`. |
| `profiles\` | Performance recordings, one `.pzprof` file each. |
| `profiles-index.json` | A summary of each recording, so the list opens without reading every file. |
| `crash\` | Error reports (`crash-<time>.txt`) written when the app closes on an unexpected error. The newest 20 are kept. |
| `game-memory.json` | The **Game memory** you chose, the game's own setting from before, and where the game's file is. |
| `game-memory-original.json` | A copy of the game's `ProjectZomboid64.json` as it was before PZ Tools first changed it. |
| `save-versions.json` | The last game version seen with each save. |
| `update.json` | When the app last checked GitHub for a new release, and what it found. |
| `install-check.json` | The app folder last found whole, and the hash of its file list. |

If the data folder can't be found when the app crashes, the error report goes to `%TEMP%\PzTools\crash` instead.

## The backup folder

| Item | What it is |
| --- | --- |
| `repository.db` | The list of every backup and the files in it. |
| `packs\` | The backed-up file contents, compressed and shared between backups. |
| `staging\` | Packs being written. |
| `.writer.lock` | Lets one program at a time change the folder. |
| `telemetry.db` and `.pztools\<component>\` | Diagnostic records of backups and cleanup. |

[Repository format](../design/repository-format.md) describes each part. Don't edit or delete files inside the folder; delete backups from the app instead.

## What PZ Tools changes in a save

| Action | What changes |
| --- | --- |
| Backup | Nothing in the save. With **Save game before backup** on, PZ Tools asks the game to save, and the game writes the save as it always does. |
| Any time the game runs with PZ Tools connected | The character carries three entries in its mod data (`pztools.recovery.id`, `.primary`, `.secondary`), which the game stores in `players.db`. They let a later revive find the character's body and the items in its hands. The game ignores them otherwise. |
| Restore | The save folder is replaced with the backup. |
| Revive a character | `players.db`, and the world file that holds the body, if you bring its belongings back (a map chunk under `map\` or `reanimated.bin`). |
| Import a ZIP | A new save folder appears under `<saves folder>\<mode>\`. If the name is taken, `(1)`, `(2)` and so on is appended, as in `MySave(1)`. |
| Delete a save | The save folder is deleted permanently, not moved to the Recycle Bin, and its backups are deleted. |

While these run, hidden folders appear beside the save, in the mode folder (such as `Saves\Sandbox`). They go away when the operation finishes. If the PC stops partway, the app sorts them out at its next start.

| Name | Made by |
| --- | --- |
| `.<save>.pztools-staging-<id>` | Restore and revive: the new copy being built. |
| `.<save>.pztools-rollback-<id>` | Restore: the old save, kept until the new one is in place. |
| `.<save>.pztools-restore.json` | Restore: the record that lets an interrupted restore be finished or undone. |
| `.<save>.pztools-file-edit` | Revive: the changed files, while they are put in place. |
| `.pztools-import-<id>` (in the saves folder itself) | Import: the save being unpacked. |

A restore or revive refuses a save the game has open.

## What PZ Tools changes in the game folder

Only `ProjectZomboid64.json`, and only when you pick a size in **Settings** > **Game memory**. PZ Tools changes the two memory options in the file's `vmArgs` list (`-Xmx`, and `-Xms` set to the same value). Everything else in the file stays as written. A game update or a Steam file check puts the file back; the app then offers to apply your choice again. Choosing **Game default** writes the game's own values back. See [more game memory](../guides/more-game-memory.md).

PZ Tools copies nothing into the game folder and installs no mod. The bridge and extensions are loaded into the running game from the app folder.

## Folders used only for non-ASCII paths

The game can't load files from a path with letters outside ASCII, such as a folder named in Korean. In that case only:

| Folder | When | What |
| --- | --- | --- |
| `%TEMP%\PzTools\attach\` | The app folder's path is not ASCII | Copies of two bridge files the game loads. |
| `%ProgramData%\PzTools\attach\` | The app folder's path and `%TEMP%` are both not ASCII | The same copies, in a folder only your account can change. |
| `%ProgramData%\PzTools\jfr\` | `%TEMP%` is not ASCII | The game's working files while it records performance. |

## Importing ZIP archives

Only ZIPs exported by PZ Tools can be imported. Each import is checked against these limits, set in the `[archive]` section of `config\archive-worker\default.toml` in the data folder:

| Setting | Default | Limit |
| --- | --- | --- |
| `maximum_entries` | 1,000,000 | Files and folders in the archive, in total |
| `maximum_single_file_bytes` | 68719476736 (64 GiB) | Size of any one file after unpacking |
| `minimum_free_space_reserve_bytes` | 5368709120 (5 GiB) | Free space that must remain on the saves drive after the import |
| `minimum_free_space_reserve_percent` | 10 | Free space that must remain, as a percentage of the archive's unpacked size |

The space kept free is the larger of the last two: 5 GiB, or 10% of the save's unpacked size, not 10% of the drive. There is no limit on the total size, and a high compression ratio alone does not get an archive refused.

The import also refuses paths that leave the save folder, links, duplicate names and files outside the save. These checks, the limits above and the free space are checked before any file is unpacked. Each file's length and CRC-32 are checked as it is unpacked. A refused or failed import deletes what it had unpacked.

The `[preview]` section limits what the import preview reads: `players_database_mib` (64, range 1 to 1024) for the character shown, and `thumbnail_mib` (16, range 1 to 64) for the picture. Above these the preview leaves the character or picture out; the import itself still works.

## Uninstalling

1. If you set **Game memory**, choose **Game default** first, so the game gets its own setting back. (If you skip this, a Steam file check also restores it, and `game-memory-original.json` holds the original file.)
2. Close PZ Tools, including from the tray.
3. Delete the app folder.
4. Delete `%LOCALAPPDATA%\PzTools` to remove settings, logs and recordings.
5. Delete the backup folder if you don't want the backups. Your saves are not touched.
6. If they exist, delete `%USERPROFILE%\.pztools-bridge`, `%TEMP%\PzTools` and `%ProgramData%\PzTools`.
