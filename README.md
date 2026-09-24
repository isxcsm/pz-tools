<p align="center">
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

<p align="center">
  <img src="src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

<h1 align="center">PZ Tools</h1>

<p align="center">
  <strong>You handle survival. PZ Tools keeps a way back.</strong><br />
  Automatic backups · Save history · Character recovery for Project Zomboid
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-x64-0078D4" alt="Windows x64" />
  <img src="https://img.shields.io/badge/UI-WinUI%203-1465AD" alt="WinUI 3" />
  <img src="https://img.shields.io/badge/.NET-10-512BD4" alt=".NET 10" />
  <img src="https://img.shields.io/badge/Languages-18-27B6B1" alt="18 locales" />
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#backup-engine">Backup engine</a> ·
  <a href="#getting-started">Getting started</a> ·
  <a href="#compatibility-and-limits">Compatibility</a> ·
  <a href="#building">Building</a>
</p>

PZ Tools is a Windows desktop app that detects the save you are playing, backs it up on a schedule, and lets you choose a restore point by thumbnail and character information.

Behind that simple save list are **in-game save requests, incremental capture, copy verification, compressed storage, and interrupted-operation recovery**. You can also heal a supported character without rolling back the entire world.

## Features

| What you want | What PZ Tools provides |
| :--- | :--- |
| Focus on surviving | Active-save detection, automatic backups, and a next-backup countdown |
| Keep an important moment | Renameable manual backups, excluded from automatic retention trimming |
| Capture recent progress | Optional game-thread `save(true)` before capture, with a five-second in-game countdown |
| Recognize a restore point | Thumbnails, character names, survival time, and alive/dead status |
| Recover your character | Offline healing and revival; inventory retrieval from an eligible matching player zombie |
| Back up frequently | USN change tracking, incremental storage, compression, and optional content deduplication |
| Move your saves | ZIP inspection, import, export, and revision restoration |
| Understand what happened | Progress cards, per-run logs, warnings, and copyable technical details |

### Automatic history. Manual checkpoints.

Automatic backups follow the currently played save. New installations default to **every 5 minutes, keeping 20 automatic backups**. Set the interval to `0` to disable scheduling. Existing settings are preserved.

Manual and automatic backups get distinct names and retention rules. The retention count trims **automatic backups only**; manual checkpoints remain outside that limit. Restarting the app starts a fresh interval instead of immediately running an overdue timer from the previous session.

> Manual retention protection does not override explicit deletion or orphan-backup cleanup when the original save disappears. Export important checkpoints as ZIP files for long-term storage.

### Ask the game to save before copying its files

Recent progress can still be in memory. When the selected world is active, the optional bridge invokes `GameWindow.save(true)` **on the game thread** and waits for its response before file capture.

- No Workshop mod or debug-console commands are required.
- PZ Tools can connect after the game has already started.
- The bridge loads an agent into the running JVM; it does not modify game installation files or launch options.
- Optional overhead notices count down **5 → 4 → 3 → 2 → 1**, then show **Save complete** after the game save call returns.
- Connection preparation begins before the scheduled deadline; it does not add another five-second wait at zero.
- Game saving and in-game notices have separate settings toggles.

Menus and inactive saves are backed up from disk without requesting an in-game save. Failed or indeterminate save requests are not reported as successful.

**Save complete in the game is not backup complete.** Collection and compression finish afterward and are reported by the app. Game-frame stalls and connection delays can affect timing. See [the save bridge](docs/save-bridge.md) for implementation and compatibility details.

### Find a restore point by its contents

Browse the current save alongside its history, with thumbnails, character names, survival time, death indicators, and timestamps. Restore a chosen revision, export a save or revision to ZIP, or inspect a ZIP before importing it.

Operations that could overwrite an actively played save are restricted. Restoration prepares files in a staging area and records transaction state so interrupted work can be handled on the next startup.

### Heal the character, not the whole world

