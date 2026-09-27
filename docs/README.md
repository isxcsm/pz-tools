# Documentation

[User guide](../README.md)

Documentation is maintained in English. The app's interface languages are managed separately.

## Use and configuration

- [Configuration](configuration.md) — preferences, paths and backup policy
- [Deployment layout](deployment-layout.md) — app files versus user data
- [CLI commands](cli.md) — backup, restore, ZIP and maintenance
- [Advanced runtime settings](runtime-configuration.md) — component tuning
- [Game-save bridge](save-bridge.md) — saving before capture and compatibility
- [Runtime observation](runtime-pause-backups.md) — pause/sleep-aware timing
- [Character state and death](runtime-character-death.md) — live observations and death-triggered backups
- [Character recovery](character-recovery.md) — healing, revival and inventory limits
- [Game extensions](game-extensions.md) — optional vehicle controls
- [Vehicle acceptance checks](e2e-vehicle-drivetrain.md) — testing and rollback

## Design references

- Storage: [repository](repository-format.md), [packs](pack-format.md), [compact representation](compact-repository-format.md), [paths](path-normalization.md), [housekeeping](repository-housekeeping.md)
- Capture: [USN tracking](usn-journal.md), [stable copies and memory limits](stable-capture.md)
- Runtime: [process architecture](process-architecture.md), [telemetry](telemetry.md), [JVM reload](module-reload.md), [vehicle model](vehicle-drivetrain-design.md)
- UI: [interaction contract](ui-ux-contract.md), [assets](ui-assets.md), [localization](localization.md)

## Contributing

- [Development and validation](development.md)
- [Documentation maintenance](documentation-maintenance.md)
- [Third-party notices](../THIRD_PARTY_NOTICES.md)

<a id="measurements-and-history"></a>
## Measurements and history

These records describe specific workloads or earlier work, not current guarantees or an active backlog.

- [Backup tuning](backup-tuning.md) and [performance profiling](performance-profile.md)
- [Verification report](verification-report.md)
- [Storage performance](storage-performance.md) and [hotpaths](storage-hotpaths.md)
- [Gameplay background load](gameplay-background-load.md)
- [Active-backup follow-up](active-backup-followup.md)
- [Connection and merge review](connection-startup-and-merge-review.md)
- [Fingerprint reconciliation](fingerprint-followup.md)
- [Localization review](localization-review.md)
- [Historical application plan](implementation-roadmap.md)
- [Computer-use diagnosis](computer-use-diagnosis.md)
