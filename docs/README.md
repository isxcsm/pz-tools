# Documentation

[User guide](../README.md)

The [user guide](../README.md) covers installing and everyday use. The pages below go
further. They are in English; the app's interface languages are managed separately.

## Start here

- [How PZ Tools fits together](overview.md): the map. What runs where, what one
  backup does, and how the app follows the game. Read this before any design page.
- [Glossary](glossary.md): the terms the other pages use without explaining, such as
  revision, run index, lease, WATCH and generation.

## Using PZ Tools

For people running the app who want more detail than the user guide.

| Page | Read it when you want to know… |
| --- | --- |
| [Configuration](configuration.md) | What each setting does, where settings are stored, and how backup limits work |
| [Game-aware backup timing](runtime-pause-backups.md) | Why the countdown paused, or why a backup ran without a game save |
| [Death backups](runtime-character-death.md) | When a death backup is made, why periodic backups stop after a death, and what the last-save report shows |
| [Saving the game before a backup](game-bridge.md) | What the in-game save does, what can make it fail, and which games are supported |
| [Character recovery](character-recovery.md) | What healing, revival and inventory recovery can and cannot do |
| [Game extensions](game-extensions.md) | What the optional in-game features are and when their settings take effect |
| [Performance recording](profiler.md) | How to record a session and read the frame graph and mod shares |
| [Game memory](game-memory.md) | How the app gives the game more memory, and what a game update does to it |
| [Vehicle test guide](e2e-vehicle-drivetrain.md) | How to test the vehicle extension in a real game, tune it and back out |
| [Command line](cli.md) | How to run backup, restore, ZIP and maintenance without the app |
| [Advanced component settings](runtime-configuration.md) | How to tune the background programs' settings files: timeouts, buffers and polling intervals |
| [Files and folders](deployment-layout.md) | Which files belong to the app, to you, and to a backup folder, and the limits for importing ZIP files |

## How it works

Design pages. Each explains one part; the [overview](overview.md) shows how they connect.

**Backups and storage**

- [Repository format](repository-format.md): what a backup folder contains and when a backup counts as saved
- [Pack format](pack-format.md) and [compact storage](compact-repository-format.md): how file contents are stored
- [Path identities](path-normalization.md): how file names and case-only renames are recorded
- [Housekeeping](repository-housekeeping.md): trimming, reclaiming space and removing backups of deleted saves
- [USN change tracking](usn-journal.md) and [stable capture](stable-capture.md): finding changed files and copying files the game may be writing

**Processes and the game**

- [Process architecture](process-architecture.md): the schedulers, runners and workers, and which database each owns
- [Telemetry](telemetry.md): the diagnostic records behind progress cards and logs
- [Component updates](module-reload.md): replacing code inside a running game without a restart
- [Vehicle model](vehicle-drivetrain-design.md): how the vehicle extension computes and applies driving forces

**Interface**

- [UI contract](ui-ux-contract.md): the rules for changing the app's screens
- [UI assets](ui-assets.md): app icons, logo and illustrations
- [Localization](localization.md): interface languages and translation

## Contributing

- [Development and validation](development.md): building, tests and integration checks
- [Documentation maintenance](documentation-maintenance.md): where a new page goes and how to write it
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