Recovery requires confirmation and operates only on the **current save while it is not being played**. It never edits historical backup revisions.

| Restored or cleared | Preserved |
| :--- | :--- |
| Health, hunger, thirst, fatigue, endurance, and mental state | Positive **and negative traits** |
| Injuries, fractures, burns, and bleeding across 17 body parts | Experience, skills, and recipes |
| Embedded glass/bullets, infection, illness, poisoning, and related timers | Appearance, position, and survival time |
| Temporary stress, pain, panic, and nicotine withdrawal | Weight, nutrition, exercise history, and existing items |
| Death flags and supported character state | Unknown mod data, without reinterpreting it |

Negative traits are **not** treated as injuries. Trait and experience regions remain byte-for-byte intact. Recovery is not permanent invulnerability: traits or environmental exposure can cause symptoms again.

If the dead character's inventory is empty, the recovery path can retrieve items and nested bag contents from a **uniquely matching saved player zombie**, using saved position and the identity-card name. It rejects ambiguous or unsupported records. Moved zombies, targets without an identity card, and corpses stored in map chunks are not supported by this retrieval path. See [character recovery](docs/character-recovery.md) for equipment and format limits.

### Small conveniences, too

- **18 locales**, covering the interface, new default backup names, and game-save notices.
- System, light, and dark themes.
- Optional system-tray behavior and single-instance protection.
- Progress reporting for backup, restore, archive, and deletion operations.
- Log filtering by severity, operation, and run number.
- Everyday settings in the UI; component-specific TOML for advanced behavior.

Select a language above for a localized feature guide and quick start. GitHub does not automatically switch README language. Internal technical documents retain their original languages; see [localization](docs/localization.md) for scope and checks.

## Backup engine

| Layer | Behavior |
| :--- | :--- |
| Change tracking | Uses the NTFS USN journal when available. A content-change record triggers capture even if size and modification time match. |
| Fallback | Falls back to a full scan when USN is unavailable or its checkpoint is invalid, with SHA-256 content comparison enabled by default. |
| Critical files | `players.db`, `vehicles.db`, and `thumb.png` are on the default always-include list. |
| Capture verification | Compares source and staged-copy hashes and retries mismatches. An unstable capture fails instead of being reported as complete. |
| Storage | Writes changed data into immutable packs and describes revisions in SQLite metadata, rather than creating a full directory copy each time. |
| Space management | Brotli compression, optional content deduplication, automatic-history trimming, garbage collection, and pack compaction. |

File collection, compression, restoration, and maintenance run in worker processes. Progress events are batched and projected as current state to reduce per-file UI overhead. Repository mutations are serialized; operation records track staging and publication for recovery and cleanup after interruption.

See the [performance profile](docs/performance-profile.md) for measurement conditions and reproduction commands. Results depend on file counts, data, compression settings, and storage hardware.

## Getting started

### Requirements

- **Windows x64** and the **.NET 10 runtime**.
- Published app folders include required WinUI components and a small Java runtime for the save bridge.
- Game integration and character recovery have the narrower compatibility limits below.

