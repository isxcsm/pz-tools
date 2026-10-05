# Documentation

[User guide](../README.md)

The [user guide](../README.md) covers installing and everyday use. The pages below go
further. They are in English; the app's interface languages are managed separately.

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

## Start here

- [How PZ Tools fits together](design/overview.md): the map. What runs where, what one
  backup does, and how the app follows the game. Read this before any design page.
- [Glossary](design/glossary.md): the terms the other pages use without explaining, such as
  revision, run index, lease, WATCH and generation.

## Using PZ Tools

For people running the app who want more detail than the user guide.

| Page | Read it when you want to know… |
| --- | --- |
| [Configuration](reference/settings.md) | What each setting does, where settings are stored, and how backup limits work |
| [Game-aware backup timing](design/runtime-pause-backups.md) | Why the countdown paused, or why a backup ran without a game save |
| [Security](../SECURITY.md) | What PZ Tools does to the game, what goes over the network, why it needs administrator rights, and how to check a download |
| [Death backups](design/runtime-character-death.md) | When a death backup is made, why periodic backups stop after a death, and what the last-save report shows |
| [Saving the game before a backup](design/game-bridge.md) | What the in-game save does, what can make it fail, and which games are supported |
| [Character recovery](design/character-recovery.md) | What healing, revival and inventory recovery can and cannot do |
| [Game extensions](design/game-extensions.md) | What the optional in-game features are and when their settings take effect |
| [Performance recording](design/profiler.md) | How to record a session and read the frame graph and mod shares; the last minutes after a stutter, comparing and saving ranges, and hotkeys |
| [Game memory](design/game-memory.md) | How the app gives the game more memory, and what a game update does to it |
| [Vehicle test guide](contributing/e2e-vehicle-drivetrain.md) | How to test the vehicle extension in a real game, tune it and back out |
| [Command line](reference/command-line.md) | How to run backup, restore, ZIP and maintenance without the app |
| [Advanced component settings](reference/advanced-settings.md) | How to tune the background programs' settings files: timeouts, buffers and polling intervals |
| [Files and folders](reference/files-and-folders.md) | Which files belong to the app, to you, and to a backup folder, and the limits for importing ZIP files |

## How it works

Design pages. Each explains one part; the [overview](design/overview.md) shows how they connect.

**Backups and storage**

- [Repository format](design/repository-format.md): what a backup folder contains and when a backup counts as saved
- [Pack format](design/pack-format.md) and [compact storage](design/compact-repository-format.md): how file contents are stored
- [Path identities](design/path-normalization.md): how file names and case-only renames are recorded
- [Housekeeping](design/repository-housekeeping.md): trimming, reclaiming space and removing backups of deleted saves
- [USN change tracking](design/usn-journal.md) and [stable capture](design/stable-capture.md): finding changed files and copying files the game may be writing

**Processes and the game**

- [Process architecture](design/process-architecture.md): the schedulers, runners and workers, and which database each owns
- [Telemetry](design/telemetry.md): the diagnostic records behind progress cards and logs
- [Component updates](design/module-reload.md): replacing code inside a running game without a restart
- [Vehicle model](design/vehicle-drivetrain.md): how the vehicle extension computes and applies driving forces

**Interface**

- [UI contract](design/ui-ux-contract.md): the rules for changing the app's screens
- [UI assets](design/ui-assets.md): app icons, logo and illustrations
- [Localization](contributing/localization.md): interface languages and translation

## Contributing

- [Development and validation](contributing/development.md): building, tests and integration checks
- [Documentation maintenance](contributing/documentation-maintenance.md): where a new page goes and how to write it
- [Third-party notices](../THIRD_PARTY_NOTICES.md)

<a id="measurements-and-history"></a>
## History and measurements

Records of earlier work, kept in [history/](history/). Each describes the code and
the measurements of its time. They are not current instructions, guarantees or a
to-do list, and they are not updated.

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
