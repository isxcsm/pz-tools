<p>
  <a href="docs/ko-KR/README.md">한국어</a> ·
  <strong>English</strong> ·
  <a href="docs/zh-CN/README.md">简体中文</a> ·
  <a href="docs/zh-TW/README.md">繁體中文</a> ·
  <a href="docs/ja-JP/README.md">日本語</a> ·
  <a href="docs/ru-RU/README.md">Русский</a> ·
  <a href="docs/pt-BR/README.md">Português (Brasil)</a> ·
  <a href="docs/es-ES/README.md">Español (España)</a> ·
  <a href="docs/fr-FR/README.md">Français</a> ·
  <a href="docs/de-DE/README.md">Deutsch</a> ·
  <a href="docs/pl-PL/README.md">Polski</a> ·
  <a href="docs/tr-TR/README.md">Türkçe</a> ·
  <a href="docs/uk-UA/README.md">Українська</a> ·
  <a href="docs/it-IT/README.md">Italiano</a> ·
  <a href="docs/th-TH/README.md">ไทย</a> ·
  <a href="docs/id-ID/README.md">Bahasa Indonesia</a> ·
  <a href="docs/cs-CZ/README.md">Čeština</a> ·
  <a href="docs/es-MX/README.md">Español (Latinoamérica)</a>
</p>

# PZ Tools

PZ Tools is an unofficial Windows app for backing up and restoring Project Zomboid saves. It also provides character recovery for the supported save format. It is not a product of The Indie Stone.

<a id="features"></a>
## Features

Manual and scheduled backups, named restore points with thumbnails and character details, ZIP import/export, and offline character healing or revival. The interface, new default backup names and game-save notices support 18 languages. Themes, an optional system-tray mode, progress indicators and filtered logs are included.

<a id="getting-started"></a>
## Install and run

