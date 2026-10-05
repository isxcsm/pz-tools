# Documentation

Start with the [README](../README.md) for what PZ Tools is and how to install it. The pages
below are in English; the app itself has its own interface languages.

## Guides

One task each, step by step.

- [Getting started](guides/getting-started.md)
- [Go back to an earlier backup](guides/restore-a-save.md)
- [Move a save to another PC](guides/move-a-save.md)
- [Bring back a dead character](guides/revive-a-character.md)
- [Find a laggy mod](guides/find-a-laggy-mod.md)
- [Give the game more memory](guides/more-game-memory.md)
- [Better vehicle controls](guides/vehicle-controls.md)
- [Troubleshooting](guides/troubleshooting.md)

## Reference

What each part of the app is, for when a guide isn't enough.

| Page | What's in it |
| --- | --- |
| [Settings](reference/settings.md) | Every setting and hotkey, its default and when it takes effect |
| [Backups](reference/backups.md) | When backups run and wait, the sidebar's backup line, names, retention and deletion |
| [Performance page](reference/performance-page.md) | The recording controls, the frame graph, the tabs and the reports |
| [Logs page](reference/logs-page.md) | The log list, its filters, the details of an entry and marking entries reviewed |
| [Files and folders](reference/files-and-folders.md) | What is in the download, the data folder and a backup folder, and how to update or remove PZ Tools |
| [Advanced settings](reference/advanced-settings.md) | The settings files behind **Settings → Advanced** |
| [Command line](reference/command-line.md) | Backing up, restoring and exporting without the app |
| [Security](../SECURITY.md) | What PZ Tools does to the game, what goes over the network, and how to check a download |

## Design

How PZ Tools works, for anyone changing the code. Read the [overview](design/overview.md)
first; the [glossary](design/glossary.md) explains the terms the other pages use.

**Backups and storage**

- [Repository format](design/repository-format.md): what a backup folder contains and when a backup counts as saved
- [Pack format](design/pack-format.md) and [compact storage](design/compact-repository-format.md): how file contents are stored
- [Path identities](design/path-normalization.md): how file names and case-only renames are recorded
- [Housekeeping](design/repository-housekeeping.md): trimming, reclaiming space and removing backups of deleted saves
- [Archives and deletion](design/archives-and-deletion.md): ZIP export and import, and deleting backups and saves
- [USN change tracking](design/usn-journal.md) and [stable capture](design/stable-capture.md): finding changed files and copying files the game may be writing

**Processes**

- [Process architecture](design/process-architecture.md): the schedulers, runners and workers, and which database each owns
- [Telemetry](design/telemetry.md): the records behind progress cards, logs and crash reports

**The game**

- [Game bridge](design/game-bridge.md): attaching to the game and saving it before a backup
- [Game-aware backup timing](design/runtime-pause-backups.md): how the schedule follows play, pauses and sleep
- [Character death](design/runtime-character-death.md): death backups and why automatic backups wait
- [Character recovery](design/character-recovery.md): how healing and revival edit a save
- [Performance recording](design/profiler.md): sampling, recordings, analysis and reports
- [Game memory](design/game-memory.md): how the memory setting changes the game's launcher file
- [Game extensions](design/game-extensions.md): the extension framework and version checks
- [Vehicle model](design/vehicle-drivetrain.md): how the vehicle extension computes and applies driving forces
- [Component updates](design/module-reload.md): replacing code inside a running game

**Interface**

- [UI contract](design/ui-ux-contract.md): the rules for changing the app's screens
- [UI assets](design/ui-assets.md): app icons, logo and illustrations

## Contributing

- [Development](contributing/development.md): building, tests, publishing and CI
- [Documentation](contributing/documentation-maintenance.md): where a page goes and how to write it
- [Localization](contributing/localization.md): interface languages and translation
- [Vehicle test guide](contributing/e2e-vehicle-drivetrain.md): testing the vehicle extension in a real game
- [Third-party notices](../THIRD_PARTY_NOTICES.md)

<a id="measurements-and-history"></a>
## History and measurements

Records of earlier work, kept in [history/](history/). Each describes the code and the
measurements of its time. They are not current instructions, guarantees or a to-do list, and
they are not updated.

- [Backup tuning](history/backup-tuning.md) and [performance profiling](history/performance-profile.md)
- [Verification report](history/verification-report.md)
- [Storage performance](history/storage-performance.md) and [storage hotpaths](history/storage-hotpaths.md)
- [Compact storage measurements](history/compact-repository-measurements.md) and [path normalization measurements](history/path-normalization-measurements.md)
- [Gameplay background load](history/gameplay-background-load.md)
- [Active-backup follow-up](history/active-backup-followup.md)
- [Connection and merge review](history/connection-startup-and-merge-review.md)
- [Fingerprint reconciliation](history/fingerprint-followup.md)
- [Localization review](history/localization-review.md)
- [Historical application plan](history/implementation-roadmap.md)
- [Computer-use diagnosis](history/computer-use-diagnosis.md)