To create a distribution from source, see [Building](#building).

1. Run `PzTools.App.exe` from the published folder.
2. Check the save and backup directories in Settings.
3. Choose the backup interval and automatic-history limit; optionally configure game saving and notices.
4. Make a manual checkpoint or let automatic backups run while you play.
5. Stop playing that save before restoring a chosen backup or recovering its character.

Settings and control data live under `%LOCALAPPDATA%\PzTools`; backup data lives in the directory you choose. The app does not put its management database inside your save.

## Compatibility and limits

| Feature | Current scope |
| :--- | :--- |
| App and backup engine | Windows x64; full-scan fallback when USN is unavailable. |
| Pre-backup game save | Experimental adapter for the inspected Java 25 / Build 42 method structure. Multiplayer is unsupported. |
| Character recovery | Build **42.20.4**, world format **249**, one local player (**ID 1**). Other formats, multiple players, or unverifiable data are rejected. |
| Mods and future versions | Compatibility is not guaranteed for changes to save structures. Mod-specific debuffs are not universally understood or removed. |

> A returned `save(true)` call and per-file validation do **not** guarantee an atomic snapshot of the entire world. The game can still modify files during capture. Backups on the same disk do not protect against disk failure; export important checkpoints to separate storage.

You can disable pre-backup game saving for a separate save mod or an incompatible game update. Backups will then contain only what has reached disk, not progress still held in memory.

## Building

.NET 10 SDK, a Windows/WinUI build environment, a Windows x64 Java 25 JDK, and Visual Studio x64 C++ build tools are required. See [bridge build and publishing](docs/save-bridge.md#building-and-publishing) for JDK selection and native build details.

```powershell
dotnet build PzTools.sln -p:JdkPath=C:\path\to\jdk-25
dotnet test PzTools.sln -p:JdkPath=C:\path\to\jdk-25
pwsh scripts/publish-tools.ps1 -JdkPath C:\path\to\jdk-25
pwsh scripts/publish-app.ps1 -JdkPath C:\path\to\jdk-25 -Output artifacts/app-local
```

Publishing requires a **new or empty output folder**. Use a different `-Output` path for another publish; the script does not erase an existing installation or user settings.

<details>
<summary>Distribution checks and advanced use</summary>

```powershell
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/app-local).Path
$env:PZTOOLS_TOOLS_DIR = $env:PZTOOLS_DISTRIBUTION_DIR
dotnet test tests/PzTools.Backup.Tests -c Release
```

Real-save, elevated USN, and app-lifecycle checks require explicit setup. Read the [verification report](docs/verification-report.md) before running opt-in verification scripts; its results are dated, not a claim about every later revision.

The distribution includes required WinUI components and a reduced Java Attach runtime. Unused Windows App SDK AI/ML, widgets, and framework installer packages are excluded at the NuGet asset stage. Game JARs are not redistributed; PDBs stay in build outputs rather than the published folder.

Command-line tools also support backup, restoration, verification, maintenance, and ZIP operations. See [CLI commands](docs/cli.md) and [configuration](docs/configuration.md).

Default capture/storage settings:

```toml
[capture]
always_include = ["players.db", "vehicles.db", "thumb.png"]
full_scan_hash_comparison = true

[storage]
checksum = "auto"
compression = "auto"
content_deduplication = false
verify_staged_copies = true
```

Currently, `auto` selects xxHash64 checksums and Brotli compression. Content deduplication uses SHA-256. Disabling full-scan hash comparison does not disable always-include capture or backup integrity checks, and does not erase existing comparison hashes.

</details>

## Technical documentation

Documents below are in their original languages; localized README guides are available through the selector above.

| Topic | Documents |
| :--- | :--- |
| Game integration | [Save bridge](docs/save-bridge.md) · [Character recovery](docs/character-recovery.md) |
| Capture correctness | [USN journal](docs/usn-journal.md) · [Stable capture](docs/stable-capture.md) |
| Storage | [Repository format](docs/repository-format.md) · [Pack format](docs/pack-format.md) |
| Workers and diagnostics | [Process architecture](docs/process-architecture.md) · [Telemetry](docs/telemetry.md) |
| Settings and deployment | [Configuration](docs/configuration.md) · [Runtime configuration](docs/runtime-configuration.md) · [Deployment layout](docs/deployment-layout.md) |
| Verification | [Performance profile](docs/performance-profile.md) · [Verification report](docs/verification-report.md) |
| Development | [Implementation roadmap](docs/implementation-roadmap.md) · [UI/UX contract](docs/ui-ux-contract.md) · [Localization](docs/localization.md) |
| Dependencies | [Third-party notices](THIRD_PARTY_NOTICES.md) |

---

PZ Tools is an unofficial tool for Project Zomboid. It is not a product of The Indie Stone.