You need **Windows x64** and the **[.NET 10 runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** for Windows x64. The app currently requests administrator permission for USN file-change tracking. A published package includes its WinUI components and the small Java runtime used to connect to the game; game JAR files are not included.

Check [Releases](https://github.com/isxcsm/pz-tools/releases) for a runnable package. If none is published, use the build instructions below. GitHub's **Source code ZIP is not a runnable app**.

1. Extract the **entire** package to a folder and run `PzTools.App.exe`. Do not copy the EXE alone or mix files from different builds.
2. In Settings, check the save folder and choose a separate backup folder. Do not use the game's save folder as the backup destination.
3. Select a save, make a manual backup, and check that the app reports completion. Choose an automatic-backup interval and retention count.
4. For an update, close PZ Tools and use a complete new package in another folder. Keep your saves and backup data separate from app files.

Settings and control data are under `%LOCALAPPDATA%\PzTools`; backups are in your chosen folder. See [deployment paths (Korean)](docs/deployment-layout.md).

<a id="backups-and-retention"></a>
## Backups and deletion

New settings use **5-minute intervals** and retain **20 automatic backups**. Use the automatic backups switch to turn them on or off. Set the interval to 1–60 minutes; turning them off keeps the interval. Automatic backups follow the active save; restarting the app starts a new interval. Existing settings are kept.

Manual backups can be renamed and are excluded from the automatic-backup count limit. **This is not permanent retention:** explicit deletion, or cleanup after the original save disappears, can also remove manual backups. Export important backups to ZIP on a different drive before deleting or moving the original save.

Deleting a backup leaves the current save intact, but that backup can no longer be restored or exported. Deleting a save through the app also removes its backups. Space reclamation can happen later; deletion does not always shrink files immediately. See [settings (Korean)](docs/configuration.md) and [cleanup policy (English)](docs/repository-housekeeping.md).

<a id="game-saving"></a>
## Game saving before a backup

The optional bridge asks the active game to save before copying files. It loads a JVM agent and calls `GameWindow.save(true)` on the game thread; it does not require a Workshop mod or alter game installation files. The bridge is experimental for the inspected **Build 42 / Java 25 single-player** structure; multiplayer is not supported.

Game saving and the five-second countdown have separate switches. **“Game save complete” is not “Backup complete”:** file capture and compression happen afterward. Without the bridge, or for an inactive save, only data already written to disk is backed up. Failed or uncertain save requests are not reported as success. See [game-save integration (English)](docs/save-bridge.md).

<a id="restore-and-archives"></a>
## Restore, import and export

Stop playing the selected save before restoring it. Select the intended backup and check the confirmation: **restoring replaces the current files, so progress made after that backup is lost**. If restoration is interrupted, reopen PZ Tools and review its status before loading the save in the game. Do not assume that an automatic rollback succeeded.

Export the current save or a backup to ZIP; inspect a ZIP before importing it. Keep exported copies outside the app's backup folder when they are meant for long-term storage. A backup on the same drive does not protect against drive failure. [Archive commands (Korean)](docs/cli.md) describe the command-line equivalents.

<a id="character-recovery"></a>
## Character recovery

Make a manual backup or export a ZIP first: **character recovery does not create an extra backup of the original files**. It modifies only the current, inactive save, never past backups. The supported scope is **Build 42.20.4, world format 249, one local player (ID 1)**.

Healing or revival restores health and clears supported injuries and temporary conditions. Positive and negative traits, experience, skills, recipes and existing inventory are preserved. It does not grant permanent immunity or remove every mod-specific effect.

If the dead character's inventory is empty, items can be recovered only from a uniquely matching saved player zombie, based on saved position and the identity-card name. Moved zombies, targets without an identity card and corpses in map chunks are unsupported. Hand equipment may need to be set again. See [character recovery and its limits (English)](docs/character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Storage and compatibility

The engine stores changed data rather than a full copy of every save. It uses NTFS USN tracking when available and falls back to a full scan with content comparison. Copy verification and Brotli compression are enabled by default; content deduplication is optional. A game-save response and per-file checks **do not guarantee that every file represents exactly the same instant**.

This is pre-release software. Incompatible repositories are rejected with `repository-reset-required`; there is no automatic conversion or deletion. Select a **new empty backup folder** and retain the old one if its backups are needed. **Do not delete `Zomboid/Saves` or only `repository.db` to work around this error.** Use the [repository format (Korean)](docs/repository-format.md) for the current format/schema and [runtime settings (English)](docs/runtime-configuration.md) for advanced options.

<a id="troubleshooting"></a>
## Troubleshooting and reporting problems

If the app will not start, check the runtime and the complete package. If a file is in use or keeps changing, let the game finish saving before retrying the backup. If automatic backups do not run, check the interval, active save and whether PZ Tools is still running; closing to the tray is not exiting.

For a failed or partially completed operation, read Logs before repeating it. An incomplete restore or character edit needs attention before the save is loaded again. When opening an [issue](https://github.com/isxcsm/pz-tools/issues), include the app commit/version, game version, steps and relevant log details. Remove personal paths and private data; do not upload an entire save unless necessary.

<a id="building"></a>
## Build from source

Use Windows, the .NET SDK selected by `global.json`, PowerShell 7, a Windows x64 Java 25 JDK and Visual Studio C++/WinUI build tools. Run from the repository root; replace the example JDK path:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

The publishing script requires a **new or empty output folder** and prepares the app and workers together. For another build, choose another output path. [Development and validation (English)](docs/development.md) covers dependencies, distribution tests, CLI use and tests that require explicit opt-in.

<a id="technical-documentation"></a>
## Documentation

[Documentation index (English/Korean)](docs/README.md) lists all reference documents and their original languages. [Localization (English)](docs/localization.md) describes translation coverage. [Verification reports (Korean)](docs/verification-report.md) are dated results, not proof that every later commit or game version has passed. See also [third-party notices (English)](THIRD_PARTY_NOTICES.md).
