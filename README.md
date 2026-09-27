# PZ Tools

Incremental backups and character recovery for Project Zomboid on Windows.

Create backups, browse save history, and heal or revive characters in supported saves. PZ Tools is unofficial and is not affiliated with The Indie Stone.

<a id="features"></a>
## Features

- **Automatic and manual backups** with thumbnails, character details and editable names.
- **Incremental storage** with compression, NTFS change tracking and file-content comparisons when change tracking is unavailable.
- **Automatic backup timing** that follows the active save and can pause the countdown while the game is paused or your character is asleep.
- **Save before backup**, with an optional in-game countdown and completion notice.
- **ZIP import/export** and offline character healing, revival and inventory recovery.
- **Optional vehicle controls** for acceleration, shifting, reversing and keyboard steering.

Includes 18 interface languages, themes, tray mode, progress cards and filtered logs. Documentation is English-only.

<a id="getting-started"></a>
## Get started

Requires **Windows x64** and the **[.NET 10 runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)**. The app requests administrator permission for NTFS change tracking.

1. Get a runnable package from [Releases](https://github.com/isxcsm/pz-tools/releases), or build from source below. Extract the whole package and run `PzTools.App.exe`; GitHub's source ZIP is not a runnable app.
2. Open Settings, choose your language and check the save and backup folders. Keep those folders separate.
3. Create a manual backup and confirm it completes. Automatic backups default to **every 5 minutes**, keeping **20 automatic backups**.

To update, close the app and extract the new package into a fresh folder. Do not mix builds. Your settings live under `%LOCALAPPDATA%\PzTools`; saves and backups stay in their configured folders. See [settings and paths](docs/configuration.md).

<a id="backups-and-retention"></a>
## Backup history

The automatic backup limit does not remove manual backups. Manual backups can still be deleted directly or by cleanup after the original save folder disappears. **Deleting a save through the app also deletes its backups.** Export anything you want to keep before removing or moving a save. See [cleanup policy](docs/repository-housekeeping.md).

Automatic timing follows the active save. Pause-aware timing is on by default, preserving the remaining interval while paused or asleep. Restarting the app starts a fresh interval; it does not immediately run an overdue periodic backup.

<a id="game-saving"></a>
## Save before backup

The optional game bridge asks the game to save before reading its files. No Workshop mod or game installation edits are needed. It uses a runtime hook to run the game's normal save operation, which can briefly pause gameplay. The integration targets the inspected Build 42 / Java 25 single-player game.

Game saving and in-game notices have separate switches. **Game-save completion is not backup completion**: file copying and compression happen afterward. Turning saving off backs up only data already written to disk. Game-state monitoring and vehicle controls can remain active. See [game integration and compatibility](docs/save-bridge.md).

<a id="restore-and-archives"></a>
## Restore and ZIP files

Stop playing the selected save before restoring. **Restore replaces current files and loses progress made after the chosen backup.** If interrupted, reopen PZ Tools and check its status before loading the save.

Export a current save or backup to ZIP for an independent copy, or import one into the save list. Keep important exports on another drive: a backup beside the original does not protect against drive failure.

<a id="character-recovery"></a>
## Character recovery

Recovery works on the current save while it is not being played. It can heal or revive a supported character while preserving positive and negative traits, skills and progress. When death emptied the inventory, it can recover belongings from an identifiable zombie or corpse; missing items are not generated.

**Create a backup first.** Recovery does not make an extra copy automatically. See [supported formats and recovery limits](docs/character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-safeguards"></a>
<a id="compatibility-and-limits"></a>
## Compatibility and limits

PZ Tools is pre-release software. Keep an independent copy of important saves. File verification helps detect changes during capture, but it is not an atomic snapshot of the entire world.

If a backup folder uses an unsupported storage format, PZ Tools leaves it unchanged and refuses to open it. Choose a new empty backup folder and retain the old one if needed; do not delete the game save or just `repository.db`. See [storage compatibility](docs/repository-format.md) and [game-extension compatibility](docs/game-extensions.md).

<a id="troubleshooting"></a>
## Troubleshooting

Check Logs before retrying a failed operation. If automatic backups are not running, check that they are enabled, that a save is being played, and whether the game is paused or the character is asleep. Closing to the tray leaves the app running.

For an [issue report](https://github.com/isxcsm/pz-tools/issues), include the app and game versions, reproduction steps and relevant logs. Remove private paths and personal data.

<a id="building"></a>
## Build from source

Use Windows, the .NET SDK selected by `global.json`, PowerShell 7, a Java 25 JDK and Visual Studio C++/WinUI build tools:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Publish to a new or empty folder and distribute the whole output. See [development and validation](docs/development.md) for prerequisites and integration tests.

<a id="technical-documentation"></a>
## Documentation

The [documentation index](docs/README.md) covers configuration, storage, game integration and development. Dated test results and implementation notes are listed separately from current instructions. [Third-party notices](THIRD_PARTY_NOTICES.md).
