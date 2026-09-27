# PZ Tools

**Incremental backups and recovery tools for Project Zomboid.**

Keep restore points, browse your save history and recover a supported character from one Windows app. Unofficial; not affiliated with The Indie Stone.

<a id="features"></a>
## Features

- **Automatic and manual backups** with thumbnails, character details and editable names.
- **Incremental storage** with compression, NTFS change tracking and content-hash fallback.
- **Game-aware timing** that follows the active save and can pause the countdown while you pause or sleep.
- **Save before backup**, with an optional in-game countdown and completion notice.
- **ZIP import/export** and offline character healing, revival and inventory recovery.
- **Optional vehicle controls** for acceleration/transmission, smooth reverse and keyboard steering.

Includes 18 interface languages, themes, tray mode, progress cards and filtered logs. Documentation is English-only.

<a id="getting-started"></a>
## Get started

Requires **Windows x64** and the **[.NET 10 runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)**. The app requests administrator permission for NTFS change tracking.

1. Get a runnable package from [Releases](https://github.com/isxcsm/pz-tools/releases), or build from source below. Extract the whole package and run `PzTools.App.exe`; GitHub's source ZIP is not a runnable app.
2. Open Settings, choose your language and check the save and backup folders. Keep those folders separate.
3. Create a manual backup and confirm it completes. Automatic backups default to **every 5 minutes**, keeping **20 automatic restore points**.

To update, close the app and extract the new package into a fresh folder. Do not mix builds. Your settings live under `%LOCALAPPDATA%\PzTools`; saves and backups stay in their configured folders. See [settings and paths](docs/configuration.md).

<a id="backups-and-retention"></a>
## Backup history

Manual backups are not removed by the automatic retention limit. They can still be removed by explicit deletion or orphan cleanup after the original save disappears. **Deleting a save through the app also deletes its backups.** Export anything you want to keep before removing or moving a save. See [cleanup policy](docs/repository-housekeeping.md).

Automatic timing follows the active save. Pause-aware timing is on by default, preserving the remaining interval while paused or asleep. Restarting the app starts a fresh interval; it does not immediately run an overdue periodic backup.

<a id="game-saving"></a>
## Save before backup

The optional JVM bridge asks the game to save before reading its files. No Workshop mod or game installation edits are needed. It uses runtime hooks and the original synchronous save call, so a brief gameplay pause is still possible. The integration targets the inspected Build 42 / Java 25 single-player game.

Game saving and in-game notices have separate switches. **Game-save completion is not backup completion**: capture and compression follow. Turning saving off backs up only on-disk data. Independent game-state observation and vehicle controls can remain active. See [game integration and compatibility](docs/save-bridge.md).

<a id="restore-and-archives"></a>
## Restore and ZIP files

Stop playing the selected save before restoring. **Restore replaces current files and loses progress made after the chosen backup.** If interrupted, reopen PZ Tools and check its status before loading the save.

Export a current save or backup to ZIP for an independent copy, or import one into the save list. Keep important exports on another drive: a backup beside the original does not protect against drive failure.

<a id="character-recovery"></a>
## Character recovery

Recovery works on the current, inactive save. It can heal or revive a supported character while preserving positive and negative traits, skills and progress. When death emptied the inventory, it can recover belongings from identifiable remains; missing items are not generated.

**Create a backup first.** Recovery does not make an extra copy automatically. See [supported formats and recovery limits](docs/character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Compatibility and safeguards

PZ Tools is pre-release software. Keep an independent copy of important saves. File verification helps detect changes during capture, but it is not an atomic snapshot of the entire world.

An incompatible backup repository is rejected, not silently converted or erased. Choose a new empty backup folder and retain the old one if needed; do not delete the game save or just the repository database. [Storage details](docs/repository-format.md) and [game extensions](docs/game-extensions.md) describe the supported boundaries.

<a id="troubleshooting"></a>
## Troubleshooting

Check Logs before retrying a failed operation. For automatic backups, check the enabled switch, active save and pause/sleep status. Closing to the tray leaves the app running.

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
