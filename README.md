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
- **Optional vehicle controls** for acceleration, shifting, reversing and keyboard steering, plus an optional light around the vehicle while its headlights are on.
- **Optional screen look**: a colour grade for the game picture with three moods, a strength and seasonal colours. No game files are changed.

Includes 18 interface languages, themes, tray mode, progress cards and filtered logs. Documentation is English-only.

<a id="getting-started"></a>
## Get started

Requires **Windows x64** and the **[.NET 10 runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)**. The app requests administrator permission for NTFS change tracking.
WinUI components and the Java Attach runtime are included; no separate Java installation is needed.

1. Get a runnable package from [Releases](https://github.com/isxcsm/pz-tools/releases), or build from source below. Extract the whole package and run `PzTools.App.exe`; GitHub's source ZIP is not a runnable app.
2. Open Settings, choose your language and check the save and backup folders. Keep those folders separate.
3. Create a manual backup and confirm it completes. Automatic backups default to **every 5 minutes**, keeping **20 automatic backups**.

To update, close the app and extract the new package into a fresh folder. Do not mix builds. Your settings live under `%LOCALAPPDATA%\PzTools`; saves and backups stay in their configured folders. See [settings and paths](docs/configuration.md).

<a id="backups-and-retention"></a>
## Backup history

The automatic backup limit does not remove manual backups. Manual backups can still be deleted directly or by cleanup after the original save folder disappears. **Deleting a save through the app also deletes its backups.** Export anything you want to keep before removing or moving a save. See [cleanup policy](docs/repository-housekeeping.md).

Automatic timing follows the active save. Pause-aware timing is on by default, preserving the remaining interval while paused or asleep. Restarting the app starts a fresh interval; it does not immediately run an overdue periodic backup.

When your character dies, periodic backups stop until you play a new character, so a game left running on the death screen cannot push the backups made while alive out of the retained history. The optional death backup keeps one backup of that moment.

<a id="game-saving"></a>
## Save before backup

The optional game bridge asks the game to save before reading its files. No Workshop mod or game installation edits are needed. It uses a runtime hook to run the game's normal save operation, which can briefly pause gameplay. The integration targets the inspected Build 42 / Java 25 single-player game.

If PZ Tools cannot connect to the running game (for example after a game update), backups continue at the set interval with the files already on disk, and the app says so; features that need the game are locked until the connection returns.

Game saving and in-game notices have separate switches. **Game-save completion is not backup completion**: file copying and compression happen afterward. Turning saving off backs up only data already written to disk. Game-state monitoring and vehicle controls can remain active. See [game integration and compatibility](docs/save-bridge.md).

<a id="restore-and-archives"></a>
## Restore and ZIP files

Stop playing the selected save before restoring. **Restore replaces current files and loses progress made after the chosen backup.** If interrupted, reopen PZ Tools and check its status before loading the save.

Export a current save or backup to ZIP for an independent copy, or import one into the save list. Keep important exports on another drive: a backup beside the original does not protect against drive failure.

<a id="character-recovery"></a>
## Character recovery

Recovery works on the current save while it is not being played. It can heal or revive a supported character while preserving positive and negative traits, skills and progress. When death emptied the inventory, it can recover belongings from an identifiable zombie or corpse; missing items are not generated.

**Create a backup first.** Recovery does not make an extra copy automatically. See [supported formats and recovery limits](docs/character-recovery.md).

<a id="performance-recording"></a>
## Performance recording

The Performance page records the running game while you reproduce a lag, then shows a zoomable frame-time graph. Drag a range (or click one frame) to see where the time went, grouped by base game, each mod and the Java runtime, with the number of samples behind every figure. Nothing is measured unless a recording is running. Standard mode has almost no effect on the game; Detailed mode samples more often and also records waits and pauses.

Each recording is a single file that can be sent to someone else; it holds mod and script names, not your user folder paths. See [performance recording](docs/profiler.md).

<a id="backup-engine"></a>
<a id="compatibility-and-safeguards"></a>
<a id="compatibility-and-limits"></a>
## Compatibility and limits

PZ Tools is pre-release software. Keep an independent copy of important saves. File verification helps detect changes during capture, but it is not an atomic snapshot of the entire world.

If a backup folder uses an unsupported storage format, PZ Tools leaves it unchanged and refuses to open it. Choose a new empty backup folder and retain the old one if needed; do not delete the game save or just `repository.db`. See [storage compatibility](docs/repository-format.md) and [game-extension compatibility](docs/game-extensions.md).

<a id="troubleshooting"></a>
## Troubleshooting

Check Logs before retrying a failed operation. If automatic backups are not running, check that they are enabled, that a save is being played, and whether the game is paused or the character is asleep. Closing to the tray leaves the app running.

PZ Tools is not code-signed. Windows Smart App Control judges each executable separately from cloud reputation and can block some PZ Tools components even when the app itself starts; that verdict can change from day to day. The app reports blocked components in a card with a shortcut to the Smart App Control page in Windows Security (App & browser control). Recent Windows 11 updates let you turn Smart App Control off and back on there; whether to do so is your decision. A blocked component does not stop later automatic backups from being attempted.

If PZ Tools closes because of an unexpected error, it names an error report under `%LOCALAPPDATA%\PzTools\crash`; the newest 20 are kept. Starting PZ Tools while it is already running, including when it is hidden in the tray, brings its window forward.

For an [issue report](https://github.com/isxcsm/pz-tools/issues), include the app and game versions, reproduction steps, relevant logs and any error report. Remove private paths and personal data.

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

The [documentation index](docs/README.md) covers configuration, storage, game integration and development. To understand how the parts fit together, start with the [overview](docs/overview.md); unfamiliar terms are explained in the [glossary](docs/glossary.md). Dated test results and implementation notes are kept apart in `docs/history`.

<a id="license"></a>
## License

PZ Tools is released under the [MIT License](LICENSE). Bundled and adapted third-party components keep their own licenses; see the [third-party notices](THIRD_PARTY_NOTICES.md). Project Zomboid is a trademark of The Indie Stone; no game code or assets are included.
